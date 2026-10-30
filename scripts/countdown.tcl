# =====================================================================
#  countdown.tcl  v1.2.0  -  Event countdowns with automatic announcements
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Per-channel events (releases, matches, birthdays, holidays...) with
#    a live countdown, a progress bar, and announcements at milestones
#    (by default 7d, 1d, 1h, 10m and when it starts). Yearly events
#    (birthdays) roll over by themselves. Each channel has a timezone.
#
#  REQUIREMENTS
#    web.tcl and timeutil.tcl (load them first)
#
#  SETUP
#    .chanset #chan +countdown
#    .chanset #chan countdown-tz Europe/Madrid    (or !cd tz, ops)
#
#  COMMANDS (channel)
#    !cd | !countdown               upcoming events
#    !cd <name>                     time left, date, progress, description
#    !cd add <name> <date> [time] [| description]          (ops by default)
#    !cd add -yearly <name> <day/month> [time] [| description]
#    !cd del <name>                 remove an event
#    !cd edit <name> <date> [time]  change the date
#    !cd desc <name> <text>         change the description
#    !cd alerts <name> <list|off|default>   e.g. 30d,7d,1d,1h,10m,0
#    !cd tz [Area/City]             channel timezone
#    <date> examples: 2026-12-24, 24/12/2026, 24/12, dec 24, tomorrow, friday
# =====================================================================

namespace eval ::countdown {
    # ------------------------- CONFIGURATION -------------------------
    variable datadir "countdown"
    variable edit_flags "o|o"        ;# who can add/del/edit ("-|-" = everyone)
    variable max_events 30           ;# per channel
    variable default_alerts {604800 86400 3600 600 0}
    variable keep_days 3             ;# keep finished one-off events this long
    variable late_window 900         ;# don't announce alerts missed by more than this
    variable throttle 3

    # --------------------- STATE (do not touch) ---------------------
    variable events                  ;# events(chan) -> list of dicts
    variable last
}

setudef flag countdown
setudef str countdown-tz

# ----------------------------- HELPERS -----------------------------

proc ::countdown::tz {chan} {
    set z [channel get $chan countdown-tz]
    if {$z ne "" && [::timeutil::valid_tz $z]} {return $z}
    return ""
}

proc ::countdown::can_edit {hand chan} {
    variable edit_flags
    expr {$edit_flags in {"" "-" "-|-"} || [matchattr $hand $edit_flags $chan]}
}

proc ::countdown::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

proc ::countdown::get_events {chan} {
    variable events
    set c [string tolower $chan]
    if {[info exists events($c)]} {return $events($c)}
    return {}
}

proc ::countdown::set_events {chan list} {
    variable events
    set events([string tolower $chan]) $list
    save
}

proc ::countdown::find {chan name} {
    set i 0
    foreach e [get_events $chan] {
        if {[string equal -nocase [dict get $e name] $name]} {return $i}
        incr i
    }
    return -1
}

proc ::countdown::save {} {
    variable events
    variable datadir
    file mkdir $datadir
    set f [file join $datadir countdown.db]
    set fd [open $f.tmp w]
    fconfigure $fd -encoding utf-8
    foreach c [array names events] {puts $fd [list $c $events($c)]}
    close $fd
    file rename -force $f.tmp $f
}

proc ::countdown::load {} {
    variable events
    variable datadir
    set f [file join $datadir countdown.db]
    if {![file exists $f]} return
    set fd [open $f r]
    fconfigure $fd -encoding utf-8
    while {[gets $fd line] >= 0} {
        if {[llength $line] == 2} {set events([lindex $line 0]) [lindex $line 1]}
    }
    close $fd
}

# "7d,1d,1h,10m,0" -> seconds list
proc ::countdown::parse_alerts {s} {
    set out {}
    foreach p [split [string map {" " ""} $s] ,] {
        if {$p eq "0" || $p eq "now"} {lappend out 0; continue}
        set d [::timeutil::duration $p]
        if {$d eq ""} {return ""}
        lappend out $d
    }
    lsort -integer -decreasing -unique $out
}

proc ::countdown::alerts_str {list} {
    join [lmap a $list {expr {$a == 0 ? "start" : [::timeutil::human $a 1]}}] ", "
}

proc ::countdown::bar {e} {
    set start [dict get $e created]
    set end [dict get $e when]
    if {$end <= $start} {return ""}
    set p [expr {min(1.0, max(0.0, double([clock seconds] - $start) / ($end - $start)))}]
    set full [expr {int(round($p * 10))}]
    return "\[[string repeat # $full][string repeat - [expr {10 - $full}]]\] [expr {int($p * 100)}]%"
}

# Next occurrence of a yearly event (day/month of 'when') after 'now'
proc ::countdown::next_yearly {when tz now} {
    set md [clock format $when -format "%m %d %H %M" {*}[::timeutil::tzopt $tz]]
    lassign [lmap x $md {scan $x %d}] m d h mi
    set y [scan [clock format $now -format %Y {*}[::timeutil::tzopt $tz]] %d]
    foreach yy [list $y [expr {$y + 1}] [expr {$y + 4}]] {
        set t [::timeutil::mk $yy $m $d $h $mi $tz]
        if {$t ne "" && $t > $now - 60} {return $t}
    }
    return $when
}

