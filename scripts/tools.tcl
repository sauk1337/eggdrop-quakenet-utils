# =====================================================================
#  tools.tcl  v1.2.0  -  Op commands, !seen and join greeting
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Basic channel commands for the bot's ops, a persistent !seen and an
#    optional greeting notice. Masters/owners and the bot can't be
#    kicked, banned or deopped with these commands.
#
#  REQUIREMENTS
#    web.tcl (load it first, for the output style)
#
#  SETUP
#    .chanset #chan greet-msg Welcome %nick% to %chan%, please read the topic.
#
#  COMMANDS (channel)
#    !seen <nick>                         everyone
#    !op | !deop | !voice | !devoice [nicks]          ops (o|o)
#    !kick <nick> [reason] | !kb <nick> [reason]      ops
#    !ban <nick|mask> [minutes] [reason] | !unban <mask>   ops
#    !topic <text>                                    ops
#    (!help is provided by help.tcl)
# =====================================================================

namespace eval ::tools {
    variable seenfile "seen.db"
    variable seen_days 90            ;# forget entries older than this
    variable kb_time 60              ;# default ban minutes for !kb / !ban
    variable throttle 5              ;# seconds between public commands per host

    variable seen
    variable last
}

setudef str greet-msg

proc ::tools::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

# Never act on the bot itself or on masters/owners
proc ::tools::protected {nick chan} {
    if {[isbotnick $nick]} {return 1}
    set h [nick2hand $nick $chan]
    expr {$h ne "" && $h ne "*" && [matchattr $h mn|mn $chan]}
}

proc ::tools::massmode {chan mode nicks default} {
    if {![botisop $chan]} return
    if {![llength $nicks]} {set nicks [list $default]}
    foreach n $nicks {
        if {![onchan $n $chan]} continue
        if {[string index $mode 0] eq "-" && [protected $n $chan]} continue
        pushmode $chan $mode $n
    }
    flushmode $chan
}

bind pub o|o !op      ::tools::cmd_op
bind pub o|o !deop    ::tools::cmd_deop
bind pub o|o !voice   ::tools::cmd_voice
bind pub o|o !devoice ::tools::cmd_devoice
proc ::tools::cmd_op      {nick uhost hand chan text} {massmode $chan +o [split [string trim $text]] $nick; return 1}
proc ::tools::cmd_deop    {nick uhost hand chan text} {massmode $chan -o [split [string trim $text]] $nick; return 1}
proc ::tools::cmd_voice   {nick uhost hand chan text} {massmode $chan +v [split [string trim $text]] $nick; return 1}
proc ::tools::cmd_devoice {nick uhost hand chan text} {massmode $chan -v [split [string trim $text]] $nick; return 1}

proc ::tools::target {nick chan text} {
    set args [split [string trim $text]]
    set who [lindex $args 0]
    if {$who eq ""} {
        puthelp "NOTICE $nick :[::web::msg Op "Missing nick."]"
        return ""
    }
    if {![onchan $who $chan]} {
        puthelp "NOTICE $nick :[::web::msg Op "[::web::b $who] is not on $chan."]"
        return ""
    }
    if {[protected $who $chan]} {
        puthelp "NOTICE $nick :[::web::msg Op "I can't do that to [::web::b $who]."]"
        return ""
    }
    return $who
}

bind pub o|o !kick ::tools::cmd_kick
proc ::tools::cmd_kick {nick uhost hand chan text} {
    set who [target $nick $chan $text]
    if {$who eq "" || ![botisop $chan]} {return 0}
    set why [join [lrange [split [string trim $text]] 1 end]]
    if {$why eq ""} {set why "Kicked"}
    putkick $chan $who "$why ($nick)"
    return 1
}

bind pub o|o !kb ::tools::cmd_kb
proc ::tools::cmd_kb {nick uhost hand chan text} {
    variable kb_time
    set who [target $nick $chan $text]
    if {$who eq "" || ![botisop $chan]} {return 0}
    set why [join [lrange [split [string trim $text]] 1 end]]
    if {$why eq ""} {set why "Banned"}
    set host [lindex [split [getchanhost $who $chan] @] end]
    newchanban $chan "*!*@$host" $hand "$why ($nick)" $kb_time
    putkick $chan $who "$why ($nick)"
    return 1
}

bind pub o|o !ban ::tools::cmd_ban
proc ::tools::cmd_ban {nick uhost hand chan text} {
    variable kb_time
    set args [split [string trim $text]]
    set mask [lindex $args 0]
    if {$mask eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !ban] <nick|mask> \[minutes\] \[reason\]"
        return 0
    }
    set mins $kb_time
    set rest [lrange $args 1 end]
    if {[string is digit -strict [lindex $rest 0]]} {
        set mins [lindex $rest 0]
        set rest [lrange $rest 1 end]
    }
    set why [join $rest]
    if {$why eq ""} {set why "Banned"}
    if {[string first ! $mask] < 0 && [onchan $mask $chan]} {
        if {[protected $mask $chan]} {
            puthelp "NOTICE $nick :[::web::msg Ban "I can't ban [::web::b $mask]."]"
            return 0
        }
        set mask "*!*@[lindex [split [getchanhost $mask $chan] @] end]"
    } elseif {[string first ! $mask] < 0} {
        set mask "$mask!*@*"
    }
    newchanban $chan $mask $hand "$why ($nick)" $mins
    puthelp "NOTICE $nick :[::web::line Ban $mask [list [::web::lbl Channel $chan] [::web::lbl Time "$mins min"] [::web::lbl Reason $why]]]"
    return 1
}

