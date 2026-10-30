# =====================================================================
#  chanstats.tcl  v1.2.0  -  Channel statistics and HTML stats page
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Per user: lines, words, characters, /me, questions, shouting,
#    smileys, kicks given/received, joins, first/last seen and a random
#    quote. Per channel: activity by hour, lines per day (31 days) and
#    most used words. Optional pisg-style web page, dark mode aware.
#
#  REQUIREMENTS
#    web.tcl (load it first, for the output style)
#    a web server to publish the HTML page (optional, e.g. nginx or Caddy)
#
#  SETUP
#    .chanset #chan +chanstats
#    In the script: set htmldir / htmlurl for the web page
#
#  COMMANDS (channel)
#    !stats [nick]       user summary and rank
#    !top [lines|words|questions|shouts|smileys|actions|kicks|kicked|joins]
#    !hours | !today | !words | !chanstats
#  PARTYLINE
#    .chanstats-reset #chan | .chanstats-html     (master)
# =====================================================================

namespace eval ::chanstats {
    # ------------------------- CONFIGURATION -------------------------
    variable datadir "chanstats"     ;# relative to the bot directory
    variable htmldir ""              ;# e.g. /var/www/html/stats  ("" = no HTML)
    variable htmlurl ""              ;# public URL of htmldir, shown by !chanstats
    variable html_every 30           ;# minutes
    variable html_top 25             ;# users in the HTML ranking
    variable ignore_nicks {Q L S}    ;# bots that shouldn't count
    variable throttle 10             ;# seconds between commands per channel
    variable min_wordlen 4
    variable max_words 3000          ;# words kept per channel
    variable stopwords {
        that this with have from they what when your just like will there
        their them then than were been about would could should which these
        those into some only also very much more here because http https www
        para pero como esta este todo porque pues bueno cuando donde tambien
        algo muy solo tiene hace eso esto estoy estas nada creo
    }

    # --------------------- STATE (do not touch) ---------------------
    variable users                   ;# users($c,$nick) -> dict
    variable hours                   ;# hours($c) -> list of 24 counters
    variable days                    ;# days($c) -> dict YYYY-MM-DD -> lines
    variable words                   ;# words($c) -> dict word -> count
    variable names                   ;# names($c) -> channel name as typed
    variable lastcmd
    variable loaded
}

setudef flag chanstats

# ----------------------------- HELPERS -----------------------------

proc ::chanstats::fmt {n} {
    regsub -all {\d(?=(\d{3})+$)} $n {&,}
}

proc ::chanstats::ago {t} {
    set d [expr {[clock seconds] - $t}]
    if {$d < 60} {return "just now"}
    foreach {secs unit} {31536000 year 2592000 month 86400 day 3600 hour 60 minute} {
        if {$d >= $secs} {
            set n [expr {$d / $secs}]
            return "$n $unit[expr {$n == 1 ? "" : "s"}] ago"
        }
    }
}