proc ::countdown::describe {chan e} {
    set tz [tz $chan]
    set now [clock seconds]
    set when [dict get $e when]
    # Name in 3 days (When: ... | Repeats: yearly | bar | description)
    set line [::web::b [dict get $e name]]
    if {$when > $now} {
        append line " in [::web::b [::timeutil::human [expr {$when - $now}] 3]]"
    } else {
        append line " was [::timeutil::human [expr {$now - $when}] 2] ago"
    }
    set f [list [::web::lbl When [::timeutil::fmt $when $tz {%a %d %b %Y %H:%M %Z}]]]
    if {[dict get $e yearly]} {lappend f [::web::lbl Repeats yearly]}
    if {$when > $now} {lappend f [bar $e]}
    lappend f [dict get $e desc]
    append line " ([::web::fields $f])"
    return $line
}

# ----------------------------- TICKER -----------------------------

proc ::countdown::tick {} {
    variable events
    variable keep_days
    variable late_window
    set now [clock seconds]
    set dirty 0
    foreach c [array names events] {
        set chan $c
        foreach real [channels] {if {[string equal -nocase $real $c]} {set chan $real}}
        set on [expr {[validchan $chan] && [channel get $chan countdown] && [botonchan $chan]}]
        set keep {}
        foreach e $events($c) {
            set when [dict get $e when]
            set done [dict get $e done]
            foreach a [dict get $e alerts] {
                if {$a in $done || $now < $when - $a} continue
                lappend done $a
                set dirty 1
                # Missed while the bot was down: stay quiet
                if {$now - ($when - $a) > $late_window || !$on} continue
                if {$a == 0} {
                    puthelp "PRIVMSG $chan :[::web::msg Countdown "[::web::b [dict get $e name]] is happening NOW![expr {[dict get $e desc] ne "" ? " [dict get $e desc]" : ""}]"]"
                } else {
                    puthelp "PRIVMSG $chan :[::web::msg Countdown "[::web::b [dict get $e name]] in [::timeutil::human [expr {$when - $now}] 2] ([::web::lbl When [::timeutil::fmt $when [tz $chan] {%a %d %b %H:%M %Z}]])"]"
                }
            }
            dict set e done $done
            if {$now > $when + 60} {
                if {[dict get $e yearly]} {
                    dict set e when [next_yearly $when [tz $chan] $now]
                    dict set e created $now
                    dict set e done {}
                    set dirty 1
                } elseif {$now > $when + $keep_days * 86400} {
                    set dirty 1
                    continue
                }
            }
            lappend keep $e
        }
        set events($c) $keep
    }
    if {$dirty} {save}
    utimer 20 ::countdown::tick
}

# ----------------------------- COMMANDS -----------------------------

proc ::countdown::parse_add {chan words} {
    # Returns {when desc} or an error string starting with "!"
    set text [join $words]
    set desc ""
    if {[set bar [string first | $text]] >= 0} {
        set desc [string trim [string range $text [expr {$bar + 1}] end]]
        set text [string trim [string range $text 0 [expr {$bar - 1}]]]
    }
    set w [regexp -all -inline {\S+} $text]
    set r [::timeutil::when $w [tz $chan]]
    if {$r eq ""} {return "!I don't understand the date. Examples: 2026-12-24 20:00, 24/12, dec 24, friday 21:00"}
    lassign $r when used
    if {$used < [llength $w] && $desc eq ""} {set desc [join [lrange $w $used end]]}
    list $when $desc
}

# Every reply of !cd carries the Countdown tag
proc ::countdown::reply {target text} {
    ::web::say $target [::web::msg Countdown $text]
}

