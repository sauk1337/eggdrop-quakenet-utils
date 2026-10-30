# =====================================================================
#  timeutil.tcl  v1.0.0  -  Shared date/time parsing and formatting
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Library used by reminders.tcl, countdown.tcl and feeds.tcl. It has
#    no commands of its own. Understands English and Spanish words.
#
#  API
#    ::timeutil::duration "1h30m"        -> seconds, or "" if not a duration
#    ::timeutil::when words ?tz? ?now?   -> {epoch consumed_words} or ""
#        "10m", "in 2h 30m", "at 18:30", "18:30", "tomorrow 9:00",
#        "friday 20:00", "2026-12-24 20:00", "24/12 20:00", "dec 24",
#        "mañana 9:00", "en 10 minutos", "viernes", "hoy 22:00"
#    ::timeutil::date text ?tz?          -> epoch for a date/time text or ""
#    ::timeutil::parse_feed_date text    -> epoch for RFC 822 / ISO 8601
#    ::timeutil::human secs              -> "2d 3h", "45m", "30s"
#    ::timeutil::rel epoch               -> "in 2h 5m" / "5m ago"
#    ::timeutil::fmt epoch ?tz?          -> "Fri 24 Dec 2026 20:00 CET"
#    ::timeutil::valid_tz name           -> 1 if the zone exists
#
#  REQUIREMENTS
#    tzdata on the system (Debian/Ubuntu: apt install tzdata)
# =====================================================================

namespace eval ::timeutil {
    variable units {
        s 1 sec 1 secs 1 second 1 seconds 1 seg 1 segs 1 segundo 1 segundos 1
        m 60 min 60 mins 60 minute 60 minutes 60 minuto 60 minutos 60
        h 3600 hr 3600 hrs 3600 hour 3600 hours 3600 hora 3600 horas 3600
        d 86400 day 86400 days 86400 dia 86400 dias 86400 día 86400 días 86400
        w 604800 wk 604800 week 604800 weeks 604800 semana 604800 semanas 604800
        mo 2592000 month 2592000 months 2592000 mes 2592000 meses 2592000
        y 31536000 yr 31536000 year 31536000 years 31536000 año 31536000 años 31536000
    }
    variable weekdays {
        sunday 0 sun 0 domingo 0 dom 0
        monday 1 mon 1 lunes 1 lun 1
        tuesday 2 tue 2 tues 2 martes 2
        wednesday 3 wed 3 miercoles 3 miércoles 3 mie 3 mié 3
        thursday 4 thu 4 thurs 4 jueves 4 jue 4
        friday 5 fri 5 viernes 5 vie 5
        saturday 6 sat 6 sabado 6 sábado 6 sab 6 sáb 6
    }
    variable months {
        jan 1 january 1 ene 1 enero 1
        feb 2 february 2 febrero 2
        mar 3 march 3 marzo 3
        apr 4 april 4 abr 4 abril 4
        may 5 mayo 5
        jun 6 june 6 junio 6
        jul 7 july 7 julio 7
        aug 8 august 8 ago 8 agosto 8
        sep 9 sept 9 september 9 septiembre 9 setiembre 9
        oct 10 october 10 octubre 10
        nov 11 november 11 noviembre 11
        dec 12 december 12 dic 12 diciembre 12
    }
}

proc ::timeutil::tzopt {tz} {
    if {$tz eq ""} {return {}}
    list -timezone :$tz
}

proc ::timeutil::valid_tz {tz} {
    expr {![catch {clock format 0 -timezone :$tz}]}
}

# "1h30m", "90s", "2d", "1.5h", "10min", "3dias"  -> seconds
proc ::timeutil::duration {s} {
    variable units
    set s [string tolower [string trim $s]]
    if {$s eq ""} {return ""}
    set total 0
    while {$s ne ""} {
        if {![regexp {^(\d+(?:[.,]\d+)?)\s*([a-zñáéíóú]+)(.*)$} $s -> n u rest]} {return ""}
        if {![dict exists $units $u]} {return ""}
        set total [expr {$total + double([string map {, .} $n]) * [dict get $units $u]}]
        set s [string trimleft $rest]
    }
    expr {int(round($total))}
}

