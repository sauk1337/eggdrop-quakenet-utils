# =====================================================================
#  github.tcl  v1.2.1  -  GitHub profile tracker and lookups
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Follows the GitHub users and organisations you choose, per channel,
#    and announces what they do: pushes, releases, new repositories and
#    tags, forks, repos made public, pull requests and issues (stars are
#    off by default). Each channel picks its own profiles and, per
#    profile, which kinds of activity it wants to see.
#    - New repositories are seen at once from the profile's repository
#      list. Pushes, releases, PRs and issues come from GitHub's public
#      events feed, which GitHub warns can lag from 30 seconds to a few
#      hours. Private repositories and their activity are never visible.
#    - Uses the public events API with ETag: a "nothing new" answer
#      (304) doesn't count against GitHub's rate limit.
#    - Profiles are checked one at a time, spread over the minutes, and
#      the script waits by itself if GitHub says the limit is reached.
#    - The first check of a profile only records its current activity;
#      after that, only new events are announced (never older than a day).
#    Also: profile cards (!gh <user>) and repository cards (!gh repo).
#    To follow only the releases of one repository, feeds.tcl can do it
#    too:  !feed add github:owner/repo
#
#  REQUIREMENTS
#    web.tcl (load it before this script), tcl-tls
#    Optional token in secrets.tcl (raises the limit from 60 to 5000
#    requests per hour; a fine-grained token with no permissions is enough):
#      set ::github::token "github_pat_..."
#
#  SETUP
#    .chanset #chan +github            enable commands and announcements
#    Each check uses two requests (events + repository list).
#    Without a token one profile is checked every ~2 minutes, with a token
#    every minute; each profile at most every 10 minutes (settings below).
#
#  COMMANDS
#    !gh <user>                        profile card
#    !gh repo <owner/repo>             repository card
#    !gh repo <user>                   that profile's latest repositories
#    !gh list                          profiles tracked on this channel
#    !gh add <user>                    track a user or organisation (ops)
#    !gh del <user>                    stop tracking it (ops)
#    !gh filter <user> [types|all|default]
#                                      show or choose what to announce (ops)
#                                      types: push release create fork
#                                             public pr issues star
#    !gh check                         check this channel's profiles now and
#                                      say if there is nothing new (ops)
#  PARTYLINE
#    .github                           every tracked profile and its state
# =====================================================================

namespace eval ::github {
    # ------------------------- CONFIGURATION -------------------------

    variable token ""                ;# set it in secrets.tcl
    variable interval 10             ;# minutes between checks of one profile
    variable gap_anon 130            ;# seconds between two checks, no token (2 requests each)
    variable gap_token 50            ;# seconds between two checks, with token
    variable max_age 1440            ;# minutes: older events are never announced
    variable max_announce 3          ;# events per profile and check, then "...and N more"
    variable max_per_chan 15         ;# tracked profiles per channel
    variable default_types {push release create fork public pr issues}
    variable all_types {push release create fork public pr issues star}
    variable datadir "github"        ;# relative to the bot directory

    # --------------------- STATE (do not touch) ---------------------
    # subs(<#chan> <login lower>)  -> dict {user filter by added}
    # users(<login lower>)         -> dict {login etag seen primed checked error}
    variable subs
    variable users
    variable backoff
    variable lastpoll
    if {![info exists backoff]} {set backoff 0}
    if {![info exists lastpoll]} {set lastpoll 0}
}

setudef flag github

# ----------------------------- STORAGE -----------------------------

proc ::github::save {} {
    variable subs
    variable users
    variable datadir
    file mkdir $datadir
    set f [file join $datadir tracked.db]
    set fd [open $f.tmp w]
    fconfigure $fd -encoding utf-8
    foreach k [lsort [array names subs]] {puts $fd [list sub $k $subs($k)]}
    foreach k [lsort [array names users]] {puts $fd [list user $k $users($k)]}
    close $fd
    file rename -force $f.tmp $f
}

proc ::github::load {} {
    variable subs
    variable users
    variable datadir
    array unset subs
    array unset users
    set f [file join $datadir tracked.db]
    if {![file exists $f]} return
    set fd [open $f r]
    fconfigure $fd -encoding utf-8
    while {[gets $fd line] >= 0} {
        if {[catch {lindex $line 0} kind]} continue
        switch -- $kind {
            sub  {set subs([lindex $line 1]) [lindex $line 2]}
            user {set users([lindex $line 1]) [lindex $line 2]}
        }
    }
    close $fd
}

