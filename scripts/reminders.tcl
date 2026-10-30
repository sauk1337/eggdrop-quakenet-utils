# =====================================================================
#  reminders.tcl  v1.2.0  -  Reminders, alarms and recurring reminders
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Users set reminders in plain English or Spanish. They survive bot
#    restarts, follow nick changes (and Q accounts on +x hosts), and are
#    delivered when the person comes back if they were away when due.
#    Each user can set a timezone for absolute times.
#
#  REQUIREMENTS
#    web.tcl and timeutil.tcl (load them first)
#
#  SETUP
#    .chanset #chan +reminders
#
#  COMMANDS (channel)
#    !remind <when> <text>            remind me        !remind 10m tea
#    !remind <nick> <when> <text>     remind someone on the channel
#    !remind every <interval> [at <time>] <text>    recurring (min 10m)
#    !at <time> <text>                same as !remind at <time> <text>
#    !reminders | !remind list        your pending reminders (by notice)
#    !remind del <id|all>             delete yours (ops: any on the channel)
#    !remind tz [Area/City]           show/set your timezone
#    !snooze [interval]               repeat the last reminder (default 10m)
#    <when> examples: 10m, 2h30m, in 1 hour, at 18:30, tomorrow 9:00,
#      friday 20:00, 24/12 20:00, dec 24, mañana 9:00, en 10 minutos
#  COMMANDS (private)
#    /msg <bot> remind <when> <text>  private reminder, delivered by notice
#  PARTYLINE
#    .reminders [nick]                list reminders (master)
# =====================================================================

namespace eval ::reminders {
    # ------------------------- CONFIGURATION -------------------------
    variable datadir "reminders"
    variable max_per_user 25
    variable max_ahead 63072000      ;# 2 years
    variable min_delay 20            ;# seconds
    variable min_every 600           ;# seconds, recurring minimum
    variable max_recurring 3         ;# per user
    variable max_for_others 5        ;# reminders a user may set for others
    variable throttle 3              ;# seconds between commands per user
    variable default_tz ""           ;# "" = the system timezone
    variable snooze_window 900       ;# !snooze works this long after delivery

    # --------------------- STATE (do not touch) ---------------------
    variable list                    ;# list of reminder dicts
    variable nextid
    variable tzs                     ;# tzs(owner-id) -> timezone
    variable lastfired               ;# lastfired(owner-id) -> {time reminder}
    variable last
    if {![info exists list]} {set list {}}
    if {![info exists nextid]} {set nextid 1}
}

setudef flag reminders

# ----------------------------- HELPERS -----------------------------

# Identity: the Q account for +x users, the nick otherwise
proc ::reminders::who {nick uhost} {
    if {[regexp -nocase {@([^.]+)\.users\.quakenet\.org$} $uhost -> acc]} {
        return "a:[string tolower $acc]"
    }
    return "n:[string tolower $nick]"
}

proc ::reminders::tz_of {id} {
    variable tzs
    variable default_tz
    if {[info exists tzs($id)]} {return $tzs($id)}
    return $default_tz
}

proc ::reminders::notice {nick text} {
    puthelp "NOTICE $nick :[::web::msg Reminder $text]"
}

proc ::reminders::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

proc ::reminders::count {owner {what all}} {
    variable list
    set n 0
    foreach r $list {
        if {[dict get $r owner] ne $owner} continue
        if {$what eq "recurring" && [dict get $r every] == 0} continue
        if {$what eq "others" && [dict get $r target] eq [dict get $r ownernick]} continue
        incr n
    }
    return $n
}

proc ::reminders::save {} {
    variable list
    variable nextid
    variable tzs
    variable datadir
    file mkdir $datadir
    set f [file join $datadir reminders.db]
    set fd [open $f.tmp w]
    fconfigure $fd -encoding utf-8
    puts $fd [list nextid $nextid]
    puts $fd [list tzs [array get tzs]]
    foreach r $list {puts $fd [list r $r]}
    close $fd
    file rename -force $f.tmp $f
}

