# =====================================================================
#  feeds.tcl  v1.2.0  -  RSS / Atom announcer with per-channel subscriptions
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Announces new items from RSS 2.0, RSS 1.0 (RDF) and Atom feeds.
#    Polls politely (ETag / If-Modified-Since, per-feed interval), never
#    repeats an item, doesn't flood on the first fetch, and supports
#    keyword filters. Shortcuts for common sources:
#      github:owner/repo      releases of a GitHub repository
#      github-commits:owner/repo[/branch]
#      youtube:UCxxxxxxxx     new videos of a YouTube channel (channel id)
#      reddit:subreddit       new posts of a subreddit
#      mastodon:@user@host    posts of a Mastodon account
#      bsky:handle            posts of a Bluesky account
#
#  REQUIREMENTS
#    web.tcl, timeutil.tcl (load them first), tcl-tls for HTTPS
#
#  SETUP
#    .chanset #chan +feeds
#
#  COMMANDS (channel; adding/changing needs bot op o|o)
#    !feed add <url|shortcut> [name] [minutes]   subscribe this channel
#    !feed del <name>                           unsubscribe
#    !feed list                                 subscriptions and status
#    !feed latest <name> [n]                    show the n latest items
#    !feed check <name>                         poll it now
#    !feed pause <name> | !feed resume <name>
#    !feed interval <name> <minutes>
#    !feed filter <name> <words|off>            only items matching any
#                                               word; -word excludes
#    !feed rename <name> <newname>
#    !feed max <name> <n>                       items announced per poll
#    !feed test <url|shortcut>                  preview without saving
#  PARTYLINE
#    .feeds                                     every feed on the bot (master)
# =====================================================================

namespace eval ::feeds {
    # ------------------------- CONFIGURATION -------------------------
    variable datadir "feeds"
    variable default_interval 15     ;# minutes
    variable min_interval 5          ;# minutes
    variable max_feeds_per_chan 25
    variable default_max_items 3     ;# items announced per poll
    variable max_age_days 3          ;# ignore items older than this
    variable seen_keep 400           ;# remembered item ids per feed
    variable max_bytes 2000000       ;# refuse bigger feeds
    variable throttle 3

    # --------------------- STATE (do not touch) ---------------------
    variable feeds                   ;# feeds(id) -> dict
    variable nextid
    variable busy                    ;# busy(id) -> 1 while fetching
    variable last
    if {![info exists nextid]} {set nextid 1}
}

setudef flag feeds

# ----------------------------- HELPERS -----------------------------