# ----------------------------- HELPERS -----------------------------

proc ::github::valid_user {s} {
    regexp {^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$} $s
}

proc ::github::valid_repo {s} {
    regexp {^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$} $s
}

proc ::github::headers {{etag ""}} {
    variable token
    set h [list User-Agent "eggdrop-quakenet-utils/1.2 (Eggdrop)" \
        Accept "application/vnd.github+json" X-GitHub-Api-Version 2022-11-28]
    if {$token ne ""} {lappend h Authorization "Bearer $token"}
    if {$etag ne ""} {lappend h If-None-Match $etag}
    return $h
}

# Profiles tracked on a channel, as subs() keys
proc ::github::chansubs {chan} {
    variable subs
    lsort [array names subs "[string tolower $chan] *"]
}

# Every channel key that tracks a login
proc ::github::subs_of {luser} {
    variable subs
    set out {}
    foreach k [array names subs] {
        if {[lindex $k 1] eq $luser} {lappend out $k}
    }
    return $out
}

proc ::github::num {n} {
    if {![string is double -strict $n]} {return $n}
    if {$n >= 1000000} {return [format %.1fM [expr {$n / 1e6}]]}
    if {$n >= 10000} {return [format %.0fK [expr {$n / 1e3}]]}
    if {$n >= 1000} {return [format %.1fK [expr {$n / 1e3}]]}
    return $n
}

proc ::github::isotime {s} {
    if {[catch {clock scan [string range $s 0 18] -format "%Y-%m-%dT%H:%M:%S" -gmt 1} t]} {return 0}
    return $t
}

# One clean line of user text: no control codes, no newlines, shortened
# (ASCII "..." so old clients don't show mojibake)
proc ::github::clean {s {n 100}} {
    regsub -all {[\x00-\x1f\x7f]+} $s " " s
    set s [string trim $s]
    if {[string length $s] <= $n} {return $s}
    set cut [string last " " $s $n]
    if {$cut < $n / 2} {set cut $n}
    return "[string trimright [string range $s 0 [expr {$cut - 1}]] { ,.;:}]..."
}

# Rate limit bookkeeping from any API answer
proc ::github::ratelimit {code meta} {
    variable backoff
    set now [clock seconds]
    set remaining [::web::dget $meta x-ratelimit-remaining]
    set reset [::web::dget $meta x-ratelimit-reset]
    set retry [::web::dget $meta retry-after]
    if {[string is integer -strict $retry] && $code in {403 429}} {
        set backoff [expr {$now + $retry + 5}]
    } elseif {$remaining eq "0" && [string is integer -strict $reset]} {
        set backoff [expr {max($now + 60, $reset + 5)}]
    } elseif {$code in {403 429}} {
        set backoff [expr {$now + 600}]
    } else {
        return 0
    }
    putlog "github: rate limit reached, waiting until [clock format $backoff -format %H:%M:%S]"
    return 1
}

proc ::github::limited {} {
    variable backoff
    expr {[clock seconds] < $backoff}
}

proc ::github::flood {uhost} {
    ::web::throttle "github:[lindex [split $uhost @] end]" 3
}

# ----------------------------- EVENTS -----------------------------

proc ::github::kind {type} {
    switch -- $type {
        PushEvent        {return push}
        ReleaseEvent     {return release}
        CreateEvent      {return create}
        ForkEvent        {return fork}
        PublicEvent      {return public}
        PullRequestEvent {return pr}
        IssuesEvent      {return issues}
        WatchEvent       {return star}
    }
    return ""
}

proc ::github::out {text {fields {}}} {
    set line [::web::msg GitHub $text]
    set f [::web::fields $fields]
    if {$f ne ""} {append line " ($f)"}
    return $line
}