proc ::reminders::load {} {
    variable list
    variable nextid
    variable tzs
    variable datadir
    set f [file join $datadir reminders.db]
    if {![file exists $f]} return
    set fd [open $f r]
    fconfigure $fd -encoding utf-8
    set list {}
    while {[gets $fd line] >= 0} {
        if {[catch {lassign $line kind data}]} continue
        switch -- $kind {
            nextid {set nextid $data}
            tzs    {array set tzs $data}
            r      {lappend list $data}
        }
    }
    close $fd
}

# ----------------------------- CREATION -----------------------------

# Parses "<when> <text>" and adds the reminder. Returns a message for the user.
proc ::reminders::add {nick uhost chan target words {private 0}} {
    variable list
    variable nextid
    variable max_per_user
    variable max_ahead
    variable min_delay
    variable min_every
    variable max_recurring
    variable max_for_others
    set owner [who $nick $uhost]
    set tz [tz_of $owner]
    set now [clock seconds]
    if {[count $owner] >= $max_per_user} {
        return "You already have $max_per_user reminders. Delete some with !remind del <id>."
    }
    set every 0
    if {[string tolower [lindex $words 0]] in {every cada}} {
        set every [::timeutil::duration [lindex $words 1]]
        if {$every eq "" || $every < $min_every} {
            return "Recurring reminders need an interval of at least [::timeutil::human $min_every] (e.g. !remind every 1d at 09:00 water the plants)."
        }
        if {[count $owner recurring] >= $max_recurring} {
            return "You can have at most $max_recurring recurring reminders."
        }
        set words [lrange $words 2 end]
        # Optional first occurrence: "every 1d at 09:00 ..."
        set r [::timeutil::when $words $tz $now]
        if {$r ne "" && [string tolower [lindex $words 0]] in {at @ a}} {
            lassign $r due used
            set words [lrange $words $used end]
        } else {
            set due [expr {$now + $every}]
        }
    } else {
        set r [::timeutil::when $words $tz $now]
        if {$r eq ""} {
            return "I don't understand when. Examples: 10m, 2h30m, at 18:30, tomorrow 9:00, friday 20:00, 24/12 20:00"
        }
        lassign $r due used
        set words [lrange $words $used end]
    }
    set text [string trim [join $words]]
    regsub {^(to|que|de)\s+} $text "" text
    if {$text eq ""} {return "What should I remind you about? (!remind 10m <text>)"}
    if {$due - $now < $min_delay} {return "That's too soon: at least $min_delay seconds."}
    if {$due - $now > $max_ahead} {return "That's too far away (max [::timeutil::human $max_ahead])."}
    if {![string equal -nocase $target $nick] && [count $owner others] >= $max_for_others} {
        return "You can set at most $max_for_others reminders for other people."
    }
    set id $nextid
    incr nextid
    lappend list [dict create id $id owner $owner ownernick $nick target $target \
        targetid [expr {[string equal -nocase $target $nick] ? $owner : "n:[string tolower $target]"}] \
        chan $chan private $private text $text due $due every $every created $now waiting 0]
    save
    set whom [expr {[string equal -nocase $target $nick] ? "you" : $target}]
    set when "[::timeutil::fmt $due $tz {%a %d %b %H:%M %Z}] ([::timeutil::rel $due $now])"
    if {$every} {
        return "OK #$id: I'll remind $whom every [::timeutil::human $every], next $when."
    }
    return "OK #$id: I'll remind $whom $when."
}

# ----------------------------- DELIVERY -----------------------------

# Where is the target now? Returns the nick to use, or "" if not online
proc ::reminders::find {r} {
    set target [dict get $r target]
    set tid [dict get $r targetid]
    foreach chan [channels] {
        if {[onchan $target $chan]} {return $target}
    }
    # Same Q account under another nick
    if {[string match a:* $tid]} {
        set acc [string range $tid 2 end]
        foreach chan [channels] {
            foreach n [chanlist $chan] {
                if {[string match -nocase "*@$acc.users.quakenet.org" [getchanhost $n $chan]]} {return $n}
            }
        }
    }
    return ""
}