# "18:30", "18.30", "6pm", "6:30am", "18h", "18h30" -> {hour minute} or ""
proc ::timeutil::clocktime {s} {
    set s [string tolower $s]
    if {[regexp {^(\d{1,2})(?:[:.h](\d{2}))?\s*(am|pm)$} $s -> h m ap]} {
        if {$m eq ""} {set m 0}
        set h [scan $h %d]
        if {$h < 1 || $h > 12} {return ""}
        if {$ap eq "pm" && $h != 12} {incr h 12}
        if {$ap eq "am" && $h == 12} {set h 0}
        return [list $h [scan $m %d]]
    }
    if {[regexp {^(\d{1,2})[:.h](\d{2})(?::(\d{2}))?$} $s -> h m] ||
        [regexp {^(\d{1,2})h$} $s -> h] && [set m 0] == 0} {
        set h [scan $h %d]
        set m [scan $m %d]
        if {$h > 23 || $m > 59} {return ""}
        return [list $h $m]
    }
    return ""
}

# Builds an epoch from Y M D h m in the given zone
proc ::timeutil::mk {y mo d h mi tz} {
    if {[catch {
        clock scan [format "%04d-%02d-%02d %02d:%02d:00" $y $mo $d $h $mi] \
            -format "%Y-%m-%d %H:%M:%S" {*}[tzopt $tz]
    } t]} {return ""}
    # Reject impossible dates (clock scan normalises 31/02 to March)
    if {[clock format $t -format %Y-%m-%d {*}[tzopt $tz]] ne [format "%04d-%02d-%02d" $y $mo $d]} {return ""}
    return $t
}

# Date part: returns {y m d explicit_year} or ""
proc ::timeutil::datepart {s now tz} {
    variable months
    set s [string tolower $s]
    set y [clock format $now -format %Y {*}[tzopt $tz]]
    if {[regexp {^(\d{4})-(\d{1,2})-(\d{1,2})$} $s -> yy mm dd]} {
        return [list [scan $yy %d] [scan $mm %d] [scan $dd %d] 1]
    }
    if {[regexp {^(\d{1,2})[/.-](\d{1,2})(?:[/.-](\d{2,4}))?$} $s -> dd mm yy]} {
        set explicit [expr {$yy ne ""}]
        if {$yy eq ""} {set yy $y} elseif {[string length $yy] == 2} {set yy [expr {2000 + [scan $yy %d]}]}
        return [list [scan $yy %d] [scan $mm %d] [scan $dd %d] $explicit]
    }
    return ""
}