# One event -> one line, or "" when it isn't worth announcing
proc ::github::format_event {ev} {
    set who [::web::dget $ev actor display_login]
    if {$who eq ""} {set who [::web::dget $ev actor login]}
    set repo [::web::dget $ev repo name]
    set p [::web::dget $ev payload]
    set rurl "https://github.com/$repo"
    set brepo [::web::b $repo]
    switch -- [::web::dget $ev type] {
        PushEvent {
            set branch [regsub {^refs/(heads|tags)/} [::web::dget $p ref] ""]
            set head [::web::dget $p head]
            set before [::web::dget $p before]
            set commits [::web::dget $p commits]
            set n [::web::dget $p size]
            if {![string is integer -strict $n]} {set n [llength $commits]}
            set what [expr {$n == 1 ? "1 commit" : "$n commits"}]
            if {$n > 0} {
                set text "$who pushed $what to $brepo"
            } else {
                set text "$who pushed to $brepo"
            }
            set last ""
            if {[llength $commits]} {
                set msg [lindex [split [::web::dget [lindex $commits end] message] \n] 0]
                if {$msg ne ""} {set last [::web::lbl Last "\"[clean $msg 90]\""]}
            }
            if {$head eq ""} {
                set link $rurl
            } elseif {$before eq "" || [regexp {^0+$} $before]} {
                set link "$rurl/commit/[string range $head 0 11]"
            } else {
                set link "$rurl/compare/[string range $before 0 11]...[string range $head 0 11]"
            }
            return [out $text [list [::web::lbl Branch $branch] $last $link]]
        }
        ReleaseEvent {
            if {[::web::dget $p action] ni {published released}} {return ""}
            set r [::web::dget $p release]
            set tag [::web::dget $r tag_name]
            set name [clean [::web::dget $r name] 80]
            set pre [expr {[::web::dget $r prerelease] eq "1" ? "pre-release" : ""}]
            if {$name eq $tag} {set name ""}
            set url [::web::dget $r html_url]
            if {$url eq ""} {set url "$rurl/releases/tag/$tag"}
            return [out "$who released $brepo [::web::b $tag]" \
                [list [expr {$name ne "" ? [::web::lbl Name $name] : ""}] $pre $url]]
        }
        CreateEvent {
            set ref [::web::dget $p ref]
            switch -- [::web::dget $p ref_type] {
                repository {
                    set desc [clean [::web::dget $p description] 120]
                    return [out "$who created repository $brepo" \
                        [list [expr {$desc ne "" ? [::web::lbl Description $desc] : ""}] $rurl]]
                }
                tag {
                    return [out "$who tagged $brepo [::web::b $ref]" [list "$rurl/releases/tag/$ref"]]
                }
                branch {
                    return [out "$who created branch [::web::b $ref] in $brepo" [list "$rurl/tree/$ref"]]
                }
            }
            return ""
        }
        ForkEvent {
            set fork [::web::dget $p forkee full_name]
            set url [::web::dget $p forkee html_url]
            if {$url eq "" && $fork ne ""} {set url "https://github.com/$fork"}
            return [out "$who forked $brepo" [list [expr {$fork ne "" ? [::web::lbl Fork $fork] : ""}] $url]]
        }
        PublicEvent {
            return [out "$who made $brepo public" [list $rurl]]
        }
        PullRequestEvent {
            set pr [::web::dget $p pull_request]
            set num [::web::dget $p number]
            if {$num eq ""} {set num [::web::dget $pr number]}
            set action [::web::dget $p action]
            if {$action eq "closed" && [::web::dget $pr merged] eq "1"} {set action merged}
            if {$action ni {opened closed reopened merged}} {return ""}
            set title [clean [::web::dget $pr title] 100]
            set url [::web::dget $pr html_url]
            if {$url eq ""} {set url "$rurl/pull/$num"}
            return [out "$who $action PR #$num in $brepo" \
                [list [expr {$title ne "" ? [::web::lbl Title $title] : ""}] $url]]
        }
        IssuesEvent {
            set is [::web::dget $p issue]
            set action [::web::dget $p action]
            if {$action ni {opened closed reopened}} {return ""}
            set num [::web::dget $is number]
            set title [clean [::web::dget $is title] 100]
            set url [::web::dget $is html_url]
            if {$url eq ""} {set url "$rurl/issues/$num"}
            return [out "$who $action issue #$num in $brepo" \
                [list [expr {$title ne "" ? [::web::lbl Title $title] : ""}] $url]]
        }
        WatchEvent {
            return [out "$who starred $brepo" [list $rurl]]
        }
    }
    return ""
}