bind pub o|o !unban ::tools::cmd_unban
proc ::tools::cmd_unban {nick uhost hand chan text} {
    set mask [lindex [split [string trim $text]] 0]
    if {$mask eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !unban] <mask>"
        return 0
    }
    if {[isban $mask $chan]} {killchanban $chan $mask}
    if {[isban $mask]} {killban $mask}
    if {[botisop $chan]} {pushmode $chan -b $mask}
    puthelp "NOTICE $nick :[::web::msg Ban "[::web::b $mask] removed from $chan."]"
    return 1
}

bind pub o|o !topic ::tools::cmd_topic
proc ::tools::cmd_topic {nick uhost hand chan text} {
    if {[string trim $text] eq ""} {return 0}
    putserv "TOPIC $chan :$text"
    return 1
}

# ------------------------------ SEEN ------------------------------

proc ::tools::seen_set {nick uhost what} {
    variable seen
    set seen([string tolower $nick]) [list $nick $uhost [clock seconds] $what]
}

bind join - * ::tools::seen_join
bind part - * ::tools::seen_part
bind sign - * ::tools::seen_sign
bind kick - * ::tools::seen_kick
bind nick - * ::tools::seen_nick
bind pubm - * ::tools::seen_pubm
proc ::tools::seen_join {nick uhost hand chan}              {seen_set $nick $uhost "joining $chan"}
proc ::tools::seen_part {nick uhost hand chan {msg ""}}     {seen_set $nick $uhost "leaving $chan[expr {$msg ne "" ? " ($msg)" : ""}]"}
proc ::tools::seen_sign {nick uhost hand chan reason}       {seen_set $nick $uhost "quitting ($reason)"}
proc ::tools::seen_pubm {nick uhost hand chan text}         {seen_set $nick $uhost "talking on $chan"}
proc ::tools::seen_nick {nick uhost hand chan newnick} {
    seen_set $nick $uhost "changing nick to $newnick"
    seen_set $newnick $uhost "on $chan (formerly $nick)"
}
proc ::tools::seen_kick {nick uhost hand chan target reason} {
    seen_set $target [getchanhost $target $chan] "being kicked from $chan by $nick ($reason)"
}

bind pub - !seen ::tools::cmd_seen
proc ::tools::cmd_seen {nick uhost hand chan text} {
    variable seen
    if {[flood $uhost]} {return 0}
    set who [lindex [split [string trim $text]] 0]
    if {$who eq ""} {
        puthelp "PRIVMSG $chan :[::web::msg Seen "$nick: usage [::web::b !seen] <nick>"]"
    } elseif {[isbotnick $who]} {
        puthelp "PRIVMSG $chan :[::web::msg Seen "$nick: I'm right here :)"]"
    } elseif {[string equal -nocase $who $nick]} {
        puthelp "PRIVMSG $chan :[::web::msg Seen "$nick: looking for yourself?"]"
    } elseif {[onchan $who $chan]} {
        puthelp "PRIVMSG $chan :[::web::msg Seen "$nick: [::web::b $who] is on the channel right now."]"
    } elseif {[info exists seen([string tolower $who])]} {
        lassign $seen([string tolower $who]) n uh t what
        set ago [duration [expr {max(1, [clock seconds] - $t)}]]
        puthelp "PRIVMSG $chan :[::web::line Seen $n [list [::web::lbl Host $uh] \
            [::web::lbl "Last seen" "$ago ago"] [::web::lbl Doing $what]]]"
    } else {
        puthelp "PRIVMSG $chan :[::web::msg Seen "$nick: I haven't seen [::web::b $who]."]"
    }
    return 1
}

proc ::tools::seen_save {args} {
    variable seen
    variable seenfile
    variable seen_days
    set limit [expr {[clock seconds] - $seen_days * 86400}]
    set fd [open $seenfile.tmp w]
    fconfigure $fd -encoding utf-8
    foreach k [array names seen] {
        if {[lindex $seen($k) 2] < $limit} {
            unset seen($k)
        } else {
            puts $fd $seen($k)
        }
    }
    close $fd
    file rename -force $seenfile.tmp $seenfile
}

proc ::tools::seen_load {} {
    variable seen
    variable seenfile
    if {![file exists $seenfile]} return
    set fd [open $seenfile r]
    fconfigure $fd -encoding utf-8
    while {[gets $fd line] >= 0} {
        if {[catch {llength $line} n] || $n != 4} continue
        set seen([string tolower [lindex $line 0]]) $line
    }
    close $fd
}

bind evnt - save ::tools::seen_save
if {![array exists ::tools::seen]} {::tools::seen_load}

# ----------------------------- GREETING -----------------------------

bind join - * ::tools::greet
proc ::tools::greet {nick uhost hand chan} {
    if {[isbotnick $nick]} return
    set msg [channel get $chan greet-msg]
    if {$msg eq ""} return
    puthelp "NOTICE $nick :[string map [list %nick% $nick %chan% $chan] $msg]"
}

putlog "tools.tcl loaded (op commands, !seen, greeting)"