proc ::reminders::deliver {r nick} {
    variable lastfired
    set now [clock seconds]
    set text [dict get $r text]
    # Reminder :: nick: text (From: x | Set: 2 hours ago | Late: 5 minutes)
    set f {}
    if {![string equal -nocase [dict get $r ownernick] [dict get $r target]]} {
        lappend f [::web::lbl From [dict get $r ownernick]]
    }
    lappend f [::web::lbl Set "[::timeutil::human [expr {$now - [dict get $r created]}]] ago"]
    if {$now - [dict get $r due] > 120} {lappend f [::web::lbl Late [::timeutil::human [expr {$now - [dict get $r due]}]]]}
    set tail "[::web::b $text] ([::web::fields $f])"
    set chan [dict get $r chan]
    if {[dict get $r private] || $chan eq "" || ![validchan $chan] || ![onchan $nick $chan]} {
        puthelp "NOTICE $nick :[::web::msg Reminder $tail]"
    } else {
        puthelp "PRIVMSG $chan :[::web::msg Reminder "$nick: $tail"]"
    }
    set lastfired([dict get $r targetid]) [list $now $r]
}

proc ::reminders::tick {} {
    variable list
    set now [clock seconds]
    set changed 0
    set keep {}
    foreach r $list {
        if {[dict get $r due] > $now} {
            lappend keep $r
            continue
        }
        set nick [find $r]
        if {$nick eq ""} {
            # Deliver when they come back
            if {![dict get $r waiting]} {dict set r waiting 1; set changed 1}
            lappend keep $r
            continue
        }
        deliver $r $nick
        set changed 1
        if {[dict get $r every] > 0} {
            set due [dict get $r due]
            while {$due <= $now} {incr due [dict get $r every]}
            dict set r due $due
            dict set r waiting 0
            lappend keep $r
        }
    }
    set list $keep
    if {$changed} {save}
    utimer 10 ::reminders::tick
}

# Someone appeared: hand over reminders that were waiting for them
proc ::reminders::arrived {nick uhost} {
    variable list
    set id [who $nick $uhost]
    set nid "n:[string tolower $nick]"
    set changed 0
    set keep {}
    set now [clock seconds]
    foreach r $list {
        if {[dict get $r waiting] && [dict get $r due] <= $now &&
            ([dict get $r targetid] eq $id || [dict get $r targetid] eq $nid)} {
            deliver $r $nick
            set changed 1
            if {[dict get $r every] > 0} {
                set due [dict get $r due]
                while {$due <= $now} {incr due [dict get $r every]}
                dict set r due $due
                dict set r waiting 0
                lappend keep $r
            }
            continue
        }
        lappend keep $r
    }
    set list $keep
    if {$changed} {save}
}

bind join - * ::reminders::on_join
proc ::reminders::on_join {nick uhost hand chan} {
    if {![isbotnick $nick]} {arrived $nick $uhost}
}

bind nick - * ::reminders::on_nick
proc ::reminders::on_nick {nick uhost hand chan newnick} {
    variable list
    # Reminders for the old nick follow the person
    set old "n:[string tolower $nick]"
    set changed 0
    set new {}
    foreach r $list {
        if {[dict get $r targetid] eq $old} {
            dict set r target $newnick
            dict set r targetid "n:[string tolower $newnick]"
            set changed 1
        }
        lappend new $r
    }
    set list $new
    if {$changed} {save}
    arrived $newnick $uhost
}

# ----------------------------- COMMANDS -----------------------------