proc ::feeds::expand {src} {
    set s [string trim $src]
    switch -regexp -matchvar m -- $s {
        {^github:([\w.-]+/[\w.-]+)$}                {return "https://github.com/[lindex $m 1]/releases.atom"}
        {^github-commits:([\w.-]+/[\w.-]+)(?:/([\w./-]+))?$} {
            set br [expr {[lindex $m 2] eq "" ? "HEAD" : [lindex $m 2]}]
            return "https://github.com/[lindex $m 1]/commits/$br.atom"
        }
        {^youtube:(UC[\w-]{22})$}                   {return "https://www.youtube.com/feeds/videos.xml?channel_id=[lindex $m 1]"}
        {^reddit:(?:r/)?(\w+)$}                     {return "https://www.reddit.com/r/[lindex $m 1]/new/.rss"}
        {^mastodon:@?([\w.]+)@([\w.-]+)$}           {return "https://[lindex $m 2]/@[lindex $m 1].rss"}
        {^bsky:@?([\w.-]+)$}                        {return "https://bsky.app/profile/[lindex $m 1]/rss"}
    }
    if {[regexp -nocase {^https?://} $s]} {return $s}
    return ""
}

proc ::feeds::hash {s} {
    if {[info commands ::md5] ne ""} {return [::md5 $s]}
    if {[string length $s] > 200} {return [string range $s 0 199]}
    return $s
}

proc ::feeds::find {chan name} {
    variable feeds
    set c [string tolower $chan]
    foreach id [array names feeds] {
        set f $feeds($id)
        if {[string tolower [dict get $f chan]] eq $c &&
            ([string equal -nocase [dict get $f name] $name] || $id eq [string trimleft $name #])} {
            return $id
        }
    }
    return ""
}

proc ::feeds::chanfeeds {chan} {
    variable feeds
    set out {}
    foreach id [lsort -integer [array names feeds]] {
        if {[string equal -nocase [dict get $feeds($id) chan] $chan]} {lappend out $id}
    }
    return $out
}

proc ::feeds::save {} {
    variable feeds
    variable nextid
    variable datadir
    file mkdir $datadir
    set f [file join $datadir feeds.db]
    set fd [open $f.tmp w]
    fconfigure $fd -encoding utf-8
    puts $fd [list nextid $nextid]
    foreach id [lsort -integer [array names feeds]] {puts $fd [list feed $id $feeds($id)]}
    close $fd
    file rename -force $f.tmp $f
}

proc ::feeds::load {} {
    variable feeds
    variable nextid
    variable datadir
    set f [file join $datadir feeds.db]
    if {![file exists $f]} return
    set fd [open $f r]
    fconfigure $fd -encoding utf-8
    while {[gets $fd line] >= 0} {
        if {[catch {lindex $line 0} kind]} continue
        switch -- $kind {
            nextid {set nextid [lindex $line 1]}
            feed   {set feeds([lindex $line 1]) [lindex $line 2]}
        }
    }
    close $fd
}

# ------------------------------ PARSING ------------------------------

proc ::feeds::tag {xml name} {
    if {[regexp -nocase "<${name}(?:\\s\[^>\]*)?>(.*?)</${name}>" $xml -> v]} {return $v}
    return ""
}

# Returns {title items} ; items = list of dicts {title link id date}
proc ::feeds::parse {xml} {
    set items {}
    set atom [regexp -nocase {<entry[\s>]} $xml]
    if {$atom} {
        set blocks [regexp -all -inline -nocase {<entry[\s>].*?</entry>} $xml]
        set head [lindex [split [string map {<entry \x01} $xml] \x01] 0]
    } else {
        set blocks [regexp -all -inline -nocase {<item[\s>].*?</item>} $xml]
        set head [lindex [split [string map {<item \x01} $xml] \x01] 0]
    }
    set ftitle [::web::unhtml [tag $head title]]
    foreach b $blocks {
        set title [::web::unhtml [tag $b title]]
        set link ""
        if {$atom} {
            if {![regexp -nocase {<link[^>]*rel=["']alternate["'][^>]*href=["']([^"']+)["']} $b -> link] &&
                ![regexp -nocase {<link[^>]*href=["']([^"']+)["'][^>]*rel=["']alternate["']} $b -> link]} {
                regexp -nocase {<link[^>]*href=["']([^"']+)["']} $b -> link
            }
            set id [::web::unhtml [tag $b id]]
            set date [tag $b published]
            if {$date eq ""} {set date [tag $b updated]}
        } else {
            set link [::web::unhtml [tag $b link]]
            if {$link eq ""} {regexp -nocase {rdf:about=["']([^"']+)["']} $b -> link}
            set id [::web::unhtml [tag $b guid]]
            set date [tag $b pubDate]
            if {$date eq ""} {set date [tag $b dc:date]}
        }
        set link [::web::entities [string trim $link]]
        if {$id eq ""} {set id $link}
        if {$id eq ""} {set id $title}
        if {$title eq "" && $link eq ""} continue
        if {$title eq ""} {set title "(untitled)"}
        lappend items [dict create title $title link $link id $id date [::timeutil::parse_feed_date [string trim $date]]]
    }
    list $ftitle $items
}

# ------------------------------ POLLING ------------------------------

proc ::feeds::poll {id {force 0}} {
    variable feeds
    variable busy
    if {![info exists feeds($id)] || [info exists busy($id)]} return
    set f $feeds($id)
    set busy($id) 1
    set hdr {}
    if {!$force && [dict get $f etag] ne ""} {lappend hdr If-None-Match [dict get $f etag]}
    if {!$force && [dict get $f lastmod] ne ""} {lappend hdr If-Modified-Since [dict get $f lastmod]}
    lappend hdr Accept "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5"
    dict set feeds($id) checked [clock seconds]
    ::web::fetch [dict get $f url] [list ::feeds::polled $id] $hdr
}

proc ::feeds::polled {id ok code body meta} {
    variable feeds
    variable busy
    variable max_bytes
    unset -nocomplain busy($id)
    if {![info exists feeds($id)]} return
    if {$code == 304} {
        dict set feeds($id) fails 0
        return
    }
    if {!$ok || [string length $body] > $max_bytes} {
        dict incr feeds($id) fails
        dict set feeds($id) error [expr {$ok ? "too large" : "HTTP $code"}]
        if {[dict get $feeds($id) fails] == 10} {
            putlog "feeds: #$id [dict get $feeds($id) name] ([dict get $feeds($id) chan]) failed 10 times in a row"
        }
        save
        return
    }
    if {[catch {parse [decode $body $meta]} parsed] || ![llength [lindex $parsed 1]]} {
        dict incr feeds($id) fails
        dict set feeds($id) error "not a feed"
        save
        return
    }
    lassign $parsed ftitle items
    dict set feeds($id) fails 0
    dict set feeds($id) error ""
    if {$ftitle ne ""} {dict set feeds($id) title $ftitle}
    foreach {k v} {etag etag lastmod last-modified} {
        dict set feeds($id) $k [expr {[dict exists $meta $v] ? [dict get $meta $v] : ""}]
    }
    announce $id $items
    save
}

proc ::feeds::decode {body meta} {
    set cs utf-8
    if {[dict exists $meta content-type]} {
        regexp -nocase {charset=["']?([\w-]+)} [dict get $meta content-type] -> cs
    }
    if {[regexp -nocase {<\?xml[^>]+encoding=["']([\w-]+)["']} [string range $body 0 200] -> x]} {set cs $x}
    set cs [string tolower $cs]
    set map {utf8 utf-8 iso-8859-1 iso8859-1 latin1 iso8859-1 iso-8859-15 iso8859-15 windows-1252 cp1252}
    if {[dict exists $map $cs]} {set cs [dict get $map $cs]}
    if {$cs ni [encoding names]} {set cs utf-8}
    # ::web::fetch hands over raw bytes
    if {[catch {encoding convertfrom $cs $body} txt]} {return $body}
    return $txt
}

proc ::feeds::matches {filter title} {
    if {$filter eq ""} {return 1}
    set inc {}
    foreach w $filter {
        if {[string index $w 0] eq "-"} {
            if {[string match -nocase "*[string range $w 1 end]*" $title]} {return 0}
        } else {
            lappend inc $w
        }
    }
    if {![llength $inc]} {return 1}
    foreach w $inc {
        if {[string match -nocase "*$w*" $title]} {return 1}
    }
    return 0
}

proc ::feeds::announce {id items} {
    variable feeds
    variable seen_keep
    variable max_age_days
    set f $feeds($id)
    set seen [dict get $f seen]
    set primed [dict get $f primed]
    set fresh {}
    foreach it $items {
        set h [hash [dict get $it id]]
        if {$h in $seen} continue
        lappend seen $h
        lappend fresh $it
    }
    if {[llength $seen] > $seen_keep} {set seen [lrange $seen end-[expr {$seen_keep - 1}] end]}
    dict set feeds($id) seen $seen
    if {!$primed} {
        # First fetch: remember everything, announce nothing
        dict set feeds($id) primed 1
        return
    }
    set now [clock seconds]
    set out {}
    foreach it $fresh {
        set d [dict get $it date]
        if {$d ne "" && $now - $d > $max_age_days * 86400} continue
        if {![matches [dict get $f filter] [dict get $it title]]} continue
        lappend out $it
    }
    if {![llength $out]} return
    set chan [dict get $f chan]
    if {![validchan $chan] || ![botonchan $chan] || ![channel get $chan feeds]} return
    set max [dict get $f max]
    # Feeds list newest first: announce in chronological order
    set out [lreverse $out]
    set extra [expr {[llength $out] - $max}]
    if {$extra > 0} {set out [lrange $out end-[expr {$max - 1}] end]}
    foreach it $out {say_item $chan [dict get $f name] $it}
    if {$extra > 0} {
        puthelp "PRIVMSG $chan :[::web::msg Feed "[::web::b [dict get $f name]] +$extra more ([::web::b {!feed latest}] [dict get $f name])"]"
    }
}

# Feed :: name Title (3 hours ago) | link
proc ::feeds::say_item {target name it} {
    set line "[::web::tag Feed] :: [::web::b $name] [::web::trim [dict get $it title] 220]"
    if {[dict get $it date] ne ""} {append line " [::web::dim ([::timeutil::rel [dict get $it date]])]"}
    if {[dict get $it link] ne ""} {append line "[::web::sep][dict get $it link]"}
    ::web::say $target $line
}

# Every reply of the !feed command carries the Feed tag
proc ::feeds::reply {target text} {
    ::web::say $target [::web::msg Feed $text]
}

# Every minute: poll the feeds that are due
bind time - "* * * * *" ::feeds::tick
proc ::feeds::tick {args} {
    variable feeds
    set now [clock seconds]
    set delay 0
    foreach id [array names feeds] {
        set f $feeds($id)
        if {[dict get $f paused] || $now - [dict get $f checked] < [dict get $f interval] * 60} continue
        set chan [dict get $f chan]
        if {![validchan $chan] || ![channel get $chan feeds]} continue
        # Spread the requests a little
        utimer [incr delay 2] [list ::feeds::poll $id]
    }
}

# ----------------------------- COMMANDS -----------------------------

proc ::feeds::new_feed {chan url name interval by} {
    variable nextid
    variable default_max_items
    set id $nextid
    incr nextid
    return [list $id [dict create chan $chan url $url name $name title "" interval $interval \
        etag "" lastmod "" checked 0 seen {} primed 0 fails 0 error "" paused 0 filter {} \
        max $default_max_items by $by added [clock seconds]]]
}

proc ::feeds::test_done {target url ok code body meta} {
    if {!$ok} {reply $target "Can't fetch $url (HTTP $code)."; return}
    if {[catch {parse [decode $body $meta]} p] || ![llength [lindex $p 1]]} {
        reply $target "That URL doesn't look like an RSS/Atom feed."
        return
    }
    lassign $p title items
    ::web::say $target [::web::line Feed "OK: [expr {$title eq "" ? $url : $title}]" [list [::web::lbl Items [llength $items]]]]
    say_item $target [expr {$title eq "" ? "feed" : [::web::trim $title 30]}] [lindex $items 0]
}

proc ::feeds::latest_done {target name n ok code body meta} {
    if {!$ok || [catch {parse [decode $body $meta]} p] || ![llength [lindex $p 1]]} {
        reply $target "Can't read $name right now."
        return
    }
    foreach it [lrange [lindex $p 1] 0 [expr {$n - 1}]] {say_item $target $name $it}
}

proc ::feeds::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

bind pub - !feed ::feeds::pub_feed
bind pub - !feeds ::feeds::pub_feed
bind pub - !rss ::feeds::pub_feed
proc ::feeds::pub_feed {nick uhost hand chan text} {
    variable feeds
    variable default_interval
    variable min_interval
    variable max_feeds_per_chan
    if {![channel get $chan feeds] || [flood $uhost]} {return 0}
    set w [regexp -all -inline {\S+} $text]
    set sub [string tolower [lindex $w 0]]
    set op [matchattr $hand o|o $chan]
    set say [list ::feeds::reply $chan]
    if {$sub in {add del delete rm pause resume interval filter rename max check} && !$op} {
        puthelp "NOTICE $nick :Only bot ops can change the feeds of $chan."
        return 0
    }
    set name [lindex $w 1]
    set id [expr {$name ne "" ? [find $chan $name] : ""}]
    switch -- $sub {
        add {
            set url [expand $name]
            if {$url eq ""} {{*}$say "Usage: !feed add <url|github:owner/repo|youtube:UC...|reddit:sub|mastodon:@user@host|bsky:handle> \[name\] \[minutes\]"; return 0}
            if {[llength [chanfeeds $chan]] >= $max_feeds_per_chan} {{*}$say "This channel already has $max_feeds_per_chan feeds."; return 0}
            set fname [lindex $w 2]
            set mins [lindex $w 3]
            if {[string is integer -strict $fname]} {set mins $fname; set fname ""}
            if {$fname eq ""} {
                regexp {^[^:]+:(?:@)?([\w.-]+)} $name -> fname
                if {[regexp -nocase {^https?://(?:www\.)?([^/]+)} $name -> hostname]} {set fname [lindex [split $hostname .] 0]}
            }
            regsub -all {[^\w.-]} $fname "" fname
            if {$fname eq "" || [find $chan $fname] ne ""} {set fname "feed[llength [chanfeeds $chan]]"}
            if {![string is integer -strict $mins]} {set mins $default_interval}
            set mins [expr {max($min_interval, $mins)}]
            foreach fid [chanfeeds $chan] {
                if {[dict get $feeds($fid) url] eq $url} {{*}$say "Already subscribed as \002[dict get $feeds($fid) name]\002."; return 0}
            }
            lassign [new_feed $chan $url $fname $mins $nick] fid data
            set feeds($fid) $data
            save
            poll $fid
            {*}$say "Subscribed \002$fname\002 ($url), checked every $mins min. New items will be announced here."
        }
        del - delete - rm {
            if {$id eq ""} {{*}$say "No feed called \"$name\" (see !feed list)."; return 0}
            set n [dict get $feeds($id) name]
            unset feeds($id)
            save
            {*}$say "Unsubscribed \002$n\002."
        }
        list - "" {
            set ids [chanfeeds $chan]
            if {![llength $ids]} {{*}$say "No feeds yet. Ops: !feed add <url> \[name\]"; return 1}
            foreach fid $ids {
                set f $feeds($fid)
                set st [expr {[dict get $f paused] ? "paused" : [dict get $f fails] > 0 ? "[dict get $f error] x[dict get $f fails]" : "ok"}]
                set fl [expr {[llength [dict get $f filter]] ? [::web::lbl Filter [join [dict get $f filter]]] : ""}]
                set title [::web::trim [dict get $f title] 50]
                puthelp "NOTICE $nick :[::web::tag Feed] :: [::web::dim #$fid] [::web::b [dict get $f name]][expr {$title ne "" ? " $title" : ""}] ([::web::fields [list [::web::lbl Every [dict get $f interval]m] [::web::lbl Status $st] $fl]])[::web::sep][dict get $f url]"
            }
        }
        latest {
            if {$id eq ""} {{*}$say "No feed called \"$name\"."; return 0}
            set n [lindex $w 2]
            if {![string is integer -strict $n] || $n < 1} {set n 3}
            ::web::fetch [dict get $feeds($id) url] [list ::feeds::latest_done $chan [dict get $feeds($id) name] [expr {min($n, 5)}]]
        }
        check {
            if {$id eq ""} {{*}$say "No feed called \"$name\"."; return 0}
            poll $id 1
            {*}$say "Checking \002[dict get $feeds($id) name]\002..."
        }
        pause - resume {
            if {$id eq ""} {{*}$say "No feed called \"$name\"."; return 0}
            dict set feeds($id) paused [expr {$sub eq "pause"}]
            save
            {*}$say "\002[dict get $feeds($id) name]\002 [expr {$sub eq "pause" ? "paused" : "resumed"}]."
        }
        interval {
            set m [lindex $w 2]
            if {$id eq "" || ![string is integer -strict $m]} {{*}$say "Usage: !feed interval <name> <minutes>"; return 0}
            dict set feeds($id) interval [expr {max($min_interval, $m)}]
            save
            {*}$say "\002[dict get $feeds($id) name]\002 checked every [dict get $feeds($id) interval] min."
        }
        filter {
            if {$id eq ""} {{*}$say "Usage: !feed filter <name> <words|off>  (-word excludes)"; return 0}
            set words [lrange $w 2 end]
            if {[string tolower [lindex $words 0]] in {off none ""}} {set words {}}
            dict set feeds($id) filter $words
            save
            {*}$say "\002[dict get $feeds($id) name]\002 filter: [expr {[llength $words] ? [join $words] : "off"}]"
        }
        rename {
            set new [lindex $w 2]
            regsub -all {[^\w.-]} $new "" new
            if {$id eq "" || $new eq "" || [find $chan $new] ne ""} {{*}$say "Usage: !feed rename <name> <newname>"; return 0}
            dict set feeds($id) name $new
            save
            {*}$say "Renamed to \002$new\002."
        }
        max {
            set m [lindex $w 2]
            if {$id eq "" || ![string is integer -strict $m] || $m < 1 || $m > 10} {{*}$say "Usage: !feed max <name> <1-10>"; return 0}
            dict set feeds($id) max $m
            save
            {*}$say "\002[dict get $feeds($id) name]\002 announces up to $m items per check."
        }
        test {
            set url [expand $name]
            if {$url eq ""} {{*}$say "Usage: !feed test <url|shortcut>"; return 0}
            ::web::fetch $url [list ::feeds::test_done $chan $url]
        }
        default {
            puthelp "NOTICE $nick :Usage: [::web::b !feed] list | latest <name> \[n\] | test <url> | ops: add <url> \[name\] \[min\] | del | pause | resume | check | interval | filter | rename | max"
        }
    }
    return 1
}

bind dcc m feeds ::feeds::dcc_feeds
proc ::feeds::dcc_feeds {hand idx text} {
    variable feeds
    foreach id [lsort -integer [array names feeds]] {
        set f $feeds($id)
        putdcc $idx [format "#%-3s %-12s %-14s %3sm fails:%-2s %s" $id [dict get $f chan] [dict get $f name] \
            [dict get $f interval] [dict get $f fails] [dict get $f url]]
    }
    putdcc $idx "[array size feeds] feed(s)."
    return 1
}

if {![info exists ::feeds::loaded]} {
    ::feeds::load
    set ::feeds::loaded 1
}

putlog "feeds.tcl loaded ([array size ::feeds::feeds] feeds)"