# ----------------------------- POLLING -----------------------------

# A check has two steps:
#   1. the public events feed (pushes, releases, PRs...). GitHub warns it
#      can lag from 30 seconds to several hours behind real activity;
#   2. the list of the profile's repositories, which is up to date at
#      once, so a new repository is announced on the next check even
#      while the events feed still hasn't shown it.
# reply = channel that asked with !gh check (it gets an answer even when
# there's nothing new), or "" for the automatic checks.
proc ::github::poll {luser {reply ""}} {
    variable users
    variable lastpoll
    if {![info exists users($luser)] || [limited]} return
    set u $users($luser)
    foreach {k v} {repos {} rprimed 0 retag ""} {
        if {![dict exists $u $k]} {dict set users($luser) $k $v}
    }
    dict set users($luser) checked [clock seconds]
    set lastpoll [clock seconds]
    set etag [expr {[dict get $u primed] ? [dict get $u etag] : ""}]
    ::web::fetch "https://api.github.com/users/[dict get $u login]/events/public?per_page=30" \
        [list ::github::polled $luser $reply] [headers $etag]
}

proc ::github::polled {luser reply ok code body meta} {
    variable users
    variable max_age
    if {![info exists users($luser)]} return
    ratelimit $code $meta
    set list {}
    if {$code == 304} {
        dict set users($luser) error ""
    } elseif {!$ok} {
        set err [expr {$code == 404 ? "user not found" : "HTTP $code"}]
        if {[dict get $users($luser) error] ne $err} {
            putlog "github: [dict get $users($luser) login]: $err"
        }
        dict set users($luser) error $err
        if {$reply ne ""} {::web::say $reply [::web::msg GitHub "[::web::b [dict get $users($luser) login]]: $err"]}
        return
    } elseif {[catch {::web::json [encoding convertfrom utf-8 $body]} events]} {
        putlog "github: [dict get $users($luser) login]: bad JSON"
    } else {
        set u $users($luser)
        dict set u error ""
        dict set u etag [::web::dget $meta etag]
        set seen [dict get $u seen]
        set fresh {}
        foreach ev $events {
            set id [::web::dget $ev id]
            if {$id ne "" && $id ni $seen} {lappend fresh $ev}
        }
        set ids [lmap ev $fresh {::web::dget $ev id}]
        dict set u seen [lrange [concat $ids $seen] 0 99]
        set primed [dict get $u primed]
        dict set u primed 1
        # Oldest first, and never anything too old. The first check only
        # records what is already there.
        set limit [expr {[clock seconds] - $max_age * 60}]
        set known [dict get $u repos]
        foreach ev [lreverse $fresh] {
            # A new repository already announced from the repository list
            # (step 2 of an earlier check) is not announced twice
            if {[::web::dget $ev type] eq "CreateEvent" && [::web::dget $ev payload ref_type] eq "repository"} {
                set rname [string tolower [::web::dget $ev repo name]]
                if {$rname in $known} continue
                lappend known $rname
            }
            if {$primed && [isotime [::web::dget $ev created_at]] >= $limit} {lappend list $ev}
        }
        dict set u repos $known
        set users($luser) $u
    }
    poll_repos $luser $reply $list
}

proc ::github::poll_repos {luser reply events} {
    variable users
    if {![info exists users($luser)]} return
    if {[limited]} {
        # Step 1 hit the rate limit: finish with what it found
        repos_done $luser $reply $events 0 0 "" {}
        return
    }
    set u $users($luser)
    set etag [expr {[dict get $u rprimed] ? [dict get $u retag] : ""}]
    ::web::fetch "https://api.github.com/users/[dict get $u login]/repos?sort=created&direction=desc&per_page=10" \
        [list ::github::repos_done $luser $reply $events] [headers $etag]
}