# Parses a time expression from the start of a word list.
# Returns {epoch consumed} or "" if the words don't start with a time.
proc ::timeutil::when {words {tz ""} {now ""}} {
    variable weekdays
    variable months
    if {$now eq ""} {set now [clock seconds]}
    set w [lmap x $words {string tolower $x}]
    set i 0

    # Relative: "in 10m", "en 2 horas", "10m", "2h 30m", "1 hour"
    if {[lindex $w 0] in {in en dentro}} {
        set i 1
        if {[lindex $w 1] eq "de"} {set i 2}
    }
    set secs 0
    set j $i
    while {$j < [llength $w]} {
        set tok [lindex $w $j]
        set d [duration $tok]
        # "10 minutes" written as two words
        if {$d eq "" && [string is double -strict $tok] && $j + 1 < [llength $w]} {
            set d [duration "$tok[lindex $w [expr {$j + 1}]]"]
            if {$d ne ""} {incr j}
        }
        if {$d eq "" || $d == 0} break
        incr secs $d
        incr j
        if {[lindex $w $j] in {and y}} {incr j}
    }
    if {$secs > 0} {return [list [expr {$now + $secs}] $j]}
    if {$i > 0} {return ""}

    # Absolute: optional "at"/"a las", day word or date, optional time
    if {[lindex $w 0] in {at @}} {set i 1}
    if {[lindex $w 0] eq "a" && [lindex $w 1] in {las la}} {set i 2}
    set ymd ""
    set explicit_year 0
    set dayword 0
    set tok [lindex $w $i]
    set today [split [clock format $now -format "%Y %m %d %w" {*}[tzopt $tz]]]
    lassign [lmap x $today {scan $x %d}] cy cm cd cw
    if {$tok in {today hoy}} {
        set ymd [list $cy $cm $cd]
        set dayword 1
        incr i
    } elseif {$tok in {tomorrow mañana manana}} {
        set t [clock add $now 1 day {*}[tzopt $tz]]
        set ymd [lmap x [split [clock format $t -format "%Y %m %d" {*}[tzopt $tz]]] {scan $x %d}]
        set dayword 1
        incr i
    } elseif {[dict exists $weekdays $tok]} {
        set wd [dict get $weekdays $tok]
        set add [expr {($wd - $cw + 7) % 7}]
        if {$add == 0} {set add 7}
        set t [clock add $now $add days {*}[tzopt $tz]]
        set ymd [lmap x [split [clock format $t -format "%Y %m %d" {*}[tzopt $tz]]] {scan $x %d}]
        set dayword 1
        incr i
    } elseif {[set dp [datepart $tok $now $tz]] ne ""} {
        lassign $dp yy mm dd explicit_year
        set ymd [list $yy $mm $dd]
        incr i
    } elseif {[dict exists $months $tok] && [regexp {^\d{1,2}$} [lindex $w [expr {$i + 1}]]]} {
        # "dec 24"
        set ymd [list $cy [dict get $months $tok] [scan [lindex $w [expr {$i + 1}]] %d]]
        incr i 2
    } elseif {[regexp {^\d{1,2}$} $tok] && [dict exists $months [lindex $w [expr {$i + 1}]]]} {
        # "24 dec" / "24 de diciembre"
        set ymd [list $cy [dict get $months [lindex $w [expr {$i + 1}]]] [scan $tok %d]]
        incr i 2
    } elseif {[regexp {^\d{1,2}$} $tok] && [lindex $w [expr {$i + 1}]] eq "de" &&
              [dict exists $months [lindex $w [expr {$i + 2}]]]} {
        set ymd [list $cy [dict get $months [lindex $w [expr {$i + 2}]]] [scan $tok %d]]
        incr i 3
    }
    # Optional year after "dec 24" / "24 dec"
    if {$ymd ne "" && !$explicit_year && [regexp {^\d{4}$} [lindex $w $i]]} {
        lset ymd 0 [scan [lindex $w $i] %d]
        set explicit_year 1
        incr i
    }
    # Optional time ("at 18:30", "a las 9")
    if {[lindex $w $i] in {at @ a}} {
        set k [expr {[lindex $w $i] eq "a" && [lindex $w [expr {$i + 1}]] in {las la} ? 2 : 1}]
        if {[clocktime [lindex $w [expr {$i + $k}]]] ne "" ||
            [regexp {^\d{1,2}$} [lindex $w [expr {$i + $k}]]]} {incr i $k}
    }
    set hm [clocktime [lindex $w $i]]
    if {$hm eq "" && $ymd ne "" && [regexp {^\d{1,2}$} [lindex $w $i]] && [scan [lindex $w $i] %d] < 24 &&
        [lindex $w [expr {$i - 1}]] in {at @ las la}} {
        set hm [list [scan [lindex $w $i] %d] 0]
    }
    if {$hm ne ""} {incr i}
    if {$ymd eq "" && $hm eq ""} {return ""}

    if {$ymd eq ""} {
        # Time only: today, or tomorrow if it already passed
        lassign $hm h mi
        set t [mk $cy $cm $cd $h $mi $tz]
        if {$t ne "" && $t <= $now} {
            set n [clock add $now 1 day {*}[tzopt $tz]]
            lassign [lmap x [split [clock format $n -format "%Y %m %d" {*}[tzopt $tz]]] {scan $x %d}] ny nm nd
            set t [mk $ny $nm $nd $h $mi $tz]
        }
    } else {
        lassign $ymd y mo d
        lassign [expr {$hm eq "" ? {9 0} : $hm}] h mi
        if {$hm eq "" && !$dayword} {lassign {0 0} h mi}
        set t [mk $y $mo $d $h $mi $tz]
        # A date without year that already passed means next year
        if {$t ne "" && !$explicit_year && !$dayword && $t < $now - 86400} {
            set t [mk [expr {$y + 1}] $mo $d $h $mi $tz]
        }
    }
    if {$t eq ""} {return ""}
    list $t $i
}

