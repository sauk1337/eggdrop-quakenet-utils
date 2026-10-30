# =====================================================================
#  wiki.tcl  v1.2.0  -  Wikipedia: summaries, search, random, on this day
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Searches Wikipedia in any language and answers with the summary of
#    the best match. Ambiguous terms list the alternatives. Optional
#    daily "on this day" post. Uses the official Wikipedia APIs, no key.
#
#  REQUIREMENTS
#    web.tcl (load it first), tcl-tls
#
#  SETUP
#    .chanset #chan +wiki
#    .chanset #chan wiki-lang es          default language (default: en)
#    .chanset #chan +otd                  daily "on this day" post
#
#  COMMANDS (channel)
#    !wiki <query>                summary of the best match
#    !wiki <lang>: <query>        another language   (!wiki fr: Paris)
#    !wikisearch <query>          top 5 article titles
#    !wikirandom [lang]           a random article
#    !otd [lang]                  on this day: events of today's date
# =====================================================================

namespace eval ::wiki {
    # ------------------------- CONFIGURATION -------------------------
    variable default_lang "en"
    variable maxlen 330              ;# characters of the extract
    variable throttle 5              ;# seconds between commands per user
    variable otd_hour 9              ;# hour of the daily post (bot time)
    variable otd_events 3            ;# events in a !otd answer

    # --------------------- STATE (do not touch) ---------------------
    variable last
}

setudef flag wiki
setudef flag otd
setudef str wiki-lang

# ----------------------------- HELPERS -----------------------------

proc ::wiki::lang {chan} {
    variable default_lang
    set l [channel get $chan wiki-lang]
    if {[regexp {^[a-z]{2,3}(-[a-z]+)?$} $l]} {return $l}
    return $default_lang
}

proc ::wiki::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

# Splits "es: query" / "es:query" / "query"
proc ::wiki::split_lang {chan text} {
    if {[regexp {^([a-z]{2,3}(?:-[a-z]+)?):\s*(.+)$} [string trim $text] -> l q]} {
        return [list $l $q]
    }
    list [lang $chan] [string trim $text]
}

proc ::wiki::title_path {title} {
    # Titles go in the URL path: spaces -> _, the rest percent-encoded
    # (including "/", which the REST API expects as %2F)
    ::http::mapReply [string map {" " _} $title]
}

proc ::wiki::api {l} {return "https://$l.wikipedia.org"}

# ------------------------------ SEARCH ------------------------------

proc ::wiki::search {l q n callback} {
    set url "[api $l]/w/api.php?[::web::query action query list search srsearch $q srlimit $n srprop "" format json utf8 1]"
    ::web::get $url [list ::wiki::search_done $callback]
}

proc ::wiki::search_done {callback ok code body} {
    set titles {}
    if {$ok && ![catch {::web::json $body} d]} {
        foreach r [::web::dget $d query search] {lappend titles [::web::dget $r title]}
    }
    {*}$callback $titles
}

proc ::wiki::summary {l title callback} {
    ::web::get "[api $l]/api/rest_v1/page/summary/[title_path $title]" [list ::wiki::summary_done $callback]
}

proc ::wiki::summary_done {callback ok code body} {
    set d ""
    if {$ok} {catch {::web::json $body} d}
    {*}$callback $d
}

proc ::wiki::format_summary {d} {
    variable maxlen
    set title [::web::dget $d title]
    set desc [::web::dget $d description]
    set extract [::web::trim [::web::unhtml [::web::dget $d extract]] $maxlen]
    set url [::web::dget $d content_urls desktop page]
    set line [::web::line Wikipedia $title [list $desc]]
    if {$extract ne ""} {append line " $extract"}
    if {$url ne ""} {append line "[::web::sep]$url"}
    return $line
}

# !wiki: search, then summary of the first hit (disambiguation -> list)
proc ::wiki::lookup {target l q} {
    search $l $q 6 [list ::wiki::lookup_found $target $l $q]
}

proc ::wiki::lookup_found {target l q titles} {
    if {![llength $titles]} {
        ::web::say $target [::web::msg Wikipedia "No article found for \"$q\" ($l)."]
        return
    }
    summary $l [lindex $titles 0] [list ::wiki::lookup_summary $target $l $titles]
}