proc ::github::repos_done {luser reply events ok code body meta} {
    variable users
    if {![info exists users($luser)]} return
    ratelimit $code $meta
    variable subs
    set newrepos {}
    if {$ok && ![catch {::web::json [encoding convertfrom utf-8 $body]} repos]} {
        set u $users($luser)
        set known [dict get $u repos]
        # The first read only records the existing repositories, except
        # those created after the profile was added with !gh add
        set since 0
        if {![dict get $u rprimed]} {
            set since [clock seconds]
            foreach k [subs_of $luser] {
                set since [expr {min($since, [dict get $subs($k) added])}]
            }
        }
        foreach r [lreverse $repos] {
            set rname [string tolower [::web::dget $r full_name]]
            if {$rname eq "" || $rname in $known} continue
            lappend known $rname
            # Forks are announced from the events feed (ForkEvent)
            if {[::web::dget $r fork] eq "1"} continue
            if {[dict get $u rprimed] || [isotime [::web::dget $r created_at]] >= $since} {
                lappend newrepos $r
            }
        }
        dict set u repos [lrange $known end-199 end]
        dict set u rprimed 1
        dict set u retag [::web::dget $meta etag]
        set users($luser) $u
    }
    save
    set said 0
    foreach k [subs_of $luser] {incr said [announce $k $events $newrepos]}
    if {$reply ne "" && !$said} {
        ::web::say $reply [::web::msg GitHub "Nothing new from [::web::b [dict get $users($luser) login]] [::web::dim {(new repositories show at once; pushes and releases can take GitHub a few minutes, sometimes hours, to publish)}]"]
    }
}

# A repository found in the repository list -> one line
proc ::github::format_repo {login r} {
    set fields {}
    set desc [clean [::web::dget $r description] 100]
    if {$desc ne ""} {lappend fields $desc}
    set lang [::web::dget $r language]
    if {$lang ne ""} {lappend fields [::web::lbl Language $lang]}
    lappend fields [::web::dget $r html_url]
    out "$login created repository [::web::b [::web::dget $r full_name]]" $fields
}

# Returns how many lines were sent to the channel
proc ::github::announce {key events {newrepos {}}} {
    variable subs
    variable max_announce
    set chan [lindex $key 0]
    foreach c [channels] {
        if {[string equal -nocase $c $chan]} {set chan $c}
    }
    if {![validchan $chan] || ![channel get $chan github] || ![botonchan $chan]} {return 0}
    set filter [dict get $subs($key) filter]
    set lines {}
    if {"create" in $filter} {
        foreach r $newrepos {lappend lines [format_repo [dict get $subs($key) user] $r]}
    }
    foreach ev $events {
        if {[kind [::web::dget $ev type]] ni $filter} continue
        if {[catch {format_event $ev} line]} {
            putlog "github: event [::web::dget $ev id]: $line"
            continue
        }
        if {$line ne ""} {lappend lines $line}
    }
    foreach line [lrange $lines 0 [expr {$max_announce - 1}]] {
        ::web::say $chan $line
    }
    set more [expr {[llength $lines] - $max_announce}]
    if {$more > 0} {
        ::web::say $chan [::web::msg GitHub "...and $more more from [::web::b [dict get $subs($key) user]] [::web::dim https://github.com/[dict get $subs($key) user]]"]
    }
    return [llength $lines]
}

# Every minute: check the profile that is most overdue, if any
bind time - "* * * * *" ::github::tick
proc ::github::tick {args} {
    variable users
    variable interval
    variable token
    variable gap_anon
    variable gap_token
    variable lastpoll
    if {[limited]} return
    set now [clock seconds]
    set gap [expr {$token ne "" ? $gap_token : $gap_anon}]
    if {$now - $lastpoll < $gap} return
    set best ""
    set oldest $now
    foreach luser [array names users] {
        set active 0
        foreach k [subs_of $luser] {
            set chan [lindex $k 0]
            if {[validchan $chan] && [channel get $chan github]} {set active 1; break}
        }
        if {!$active} continue
        set checked [dict get $users($luser) checked]
        if {$now - $checked < $interval * 60} continue
        if {$checked < $oldest || $best eq ""} {
            set best $luser
            set oldest $checked
        }
    }
    if {$best ne ""} {poll $best}
}

# ----------------------------- COMMANDS -----------------------------