# Whole text must be a date/time: returns epoch or ""
proc ::timeutil::date {text {tz ""} {now ""}} {
    set words [regexp -all -inline {\S+} $text]
    set r [when $words $tz $now]
    if {$r eq "" || [lindex $r 1] != [llength $words]} {return ""}
    lindex $r 0
}

# RFC 822 (RSS) and ISO 8601 (Atom) dates
proc ::timeutil::parse_feed_date {s} {
    set s [string trim $s]
    if {$s eq ""} {return ""}
    if {[regexp {^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$} $s -> d hm sec off]} {
        if {$sec eq ""} {set sec 00}
        if {$off eq "" || $off eq "Z"} {set off +0000}
        set off [string map {: ""} $off]
        if {![catch {clock scan "$d $hm:$sec $off" -format "%Y-%m-%d %H:%M:%S %z"} t]} {return $t}
        return ""
    }
    if {[regexp {^\d{4}-\d{2}-\d{2}$} $s]} {
        if {![catch {clock scan $s -format %Y-%m-%d -gmt 1} t]} {return $t}
    }
    # "Mon, 26 Oct 2026 10:00:00 +0000" / "... GMT" / without weekday or seconds
    regsub {^[A-Za-z]{3},\s*} $s "" s
    set s [string map {" GMT" " +0000" " UTC" " +0000" " UT" " +0000" " EST" " -0500" " EDT" " -0400"
                       " CST" " -0600" " CDT" " -0500" " PST" " -0800" " PDT" " -0700" " Z" " +0000"} $s]
    foreach f {"%d %b %Y %H:%M:%S %z" "%d %b %Y %H:%M %z" "%d %b %y %H:%M:%S %z" "%d %b %Y %H:%M:%S"} {
        if {![catch {clock scan $s -format $f -gmt 1} t]} {return $t}
    }
    return ""
}

proc ::timeutil::human {secs {parts 2}} {
    set secs [expr {abs(int($secs))}]
    if {$secs < 60} {return "${secs}s"}
    set out {}
    foreach {n u} {31536000 y 86400 d 3600 h 60 m} {
        if {$secs >= $n} {
            lappend out "[expr {$secs / $n}]$u"
            set secs [expr {$secs % $n}]
            if {[llength $out] >= $parts} break
        } elseif {[llength $out]} {
            # keep units contiguous: "1d 3h", never "1d 5m"
            break
        }
    }
    join $out " "
}

proc ::timeutil::rel {t {now ""}} {
    if {$now eq ""} {set now [clock seconds]}
    set d [expr {$t - $now}]
    if {abs($d) < 30} {return "now"}
    expr {$d > 0 ? "in [human $d]" : "[human $d] ago"}
}

proc ::timeutil::fmt {t {tz ""} {format "%a %d %b %Y %H:%M %Z"}} {
    clock format $t -format $format {*}[tzopt $tz]
}

putlog "timeutil.tcl loaded"