proc ::wiki::lookup_summary {target l titles d} {
    if {$d eq ""} {
        ::web::say $target [::web::msg Wikipedia "Not answering right now ($l)."]
        return
    }
    if {[::web::dget $d type] eq "disambiguation"} {
        set others [lrange $titles 1 5]
        set line "[::web::tag Wikipedia] :: [::web::b [::web::dget $d title]] may refer to several things"
        if {[llength $others]} {append line " ([::web::fields $others])"}
        append line "[::web::sep][::web::dget $d content_urls desktop page]"
        ::web::say $target $line
        return
    }
    ::web::say $target [format_summary $d]
}

# ----------------------------- COMMANDS -----------------------------

bind pub - !wiki ::wiki::pub_wiki
bind pub - !wikipedia ::wiki::pub_wiki
proc ::wiki::pub_wiki {nick uhost hand chan text} {
    if {![channel get $chan wiki] || [flood $uhost]} {return 0}
    lassign [split_lang $chan $text] l q
    if {$q eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !wiki] <query> | [::web::b !wiki] <lang>: <query>"
        return 0
    }
    lookup $chan $l $q
    return 1
}

bind pub - !wikisearch ::wiki::pub_search
proc ::wiki::pub_search {nick uhost hand chan text} {
    if {![channel get $chan wiki] || [flood $uhost]} {return 0}
    lassign [split_lang $chan $text] l q
    if {$q eq ""} {return 0}
    search $l $q 5 [list ::wiki::search_list $chan $l $q]
    return 1
}

proc ::wiki::search_list {target l q titles} {
    if {![llength $titles]} {
        ::web::say $target [::web::msg Wikipedia "No results for \"$q\"."]
        return
    }
    ::web::say $target [::web::line Wikipedia "Search ($l)" $titles]
}

bind pub - !wikirandom ::wiki::pub_random
proc ::wiki::pub_random {nick uhost hand chan text} {
    if {![channel get $chan wiki] || [flood $uhost]} {return 0}
    set l [string tolower [string trim $text]]
    if {![regexp {^[a-z]{2,3}$} $l]} {set l [lang $chan]}
    ::web::get "[api $l]/api/rest_v1/page/random/summary" [list ::wiki::random_done $chan]
    return 1
}

proc ::wiki::random_done {target ok code body} {
    if {!$ok || [catch {::web::json $body} d]} {::web::say $target [::web::msg Wikipedia "Not answering right now."]; return}
    ::web::say $target [format_summary $d]
}

# --------------------------- ON THIS DAY ---------------------------

proc ::wiki::otd {target l {n 0}} {
    variable otd_events
    if {$n <= 0} {set n $otd_events}
    set md [clock format [clock seconds] -format "%m/%d"]
    ::web::get "[api $l]/api/rest_v1/feed/onthisday/selected/$md" [list ::wiki::otd_done $target $l $n]
}

proc ::wiki::otd_done {target l n ok code body} {
    if {!$ok && $l ne "en"} {
        # Not every Wikipedia has this feed: fall back to English
        otd $target en $n
        return
    }
    if {!$ok || [catch {::web::json $body} d] || ![llength [::web::dget $d selected]]} {
        ::web::say $target [::web::msg "On this day" "No data right now."]
        return
    }
    set events [::web::dget $d selected]
    # Pick n random events, then sort them by year
    set picked {}
    while {[llength $picked] < $n && [llength $events]} {
        set i [expr {int(rand() * [llength $events])}]
        lappend picked [lindex $events $i]
        set events [lreplace $events $i $i]
    }
    set picked [lsort -integer -index 1 [lmap e $picked {list $e [::web::dget $e year]}]]
    set parts {}
    foreach p $picked {
        lassign $p e year
        lappend parts "[::web::lbl $year [::web::trim [::web::unhtml [::web::dget $e text]] 160]]"
    }
    ::web::say $target "[::web::tag {On this day}] :: [::web::b [clock format [clock seconds] -format {%d %B}]] ([::web::fields $parts])"
}

bind pub - !otd ::wiki::pub_otd
bind pub - !onthisday ::wiki::pub_otd
bind pub - !efemerides ::wiki::pub_otd
proc ::wiki::pub_otd {nick uhost hand chan text} {
    if {![channel get $chan wiki] || [flood $uhost]} {return 0}
    set l [string tolower [string trim $text]]
    if {![regexp {^[a-z]{2,3}$} $l]} {set l [lang $chan]}
    otd $chan $l
    return 1
}

bind time - "00 * * * *" ::wiki::hourly
proc ::wiki::hourly {min hour day month year} {
    variable otd_hour
    if {[scan $hour %d] != $otd_hour} return
    foreach chan [channels] {
        if {[channel get $chan otd] && [botonchan $chan]} {otd $chan [lang $chan]}
    }
}

putlog "wiki.tcl loaded"