bind pub - !gh ::github::pub_gh
bind pub - !github ::github::pub_gh
proc ::github::pub_gh {nick uhost hand chan text} {
    variable subs
    variable users
    variable max_per_chan
    variable default_types
    variable all_types
    if {![channel get $chan github] || [flood $uhost]} {return 0}
    set w [regexp -all -inline {\S+} $text]
    set sub [string tolower [lindex $w 0]]
    set arg [lindex $w 1]
    set say [list ::web::say $chan]
    set lchan [string tolower $chan]
    if {$sub in {add del delete rm filter check} && ![matchattr $hand o|o $chan]} {
        puthelp "NOTICE $nick :Only bot ops can change the GitHub profiles of $chan."
        return 0
    }
    switch -- $sub {
        "" {
            puthelp "NOTICE $nick :Usage: [::web::b {!gh <user>}] | [::web::b {!gh repo <owner/repo|user>}] | [::web::b {!gh list}] | ops: [::web::b {!gh add|del <user>}], [::web::b {!gh filter <user> [types]}], [::web::b {!gh check}]"
        }
        add {
            if {![valid_user $arg]} {{*}$say [::web::msg GitHub "Usage: !gh add <user>"]; return 0}
            set key "$lchan [string tolower $arg]"
            if {[info exists subs($key)]} {{*}$say [::web::msg GitHub "Already tracking [::web::b [dict get $subs($key) user]] here."]; return 0}
            if {[llength [chansubs $chan]] >= $max_per_chan} {{*}$say [::web::msg GitHub "This channel already tracks $max_per_chan profiles."]; return 0}
            if {[limited]} {{*}$say [::web::msg GitHub "GitHub's rate limit is reached, try again later."]; return 0}
            ::web::fetch "https://api.github.com/users/$arg" [list ::github::add_done $chan $nick $arg] [headers]
        }
        del - delete - rm {
            set key "$lchan [string tolower $arg]"
            if {$arg eq "" || ![info exists subs($key)]} {{*}$say [::web::msg GitHub "Not tracking \"$arg\" here. See !gh list"]; return 0}
            set login [dict get $subs($key) user]
            unset subs($key)
            set luser [string tolower $arg]
            if {![llength [subs_of $luser]]} {unset -nocomplain users($luser)}
            save
            {*}$say [::web::msg GitHub "No longer tracking [::web::b $login] on $chan."]
        }
        list {
            set keys [chansubs $chan]
            if {![llength $keys]} {{*}$say [::web::msg GitHub "No profiles tracked here. Ops: !gh add <user>"]; return 0}
            set items {}
            foreach k $keys {
                set s $subs($k)
                set item [::web::b [dict get $s user]]
                if {[lsort [dict get $s filter]] ne [lsort $default_types]} {
                    append item " [::web::dim ([join [dict get $s filter] {, }])]"
                }
                lappend items $item
            }
            {*}$say "[::web::msg GitHub "Tracking [llength $keys] profile[expr {[llength $keys] == 1 ? {} : {s}}] on $chan"] ([::web::fields $items])"
        }
        filter {
            set key "$lchan [string tolower $arg]"
            if {$arg eq "" || ![info exists subs($key)]} {{*}$say [::web::msg GitHub "Usage: !gh filter <user> \[[join $all_types { }]|all|default\]"]; return 0}
            set types [string tolower [lrange $w 2 end]]
            if {![llength $types]} {
                {*}$say [::web::msg GitHub "[::web::b [dict get $subs($key) user]] announces: [join [dict get $subs($key) filter] {, }]"]
                return 0
            }
            if {$types eq "all"} {
                set types $all_types
            } elseif {$types eq "default"} {
                set types $default_types
            }
            set bad [lmap t $types {expr {$t in $all_types ? [continue] : $t}}]
            if {[llength $bad]} {{*}$say [::web::msg GitHub "Unknown type: [join $bad {, }]. Types: [join $all_types { }]"]; return 0}
            dict set subs($key) filter [lsort -unique $types]
            save
            {*}$say [::web::msg GitHub "[::web::b [dict get $subs($key) user]] now announces: [join [dict get $subs($key) filter] {, }]"]
        }
        check {
            set keys [chansubs $chan]
            if {![llength $keys]} {{*}$say [::web::msg GitHub "No profiles tracked here."]; return 0}
            if {[limited]} {{*}$say [::web::msg GitHub "GitHub's rate limit is reached, try again later."]; return 0}
            set delay 0
            foreach k $keys {utimer [incr delay 2] [list ::github::poll [lindex $k 1] $chan]}
            {*}$say [::web::msg GitHub "Checking [llength $keys] profile[expr {[llength $keys] == 1 ? {} : {s}}]..."]
        }
        repo - repos {
            regsub {^https?://github\.com/} $arg "" arg
            set arg [string trimright $arg /]
            if {[limited]} {{*}$say [::web::msg GitHub "GitHub's rate limit is reached, try again later."]; return 0}
            if {[valid_user $arg]} {
                # !gh repo <user>: that profile's latest repositories
                ::web::fetch "https://api.github.com/users/$arg/repos?sort=pushed&direction=desc&per_page=8" \
                    [list ::github::repos_list $chan $arg] [headers]
                return 1
            }
            if {![valid_repo $arg]} {{*}$say [::web::msg GitHub "Usage: !gh repo <owner/repo> | !gh repo <user>"]; return 0}
            ::web::fetch "https://api.github.com/repos/$arg" [list ::github::repo_done $chan $arg] [headers]
        }
        default {
            set user [lindex $w 0]
            regsub {^https?://github\.com/} $user "" user
            set user [string trimright $user /]
            if {![valid_user $user]} {{*}$say [::web::msg GitHub "Usage: !gh <user> | !gh repo <owner/repo>"]; return 0}
            if {[limited]} {{*}$say [::web::msg GitHub "GitHub's rate limit is reached, try again later."]; return 0}
            ::web::fetch "https://api.github.com/users/$user" [list ::github::user_done $chan $user] [headers]
        }
    }
    return 1
}

proc ::github::answer {code meta body} {
    ratelimit $code $meta
    if {[catch {::web::json [encoding convertfrom utf-8 $body]} d]} {return ""}
    return $d
}

proc ::github::add_done {chan nick arg ok code body meta} {
    variable subs
    variable users
    variable default_types
    set d [answer $code $meta $body]
    if {$code == 404} {::web::say $chan [::web::msg GitHub "No GitHub user or organisation called \"$arg\"."]; return}
    if {!$ok || $d eq ""} {::web::say $chan [::web::msg GitHub "GitHub didn't answer (HTTP $code), try again later."]; return}
    set login [::web::dget $d login]
    set luser [string tolower $login]
    set key "[string tolower $chan] $luser"
    set subs($key) [dict create user $login filter $default_types by $nick added [clock seconds]]
    if {![info exists users($luser)]} {
        set users($luser) [dict create login $login etag "" seen {} primed 0 checked 0 error ""]
        utimer 3 [list ::github::poll $luser]
    }
    save
    set type [expr {[::web::dget $d type] eq "Organization" ? "organisation" : "user"}]
    ::web::say $chan "[::web::msg GitHub "Now tracking $type [::web::b $login] on $chan"] ([::web::fields [list [::web::lbl Announces [join $default_types {, }]] [::web::dget $d html_url]]])"
}

proc ::github::user_done {chan arg ok code body meta} {
    set d [answer $code $meta $body]
    if {$code == 404} {::web::say $chan [::web::msg GitHub "No GitHub user or organisation called \"$arg\"."]; return}
    if {!$ok || $d eq ""} {::web::say $chan [::web::msg GitHub "GitHub didn't answer (HTTP $code), try again later."]; return}
    set login [::web::dget $d login]
    set name [clean [::web::dget $d name] 60]
    set title [expr {$name ne "" && $name ne $login ? "$name ($login)" : $login}]
    if {[::web::dget $d type] eq "Organization"} {append title " [::web::dim org]"}
    set fields {}
    set bio [clean [::web::dget $d bio] 120]
    if {$bio ne ""} {lappend fields $bio}
    lappend fields [::web::lbl Repos [num [::web::dget $d public_repos]]]
    lappend fields [::web::lbl Followers [num [::web::dget $d followers]]]
    if {[::web::dget $d type] ne "Organization"} {
        lappend fields [::web::lbl Following [num [::web::dget $d following]]]
    }
    set created [isotime [::web::dget $d created_at]]
    if {$created} {lappend fields [::web::lbl Since [clock format $created -format "%b %Y" -gmt 1]]}
    set loc [clean [::web::dget $d location] 40]
    if {$loc ne ""} {lappend fields [::web::lbl Location $loc]}
    set blog [clean [::web::dget $d blog] 60]
    if {$blog ne ""} {lappend fields [::web::lbl Web $blog]}
    lappend fields [::web::dget $d html_url]
    ::web::say $chan [::web::line GitHub $title $fields]
}

proc ::github::repos_list {chan arg ok code body meta} {
    set d [answer $code $meta $body]
    if {$code == 404} {::web::say $chan [::web::msg GitHub "No GitHub user or organisation called \"$arg\"."]; return}
    if {!$ok} {::web::say $chan [::web::msg GitHub "GitHub didn't answer (HTTP $code), try again later."]; return}
    if {![llength $d]} {::web::say $chan [::web::msg GitHub "[::web::b $arg] has no public repositories."]; return}
    set items {}
    foreach r $d {
        set item [::web::b [::web::dget $r name]]
        set lang [::web::dget $r language]
        set stars [::web::dget $r stargazers_count]
        set extra {}
        if {$lang ne ""} {lappend extra $lang}
        if {[string is integer -strict $stars] && $stars > 0} {lappend extra "[num $stars] stars"}
        if {[llength $extra]} {append item " [::web::dim [join $extra {, }]]"}
        lappend items $item
    }
    ::web::say $chan [::web::line GitHub "Latest repositories of $arg" [concat $items [list https://github.com/$arg?tab=repositories]]]
}

proc ::github::repo_done {chan arg ok code body meta} {
    set d [answer $code $meta $body]
    if {$code == 404} {::web::say $chan [::web::msg GitHub "No repository called \"$arg\" (or it's private)."]; return}
    if {!$ok || $d eq ""} {::web::say $chan [::web::msg GitHub "GitHub didn't answer (HTTP $code), try again later."]; return}
    set title [::web::dget $d full_name]
    if {[::web::dget $d archived] eq "1"} {append title " [::web::dim archived]"}
    if {[::web::dget $d fork] eq "1"} {append title " [::web::dim fork]"}
    set fields {}
    set desc [clean [::web::dget $d description] 120]
    if {$desc ne ""} {lappend fields $desc}
    lappend fields [::web::lbl Stars [num [::web::dget $d stargazers_count]]]
    lappend fields [::web::lbl Forks [num [::web::dget $d forks_count]]]
    set lang [::web::dget $d language]
    if {$lang ne ""} {lappend fields [::web::lbl Language $lang]}
    lappend fields [::web::lbl Issues [num [::web::dget $d open_issues_count]]]
    set pushed [isotime [::web::dget $d pushed_at]]
    if {$pushed} {lappend fields [::web::lbl Updated [::timeutil::rel $pushed]]}
    set lic [::web::dget $d license spdx_id]
    if {$lic ne "" && $lic ne "NOASSERTION"} {lappend fields [::web::lbl License $lic]}
    lappend fields [::web::dget $d html_url]
    ::web::say $chan [::web::line GitHub $title $fields]
}

# ----------------------------- PARTYLINE -----------------------------

bind dcc o github ::github::dcc_github
proc ::github::dcc_github {hand idx text} {
    variable subs
    variable users
    variable backoff
    set now [clock seconds]
    if {![array size subs]} {
        putdcc $idx "github: no profiles tracked (on IRC: !gh add <user>)"
        return 1
    }
    foreach k [lsort [array names subs]] {
        lassign $k chan luser
        set s $subs($k)
        set state "never checked"
        if {[info exists users($luser)]} {
            set u $users($luser)
            if {[dict get $u checked]} {set state "checked [duration [expr {max(1, $now - [dict get $u checked])}]] ago"}
            if {[dict get $u error] ne ""} {append state ", error: [dict get $u error]"}
        }
        putdcc $idx [format "  %-15s %-20s %-30s %s" $chan [dict get $s user] [join [dict get $s filter] ,] $state]
    }
    if {$backoff > $now} {putdcc $idx "github: rate limited until [clock format $backoff -format %H:%M:%S]"}
    putdcc $idx "github: [array size subs] subscriptions, [array size users] profiles"
    return 1
}

# ----------------------------- START -----------------------------

if {![array exists ::github::subs]} {::github::load}

putlog "github.tcl loaded (GitHub profile tracker: !gh)"