proc ::reminders::list_for {nick uhost} {
    variable list
    set owner [who $nick $uhost]
    set tz [tz_of $owner]
    set out {}
    foreach r [lsort -integer -index 1 [lmap r $list {list $r [dict get $r due]}]] {
        set r [lindex $r 0]
        if {[dict get $r owner] ne $owner && [dict get $r targetid] ne $owner} continue
        # #3 text (When: Fri 24 Oct 18:00, in 2 hours | Every: 1 day | For: x | From: y)
        set f [list [::web::lbl When "[::timeutil::fmt [dict get $r due] $tz {%a %d %b %H:%M}], [::timeutil::rel [dict get $r due]]"]]
        if {[dict get $r every]} {lappend f [::web::lbl Every [::timeutil::human [dict get $r every]]]}
        if {![string equal -nocase [dict get $r target] [dict get $r ownernick]]} {
            lappend f [::web::lbl For [dict get $r target]]
            if {[dict get $r owner] ne $owner} {lappend f [::web::lbl From [dict get $r ownernick]]}
        }
        lappend out "[::web::dim #[dict get $r id]] [::web::b [::web::trim [dict get $r text] 120]] ([::web::fields $f])"
    }
    return $out
}

proc ::reminders::delete {nick uhost hand chan arg} {
    variable list
    set owner [who $nick $uhost]
    set isop [expr {$chan ne "" && [matchattr $hand o|o $chan]}]
    set n 0
    set keep {}
    foreach r $list {
        set mine [expr {[dict get $r owner] eq $owner || [dict get $r targetid] eq $owner}]
        set match [expr {$arg eq "all" ? $mine : [dict get $r id] eq [string trimleft $arg #]}]
        if {$match && ($mine || ($isop && [dict get $r chan] eq $chan))} {
            incr n
            continue
        }
        lappend keep $r
    }
    set list $keep
    if {$n} {save}
    return $n
}

proc ::reminders::command {nick uhost hand chan text {private 0}} {
    variable tzs
    set words [regexp -all -inline {\S+} $text]
    set sub [string tolower [lindex $words 0]]
    set to [expr {$private ? "notice" : "chan"}]
    switch -- $sub {
        "" - help {
            notice $nick "Usage: [::web::b !remind] <when> <text> | [::web::b !remind] <nick> <when> <text> | [::web::b {!remind every}] <interval> \[at <time>\] <text> | [::web::b !reminders] | [::web::b {!remind del}] <id|all> | [::web::b {!remind tz}] <Area/City> | [::web::b !snooze] \[interval\]"
            notice $nick "[::web::lbl When {10m, 2h30m, in 1 hour, at 18:30, tomorrow 9:00, friday 20:00, 24/12 20:00, dec 24, manana 9:00}]"
            return
        }
        list {
            set l [list_for $nick $uhost]
            if {![llength $l]} {notice $nick "You have no reminders."; return}
            foreach line [lrange $l 0 14] {notice $nick $line}
            if {[llength $l] > 15} {notice $nick "... and [expr {[llength $l] - 15}] more"}
            return
        }
        del - delete - rm {
            set arg [string tolower [lindex $words 1]]
            if {$arg eq ""} {notice $nick "Usage: !remind del <id|all>"; return}
            set n [delete $nick $uhost $hand $chan $arg]
            notice $nick [expr {$n ? "Deleted $n reminder[expr {$n == 1 ? "" : "s"}]." : "Nothing to delete (see !reminders)."}]
            return
        }
        tz - timezone {
            set owner [who $nick $uhost]
            set z [lindex $words 1]
            if {$z eq ""} {
                set cur [tz_of $owner]
                notice $nick "Your timezone: [expr {$cur eq "" ? "server default ([clock format [clock seconds] -format %Z])" : $cur}]. Set it with !remind tz Europe/Madrid"
                return
            }
            if {![::timeutil::valid_tz $z]} {notice $nick "Unknown timezone $z. Use Area/City, e.g. Europe/Madrid, America/Mexico_City."; return}
            set tzs($owner) $z
            save
            notice $nick "Timezone set to $z (now [::timeutil::fmt [clock seconds] $z {%H:%M %Z}])."
            return
        }
    }
    # "!remind me 10m ..." / "!remind pepe 10m ..."
    set target $nick
    if {$sub eq "me" || $sub eq "a" && [string tolower [lindex $words 1]] eq "mi"} {
        set words [lrange $words [expr {$sub eq "me" ? 1 : 2}] end]
    } elseif {!$private && $chan ne "" && [onchan [lindex $words 0] $chan] && ![isbotnick [lindex $words 0]] &&
              [::timeutil::duration [lindex $words 0]] eq ""} {
        set target [lindex $words 0]
        set words [lrange $words 1 end]
    }
    set msg [add $nick $uhost $chan $target $words $private]
    if {$private} {
        notice $nick $msg
    } else {
        puthelp "PRIVMSG $chan :[::web::msg Reminder "$nick: $msg"]"
    }
}

bind pub - !remind ::reminders::pub_remind
bind pub - !reminder ::reminders::pub_remind
bind pub - !recuerda ::reminders::pub_remind
proc ::reminders::pub_remind {nick uhost hand chan text} {
    if {![channel get $chan reminders] || [flood $uhost]} {return 0}
    command $nick $uhost $hand $chan $text
    return 1
}

bind pub - !at ::reminders::pub_at
proc ::reminders::pub_at {nick uhost hand chan text} {
    if {![channel get $chan reminders] || [flood $uhost]} {return 0}
    command $nick $uhost $hand $chan "at $text"
    return 1
}

bind pub - !reminders ::reminders::pub_list
proc ::reminders::pub_list {nick uhost hand chan text} {
    if {![channel get $chan reminders] || [flood $uhost]} {return 0}
    command $nick $uhost $hand $chan "list"
    return 1
}

bind pub - !snooze ::reminders::pub_snooze
proc ::reminders::pub_snooze {nick uhost hand chan text} {
    variable lastfired
    variable snooze_window
    variable list
    variable nextid
    if {![channel get $chan reminders] || [flood $uhost]} {return 0}
    set id [who $nick $uhost]
    set nid "n:[string tolower $nick]"
    set key [expr {[info exists lastfired($id)] ? $id : $nid}]
    if {![info exists lastfired($key)] || [clock seconds] - [lindex $lastfired($key) 0] > $snooze_window} {
        notice $nick "Nothing to snooze."
        return 0
    }
    set secs [::timeutil::duration [expr {[string trim $text] eq "" ? "10m" : [string trim $text]}]]
    if {$secs eq "" || $secs < 60} {notice $nick "Usage: !snooze \[interval\] (e.g. !snooze 15m)"; return 0}
    set r [lindex $lastfired($key) 1]
    set now [clock seconds]
    dict set r id $nextid
    incr nextid
    dict set r due [expr {$now + $secs}]
    dict set r every 0
    dict set r waiting 0
    dict set r created $now
    lappend list $r
    unset lastfired($key)
    save
    puthelp "PRIVMSG $chan :[::web::msg Reminder "$nick: snoozed, I'll remind you again in [::web::b [::timeutil::human $secs]]."]"
    return 1
}

bind msg - remind ::reminders::msg_remind
proc ::reminders::msg_remind {nick uhost hand text} {
    if {[flood $uhost]} {return 0}
    command $nick $uhost $hand "" $text 1
    return 1
}

bind dcc m reminders ::reminders::dcc_list
proc ::reminders::dcc_list {hand idx text} {
    variable list
    set who [string tolower [string trim $text]]
    set n 0
    foreach r $list {
        if {$who ne "" && ![string match -nocase "*$who*" "[dict get $r ownernick] [dict get $r target]"]} continue
        putdcc $idx [format "#%-4s %s  %-12s -> %-12s %s %s" [dict get $r id] \
            [::timeutil::fmt [dict get $r due] "" "%Y-%m-%d %H:%M"] [dict get $r ownernick] \
            [dict get $r target] [expr {[dict get $r chan] eq "" ? "(private)" : [dict get $r chan]}] \
            [::web::trim [dict get $r text] 60]]
        incr n
    }
    putdcc $idx "$n reminder(s)."
    return 1
}

# ------------------------------ STARTUP ------------------------------

if {![info exists ::reminders::loaded]} {
    ::reminders::load
    set ::reminders::loaded 1
}
apply {{} {
    foreach t [utimers] {
        if {[string match ::reminders::* [lindex $t 1]]} {killutimer [lindex $t 2]}
    }
}}
utimer 10 ::reminders::tick

putlog "reminders.tcl loaded ([llength $::reminders::list] pending)"