bind pub - !cd ::countdown::pub_cd
bind pub - !countdown ::countdown::pub_cd
bind pub - !cuentaatras ::countdown::pub_cd
proc ::countdown::pub_cd {nick uhost hand chan text} {
    variable max_events
    variable default_alerts
    if {![channel get $chan countdown] || [flood $uhost]} {return 0}
    set w [regexp -all -inline {\S+} $text]
    set sub [string tolower [lindex $w 0]]
    set reply [list ::countdown::reply $chan]
    if {$sub in {add del delete rm edit desc alerts tz} && ![can_edit $hand $chan]} {
        puthelp "NOTICE $nick :Only bot ops can change the countdowns of $chan."
        return 0
    }
    set list [get_events $chan]
    switch -- $sub {
        "" - list {
            set now [clock seconds]
            set up [lsort -integer -index 1 [lmap e $list {list $e [dict get $e when]}]]
            set out {}
            foreach p $up {
                lassign $p e when
                if {$when < $now} continue
                lappend out [::web::lbl [dict get $e name] [::timeutil::human [expr {$when - $now}] 2]]
            }
            if {![llength $out]} {
                {*}$reply "No upcoming events. Ops: [::web::b {!cd add}] <name> <date> \[time\] \[| description\]"
            } else {
                {*}$reply "[::web::fields [lrange $out 0 7]][expr {[llength $out] > 8 ? " [::web::dim (+[expr {[llength $out] - 8}])]" : ""}]"
            }
        }
        add {
            set yearly 0
            set w [lrange $w 1 end]
            if {[string tolower [lindex $w 0]] in {-yearly -y yearly}} {
                set yearly 1
                set w [lrange $w 1 end]
            }
            set name [lindex $w 0]
            regsub -all {[^\w.-]} $name "" name
            if {$name eq "" || [llength $w] < 2} {
                puthelp "NOTICE $nick :Usage: !cd add \[-yearly\] <name> <date> \[time\] \[| description\]"
                return 0
            }
            if {[find $chan $name] >= 0} {{*}$reply "There is already an event called \002$name\002 (!cd edit)."; return 0}
            if {[llength $list] >= $max_events} {{*}$reply "This channel already has $max_events events."; return 0}
            set r [parse_add $chan [lrange $w 1 end]]
            if {[string index $r 0] eq "!"} {{*}$reply [string range $r 1 end]; return 0}
            lassign $r when desc
            if {$yearly} {set when [next_yearly $when [tz $chan] [clock seconds]]}
            if {$when <= [clock seconds]} {{*}$reply "That date is in the past."; return 0}
            set e [dict create name $name when $when desc $desc yearly $yearly by $nick \
                created [clock seconds] alerts $default_alerts done {}]
            lappend list $e
            set_events $chan $list
            {*}$reply "Added. [describe $chan $e]"
        }
        del - delete - rm {
            set i [find $chan [lindex $w 1]]
            if {$i < 0} {{*}$reply "No event called \"[lindex $w 1]\"."; return 0}
            set_events $chan [lreplace $list $i $i]
            {*}$reply "Removed \002[lindex $w 1]\002."
        }
        edit {
            set i [find $chan [lindex $w 1]]
            if {$i < 0} {{*}$reply "No event called \"[lindex $w 1]\"."; return 0}
            set r [parse_add $chan [lrange $w 2 end]]
            if {[string index $r 0] eq "!"} {{*}$reply [string range $r 1 end]; return 0}
            set e [lindex $list $i]
            dict set e when [lindex $r 0]
            if {[dict get $e yearly]} {dict set e when [next_yearly [lindex $r 0] [tz $chan] [clock seconds]]}
            dict set e done {}
            dict set e created [clock seconds]
            lset list $i $e
            set_events $chan $list
            {*}$reply "Updated. [describe $chan $e]"
        }
        desc {
            set i [find $chan [lindex $w 1]]
            if {$i < 0} {{*}$reply "No event called \"[lindex $w 1]\"."; return 0}
            set e [lindex $list $i]
            dict set e desc [join [lrange $w 2 end]]
            lset list $i $e
            set_events $chan $list
            {*}$reply "Description of \002[dict get $e name]\002 updated."
        }
        alerts {
            set i [find $chan [lindex $w 1]]
            set spec [string tolower [join [lrange $w 2 end]]]
            if {$i < 0} {{*}$reply "Usage: !cd alerts <name> <30d,7d,1d,1h,10m,0 | off | default>"; return 0}
            set e [lindex $list $i]
            if {$spec eq "off"} {
                set a {}
            } elseif {$spec in {default ""}} {
                set a $default_alerts
            } else {
                set a [parse_alerts $spec]
                if {$a eq ""} {{*}$reply "Invalid list. Example: 7d,1d,1h,10m,0"; return 0}
            }
            dict set e alerts $a
            # Alerts already past stay silent
            set now [clock seconds]
            dict set e done [lmap x $a {expr {$now >= [dict get $e when] - $x ? $x : [continue]}}]
            lset list $i $e
            set_events $chan $list
            {*}$reply "Alerts for \002[dict get $e name]\002: [expr {[llength $a] ? [alerts_str $a] : "off"}]"
        }
        tz {
            set z [lindex $w 1]
            if {$z eq ""} {
                set cur [tz $chan]
                {*}$reply "Timezone of $chan: [expr {$cur eq "" ? "server default" : $cur}] (now [::timeutil::fmt [clock seconds] $cur {%H:%M %Z}])"
                return 1
            }
            if {![::timeutil::valid_tz $z]} {{*}$reply "Unknown timezone $z (use Area/City, e.g. Europe/Madrid)."; return 0}
            channel set $chan countdown-tz $z
            {*}$reply "Timezone of $chan set to $z."
        }
        default {
            set i [find $chan [lindex $w 0]]
            if {$i < 0} {
                puthelp "NOTICE $nick :No event called \"[lindex $w 0]\". Usage: !cd | !cd <name> | ops: !cd add/del/edit/desc/alerts/tz"
                return 0
            }
            {*}$reply [describe $chan [lindex $list $i]]
        }
    }
    return 1
}

if {![info exists ::countdown::loaded]} {
    ::countdown::load
    set ::countdown::loaded 1
}
apply {{} {
    foreach t [utimers] {
        if {[string match ::countdown::* [lindex $t 1]]} {killutimer [lindex $t 2]}
    }
}}
utimer 20 ::countdown::tick

putlog "countdown.tcl loaded"