proc ::chanstats::spark {values} {
    # Pure ASCII: block characters show as mojibake on old mIRC versions
    set bars [list _ . - : = + * #]
    set max [tcl::mathfunc::max 1 {*}$values]
    set out ""
    foreach v $values {
        append out [lindex $bars [expr {$v == 0 ? 0 : min(7, int(ceil($v * 8.0 / $max)) - 1)}]]
    }
    return $out
}

proc ::chanstats::ignored {nick hand} {
    variable ignore_nicks
    expr {[isbotnick $nick] || [lsearch -exact -nocase $ignore_nicks $nick] >= 0 || [matchattr $hand b]}
}

proc ::chanstats::chankey {chan} {
    variable names
    set c [string tolower $chan]
    set names($c) $chan
    return $c
}

proc ::chanstats::user {c nick} {
    variable users
    set k "$c,[string tolower $nick]"
    if {![info exists users($k)]} {
        set now [clock seconds]
        set users($k) [dict create nick $nick lines 0 words 0 chars 0 actions 0 \
            questions 0 shouts 0 smileys 0 kicks 0 kicked 0 joins 0 \
            first $now last $now quote ""]
    }
    return $k
}

# All user keys of a channel
proc ::chanstats::chanusers {c} {
    variable users
    set out {}
    set p "$c,"
    set len [string length $p]
    foreach k [array names users] {
        if {[string equal -length $len $p $k]} {lappend out $k}
    }
    return $out
}

# Ranking: list of {nick value} sorted descending
proc ::chanstats::ranking {c field} {
    variable users
    set l {}
    foreach k [chanusers $c] {
        set v [dict get $users($k) $field]
        if {$v > 0} {lappend l [list [dict get $users($k) nick] $v]}
    }
    lsort -integer -decreasing -index 1 $l
}

# ----------------------------- TRACKING -----------------------------

proc ::chanstats::record {nick hand chan text action} {
    variable users
    variable hours
    variable days
    variable words
    variable min_wordlen
    variable stopwords
    if {![channel get $chan chanstats] || [ignored $nick $hand]} return
    set plain [string trim [stripcodes bcruag $text]]
    if {$plain eq ""} return
    set c [chankey $chan]
    set k [user $c $nick]
    set wl [regexp -all -inline {\S+} $plain]

    dict set users($k) nick $nick
    dict set users($k) last [clock seconds]
    dict incr users($k) lines
    dict incr users($k) words [llength $wl]
    dict incr users($k) chars [string length $plain]
    if {$action} {dict incr users($k) actions}
    if {[string index $plain end] eq "?"} {dict incr users($k) questions}
    set letters [regexp -all {[[:alpha:]]} $plain]
    if {$letters >= 8 && [regexp -all {[[:upper:]]} $plain] * 100 / $letters >= 70} {
        dict incr users($k) shouts
    }
    set sm [regexp -all {(?:^|\s)(?:[:;=8xX][-o']?[)(DPp/\\|3]|<3|\^\^|xD|XD)(?=\s|$)} $plain]
    if {$sm} {dict incr users($k) smileys $sm}

    # Random quote (reservoir sampling over eligible lines)
    set len [string length $plain]
    if {$len >= 20 && $len <= 250 && ![string match {[!.]*} $plain]} {
        if {[dict get $users($k) quote] eq "" || rand() * [dict get $users($k) lines] < 1} {
            dict set users($k) quote $plain
        }
    }

    if {![info exists hours($c)]} {set hours($c) [lrepeat 24 0]}
    set h [scan [clock format [clock seconds] -format %H] %d]
    lset hours($c) $h [expr {[lindex $hours($c) $h] + 1}]

    if {![info exists days($c)]} {set days($c) [dict create]}
    dict incr days($c) [clock format [clock seconds] -format %Y-%m-%d]

    if {![info exists words($c)]} {set words($c) [dict create]}
    foreach w $wl {
        set w [string tolower [string trim $w ".,;:!?¡¿()\[\]{}\"'*_-"]]
        if {[string length $w] < $min_wordlen || [string match *://* $w] ||
            ![regexp {^[[:alpha:]]+$} $w] || $w in $stopwords} continue
        dict incr words($c) $w
    }
}

bind pubm - * ::chanstats::on_pubm
proc ::chanstats::on_pubm {nick uhost hand chan text} {
    record $nick $hand $chan $text 0
}

bind ctcp - ACTION ::chanstats::on_action
proc ::chanstats::on_action {nick uhost hand dest key text} {
    if {[validchan $dest]} {record $nick $hand $dest $text 1}
    return 0
}

bind kick - * ::chanstats::on_kick
proc ::chanstats::on_kick {nick uhost hand chan target reason} {
    variable users
    if {![channel get $chan chanstats]} return
    set c [chankey $chan]
    if {![ignored $nick $hand]} {dict incr users([user $c $nick]) kicks}
    if {![isbotnick $target]} {dict incr users([user $c $target]) kicked}
}

bind join - * ::chanstats::on_join
proc ::chanstats::on_join {nick uhost hand chan} {
    variable users
    if {![channel get $chan chanstats] || [ignored $nick $hand]} return
    dict incr users([user [chankey $chan] $nick]) joins
}

# ----------------------------- COMMANDS -----------------------------

proc ::chanstats::allowed {chan} {
    variable lastcmd
    variable throttle
    if {![channel get $chan chanstats]} {return 0}
    set c [string tolower $chan]
    set now [clock seconds]
    if {[info exists lastcmd($c)] && $now - $lastcmd($c) < $throttle} {return 0}
    set lastcmd($c) $now
    return 1
}

bind pub - !stats ::chanstats::cmd_stats
proc ::chanstats::cmd_stats {nick uhost hand chan text} {
    variable users
    if {![allowed $chan]} {return 0}
    set who [lindex [split [string trim $text]] 0]
    if {$who eq ""} {set who $nick}
    set c [string tolower $chan]
    set k "$c,[string tolower $who]"
    if {![info exists users($k)] || [dict get $users($k) lines] == 0} {
        puthelp "PRIVMSG $chan :[::web::msg Stats "No stats for [::web::b $who] on $chan yet."]"
        return 1
    }
    set u $users($k)
    set rank [lsearch -exact -index 0 -nocase [ranking $c lines] [dict get $u nick]]
    set total [llength [ranking $c lines]]
    set lines [dict get $u lines]
    set wpl [format %.1f [expr {double([dict get $u words]) / $lines}]]
    set qp [expr {[dict get $u questions] * 100 / $lines}]
    puthelp "PRIVMSG $chan :[::web::line Stats [dict get $u nick] [list \
        [::web::lbl Lines "[fmt $lines] (#[expr {$rank + 1}] of $total)"] \
        [::web::lbl Words "[fmt [dict get $u words]] ($wpl/line)"] \
        [::web::lbl Questions $qp%] \
        [::web::lbl Actions [dict get $u actions]] \
        [::web::lbl Smileys [dict get $u smileys]] \
        [::web::lbl Kicks [dict get $u kicks]] \
        [::web::lbl "First seen" [ago [dict get $u first]]] \
        [::web::lbl "Last spoke" [ago [dict get $u last]]]]]"
    return 1
}

bind pub - !top ::chanstats::cmd_top
proc ::chanstats::cmd_top {nick uhost hand chan text} {
    if {![allowed $chan]} {return 0}
    set types {lines words questions shouts smileys actions kicks kicked joins}
    set field [string tolower [lindex [split [string trim $text]] 0]]
    if {$field eq ""} {set field lines}
    if {$field ni $types} {
        puthelp "NOTICE $nick :Usage: [::web::b !top] \[[join $types |]\]"
        return 0
    }
    set out {}
    set i 0
    foreach row [lrange [ranking [string tolower $chan] $field] 0 9] {
        lassign $row n v
        lappend out "[incr i]. $n ([fmt $v])"
    }
    if {![llength $out]} {
        puthelp "PRIVMSG $chan :[::web::msg Top "No data yet."]"
    } else {
        puthelp "PRIVMSG $chan :[::web::msg Top "[::web::b "$field on $chan"]: [::web::fields $out]"]"
    }
    return 1
}

bind pub - !hours ::chanstats::cmd_hours
proc ::chanstats::cmd_hours {nick uhost hand chan text} {
    variable hours
    if {![allowed $chan]} {return 0}
    set c [string tolower $chan]
    if {![info exists hours($c)]} {puthelp "PRIVMSG $chan :[::web::msg Stats "No data yet."]"; return 1}
    set h $hours($c)
    set peak [lsearch -exact $h [tcl::mathfunc::max {*}$h]]
    puthelp "PRIVMSG $chan :[::web::line Stats "Activity by hour on $chan" [list \
        [::web::lbl 00-23 [spark $h]] [::web::lbl Peak [format %02d:00 $peak]]]]"
    return 1
}

bind pub - !today ::chanstats::cmd_today
proc ::chanstats::cmd_today {nick uhost hand chan text} {
    variable days
    if {![allowed $chan]} {return 0}
    set c [string tolower $chan]
    if {![info exists days($c)]} {puthelp "PRIVMSG $chan :[::web::msg Stats "No data yet."]"; return 1}
    set vals {}
    for {set i 13} {$i >= 0} {incr i -1} {
        set d [clock format [clock add [clock seconds] -$i days] -format %Y-%m-%d]
        lappend vals [expr {[dict exists $days($c) $d] ? [dict get $days($c) $d] : 0}]
    }
    puthelp "PRIVMSG $chan :[::web::line Stats "Activity on $chan" [list \
        [::web::lbl Today "[fmt [lindex $vals end]] lines"] [::web::lbl "Last 14 days" [spark $vals]]]]"
    return 1
}

bind pub - !words ::chanstats::cmd_words
proc ::chanstats::cmd_words {nick uhost hand chan text} {
    variable words
    if {![allowed $chan]} {return 0}
    set c [string tolower $chan]
    if {![info exists words($c)] || ![dict size $words($c)]} {puthelp "PRIVMSG $chan :[::web::msg Stats "No data yet."]"; return 1}
    set out {}
    foreach {w n} [lrange [lsort -stride 2 -index 1 -integer -decreasing $words($c)] 0 19] {
        lappend out "$w ($n)"
    }
    puthelp "PRIVMSG $chan :[::web::msg Stats "[::web::b "Most used words"]: [::web::fields $out]"]"
    return 1
}

bind pub - !chanstats ::chanstats::cmd_chanstats
proc ::chanstats::cmd_chanstats {nick uhost hand chan text} {
    variable users
    variable htmldir
    variable htmlurl
    if {![allowed $chan]} {return 0}
    set c [string tolower $chan]
    set lines 0
    set words 0
    set n 0
    foreach k [chanusers $c] {
        incr lines [dict get $users($k) lines]
        incr words [dict get $users($k) words]
        incr n
    }
    set f [list [::web::lbl Lines [fmt $lines]] [::web::lbl Words [fmt $words]] [::web::lbl Users [fmt $n]]]
    if {$htmldir ne "" && $htmlurl ne ""} {lappend f [::web::lbl "Full stats" "$htmlurl/[safe $c].html"]}
    puthelp "PRIVMSG $chan :[::web::line Stats $chan $f]"
    return 1
}

# ----------------------------- STORAGE -----------------------------

proc ::chanstats::safe {c} {
    regsub -all {[^A-Za-z0-9_-]} [string trimleft $c "#&"] _
}

proc ::chanstats::save {args} {
    variable users
    variable hours
    variable days
    variable words
    variable names
    variable datadir
    variable max_words
    file mkdir $datadir
    set cutoff [clock format [clock add [clock seconds] -31 days] -format %Y-%m-%d]
    foreach c [array names names] {
        # Trim old days and rare words to keep files small
        if {[info exists days($c)]} {
            set days($c) [dict filter $days($c) script {d n} {expr {$d >= $cutoff}}]
        }
        if {[info exists words($c)] && [dict size $words($c)] > $max_words} {
            set words($c) [lrange [lsort -stride 2 -index 1 -integer -decreasing $words($c)] 0 [expr {$max_words * 2 - 1}]]
        }
        set ul {}
        foreach k [chanusers $c] {lappend ul $users($k)}
        set data [dict create chan $names($c) users $ul \
            hours [expr {[info exists hours($c)] ? $hours($c) : [lrepeat 24 0]}] \
            days [expr {[info exists days($c)] ? $days($c) : {}}] \
            words [expr {[info exists words($c)] ? $words($c) : {}}]]
        set f [file join $datadir [safe $c].db]
        set fd [open $f.tmp w]
        fconfigure $fd -encoding utf-8
        puts $fd $data
        close $fd
        file rename -force $f.tmp $f
    }
}

proc ::chanstats::load {} {
    variable users
    variable hours
    variable days
    variable words
    variable names
    variable datadir
    foreach f [glob -nocomplain -directory $datadir *.db] {
        if {[catch {
            set fd [open $f r]
            fconfigure $fd -encoding utf-8
            set data [read $fd]
            close $fd
            set chan [dict get $data chan]
            set c [string tolower $chan]
            set names($c) $chan
            foreach u [dict get $data users] {
                set users($c,[string tolower [dict get $u nick]]) $u
            }
            set hours($c) [dict get $data hours]
            set days($c) [dict get $data days]
            set words($c) [dict get $data words]
        } err]} {
            putlog "chanstats: could not load $f: $err"
        }
    }
}

# ------------------------------ HTML ------------------------------

proc ::chanstats::esc {s} {
    string map {& &amp; < &lt; > &gt; \" &quot; ' &#39;} $s
}

proc ::chanstats::html {c} {
    variable users
    variable hours
    variable days
    variable words
    variable names
    variable html_top
    set chan $names($c)
    set ukeys [chanusers $c]
    set lines 0
    set wordsum 0
    foreach k $ukeys {
        incr lines [dict get $users($k) lines]
        incr wordsum [dict get $users($k) words]
    }
    set h [expr {[info exists hours($c)] ? $hours($c) : [lrepeat 24 0]}]
    set hmax [tcl::mathfunc::max 1 {*}$h]
    set dvals {}
    set dlabels {}
    for {set i 30} {$i >= 0} {incr i -1} {
        set t [clock add [clock seconds] -$i days]
        set d [clock format $t -format %Y-%m-%d]
        lappend dvals [expr {[info exists days($c)] && [dict exists $days($c) $d] ? [dict get $days($c) $d] : 0}]
        lappend dlabels [clock format $t -format "%b %d"]
    }
    set dmax [tcl::mathfunc::max 1 {*}$dvals]

    set o "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
    append o "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    append o "<title>[esc $chan] stats</title><style>"
    append o {
:root{--bg:#f7f7f5;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e3e3e0;--accent:#3d6fd8;--accent2:#9db6ec}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--card:#1e1e21;--text:#ececef;--muted:#9a9aa2;--line:#2e2e33;--accent:#6f98f0;--accent2:#34497a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1000px;margin:0 auto;padding:24px 16px 48px}h1{font-size:28px;margin:0 0 4px}h2{font-size:17px;margin:0 0 12px}
.muted{color:var(--muted);font-size:13px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0}
.card,section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}section{margin-top:16px;overflow-x:auto}
.big{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums}.bars{display:flex;align-items:flex-end;gap:3px;height:140px}
.bars div{flex:1;background:var(--accent);border-radius:3px 3px 0 0;min-height:2px}.bars div:hover{background:var(--accent2)}
.axis{display:flex;gap:3px;font-size:11px;color:var(--muted)}.axis span{flex:1;text-align:center}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:7px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:500;font-size:12px;text-transform:uppercase}td.n{text-align:right;font-variant-numeric:tabular-nums}
td.q{color:var(--muted);font-style:italic;max-width:380px}.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:8px 24px}
.tags span{display:inline-block;margin:3px;padding:3px 9px;border:1px solid var(--line);border-radius:99px;font-size:13px}
}
    append o "</style></head><body><main>"
    append o "<h1>[esc $chan]</h1><div class=\"muted\">QuakeNet &middot; generated [clock format [clock seconds] -format {%Y-%m-%d %H:%M}]</div>"

    set today [lindex $dvals end]
    append o "<div class=\"cards\">"
    foreach {label val} [list "Lines" [fmt $lines] "Words" [fmt $wordsum] "Users" [fmt [llength $ukeys]] "Lines today" [fmt $today]] {
        append o "<div class=\"card\"><div class=\"muted\">$label</div><div class=\"big\">$val</div></div>"
    }
    append o "</div>"

    append o "<section><h2>Activity by hour</h2><div class=\"bars\">"
    for {set i 0} {$i < 24} {incr i} {
        set v [lindex $h $i]
        append o "<div style=\"height:[expr {$v * 100 / $hmax}]%\" title=\"[format %02d:00 $i] - [fmt $v] lines\"></div>"
    }
    append o "</div><div class=\"axis\">"
    for {set i 0} {$i < 24} {incr i} {append o "<span>[expr {$i % 3 ? "" : [format %02d $i]}]</span>"}
    append o "</div></section>"

    append o "<section><h2>Last 31 days</h2><div class=\"bars\">"
    foreach v $dvals l $dlabels {
        append o "<div style=\"height:[expr {$v * 100 / $dmax}]%\" title=\"$l - [fmt $v] lines\"></div>"
    }
    append o "</div><div class=\"axis\"><span>[lindex $dlabels 0]</span><span></span><span>[lindex $dlabels end]</span></div></section>"

    append o "<section><h2>Most active users</h2><table><tr><th>#</th><th>Nick</th><th>Lines</th><th>Words</th><th>W/L</th><th>Last seen</th><th>Random quote</th></tr>"
    set i 0
    foreach row [lrange [ranking $c lines] 0 [expr {$html_top - 1}]] {
        set u $users($c,[string tolower [lindex $row 0]])
        set l [dict get $u lines]
        append o "<tr><td class=\"n\">[incr i]</td><td>[esc [dict get $u nick]]</td><td class=\"n\">[fmt $l]</td>"
        append o "<td class=\"n\">[fmt [dict get $u words]]</td><td class=\"n\">[format %.1f [expr {double([dict get $u words]) / $l}]]</td>"
        append o "<td>[esc [ago [dict get $u last]]]</td><td class=\"q\">[esc [dict get $u quote]]</td></tr>"
    }
    append o "</table></section>"

    append o "<section><h2>Interesting numbers</h2><div class=\"facts\">"
    foreach {field text} {
        questions "asked the most questions" shouts "shouted the most" smileys "used the most smileys"
        actions "did the most /me actions" kicks "kicked the most people" kicked "got kicked the most"
        joins "joined the most times"
    } {
        set top [lindex [ranking $c $field] 0]
        if {[llength $top]} {
            append o "<div><b>[esc [lindex $top 0]]</b> $text <span class=\"muted\">([fmt [lindex $top 1]])</span></div>"
        }
    }
    append o "</div></section>"

    if {[info exists words($c)] && [dict size $words($c)]} {
        append o "<section><h2>Most used words</h2><div class=\"tags\">"
        foreach {w n} [lrange [lsort -stride 2 -index 1 -integer -decreasing $words($c)] 0 59] {
            append o "<span>[esc $w] <span class=\"muted\">$n</span></span>"
        }
        append o "</div></section>"
    }
    append o "<p class=\"muted\">Generated by chanstats.tcl for Eggdrop</p></main></body></html>\n"
    return $o
}

proc ::chanstats::write_html {} {
    variable htmldir
    variable names
    if {$htmldir eq ""} return
    if {[catch {file mkdir $htmldir} err]} {putlog "chanstats: $err"; return}
    foreach c [array names names] {
        if {![validchan $names($c)] || ![channel get $names($c) chanstats]} continue
        set f [file join $htmldir [safe $c].html]
        if {[catch {
            set fd [open $f.tmp w]
            fconfigure $fd -encoding utf-8
            puts -nonewline $fd [html $c]
            close $fd
            file rename -force $f.tmp $f
        } err]} {
            putlog "chanstats: could not write $f: $err"
        }
    }
}

proc ::chanstats::tick {} {
    variable html_every
    save
    write_html
    timer $html_every ::chanstats::tick
}

bind dcc m chanstats-reset ::chanstats::dcc_reset
proc ::chanstats::dcc_reset {hand idx text} {
    variable users
    variable hours
    variable days
    variable words
    set c [string tolower [string trim $text]]
    if {$c eq ""} {putdcc $idx "Usage: .chanstats-reset #chan"; return 0}
    foreach k [chanusers $c] {unset users($k)}
    unset -nocomplain hours($c) days($c) words($c)
    save
    putdcc $idx "chanstats: stats for $c wiped."
    return 1
}

bind dcc m chanstats-html ::chanstats::dcc_html
proc ::chanstats::dcc_html {hand idx text} {
    variable htmldir
    if {$htmldir eq ""} {putdcc $idx "chanstats: htmldir is not set."; return 0}
    write_html
    putdcc $idx "chanstats: HTML written to $htmldir"
    return 1
}

bind evnt - save ::chanstats::save

if {![info exists ::chanstats::loaded]} {
    ::chanstats::load
    set ::chanstats::loaded 1
}
apply {{} {
    foreach t [timers] {
        if {[string match ::chanstats::* [lindex $t 1]]} {killtimer [lindex $t 2]}
    }
}}
timer $::chanstats::html_every ::chanstats::tick

putlog "chanstats.tcl loaded"
