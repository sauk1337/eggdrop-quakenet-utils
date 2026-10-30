# =====================================================================
#  guard.tcl  v2.1.0  -  QuakeNet channel protection and access levels
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  Author: eggdrop-quakenet-utils contributors (2026, written from scratch)
#  Design based on the 2005 "protection v1.4b" script; its license asks
#  derived works to keep its notice, reproduced at the end of this header.
#
#  DESCRIPTION
#    Access levels 0-10 on top of Eggdrop's user flags, channel
#    commands, and protection against op abuse working together with
#    QuakeNet's Q (L no longer exists on QuakeNet, so only Q is used):
#      - protected modes, bitchmode, protected ops/voices and bans
#      - topic lock, mass mode / mass kick detection
#      - reactions through Q (deopall, recover, clearchan, invite,
#        reop, unbanall) when the bot is kicked/deopped/banned or needs
#        op, invite, key or unban
#      - if Q splits off, autoop is suspended and unknown ops removed;
#        everything is restored when the service is back
#      - auto op / voice / ban on join, autolimit, kick counter
#
#  LEVELS                 Eggdrop flags
#     0 no access         -
#     1 channel autoban   |B          6 channel owner    |n
#     2 channel autodeop  |d          7 global voice     v
#     3 channel voice     |v          8 global operator  o
#     4 channel operator  |o          9 global master    m
#     5 channel master    |m         10 global owner     n
#
#  REQUIREMENTS
#    Eggdrop 1.8 or newer (no blowfish module needed). The bot's Q
#    account needs chanlev +amo (or +n to remove +m/+n flags of abusers).
#    web.tcl (load it first, for the output style)
#
#  SETUP
#    <trigger>status on     (channel owner) enables protection on a channel
#    Default trigger "!", per-user trigger with !mytrigger. Commands also
#    work as "<botnick> <command>", and an optional #channel after the
#    command acts on another channel:  !op #other nick
#
#  COMMANDS                                        (minimum level)
#    showcommands                                   3   your commands
#      (!help / !commands belong to help.tcl)
#    version                                        0
#    levels | methode notice|privmsg | mytrigger [id]   3
#    op | deop | voice | devoice [nicks|masks]      3/4 (3,4,7,8: self only)
#    kick <nick|mask> [reason]                      4
#    ban <nick|#account|mask> [-global] [%1h30m|%0] [reason]   4
#    unban <all|nick|mask|#n> [-global]             4
#    banlist [-global]                              4
#    topic [text|save|resynch|clear]                5
#    mode [-default] <modes|clear>                  5
#    kickmsg [text]   (:nickname: :reason: :counter:)   4
#    autoop | autovoice [on|off]                    5
#    autolimit [#N|off]                             5
#    adduser <nick> <handle> <level>                5
#    access <nick|#handle> [level|clear] [-global]  5
#    whois <nick|#handle> | userlist [-global]      5
#    deluser <nick|#handle>                         10
#    status [on|off]                                6
#    -- need protection on (status on) --
#    punish 1|2|3     (deop | kick | kickban)       5
#    protect <+modes-modes>                         5
#    bitchmode | topicsave [on|off]                 5
#    maxmodes <n:secs> | maxkicks <n:secs>          5
#    reaction <event> <actions...>                  5
#      events: bot-kick mass-mode mass-kick need-op need-invite
#              need-key need-unban
#      actions: deopall recover clearchan invite reop unbanall
#    remflags <+-flags|none>   Q CHANLEV flags removed from abusers  5
#
#  CHANGES FROM 1.4b
#    - Works on Eggdrop 1.8/1.9/1.10. The 1.4b copyright check called
#      "encrypt" (blowfish). Since Eggdrop 1.8 blowfish uses CBC mode with
#      a random IV, so the result never matched and the script called
#      "die" and killed the bot. Removed, with the blowfish requirement.
#    - WHOIS lookups no longer share global variables: two commands at
#      the same time can't mix up their targets any more.
#    - Levels 1/2 were shown swapped in whois/access; fixed.
#    - Q only (L was retired from QuakeNet). Q is identified by its real
#      host (TheQBot@CServe.quakenet.org), so an impostor called "Q"
#      is ignored, and "PRIVMSG Q,L" can no longer happen.
#    - Undefined variable in the topic protection, mode parser bugs
#      (punish methods 1 and 2), autolimit with a channel key: fixed.
#    - Rude messages and advertising removed.
#
# ---------------------------------------------------------------------
#  Original copyright and license (protection v1.4b):
#
#  This software is copyrighted (c) 2005 by Alexander Martin 'am' #xela.
#  All rights reserved. The following terms apply to all files associated with
#  the software unless explicitly disclaimed in individual files or
#  directories.
#
#  The authors hereby grant permission to use, copy, modify, distribute,
#  and license this software for any purpose, provided that existing
#  copyright notices are retained in all copies and that this notice is
#  included verbatim in any distributions. No written agreement, license,
#  or royalty fee is required for any of the authorized uses.
#  Modifications to this software may be copyrighted by their authors and
#  need not follow the licensing terms described here, provided that the
#  new terms are clearly indicated on the first page of each file where
#  they apply.
#
#  IN NO EVENT SHALL THE AUTHORS OR DISTRIBUTORS BE LIABLE TO ANY PARTY
#  FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES
#  ARISING OUT OF THE USE OF THIS SOFTWARE, ITS DOCUMENTATION, OR ANY
#  DERIVATIVES THEREOF, EVEN IF THE AUTHORS HAVE BEEN ADVISED OF THE
#  POSSIBILITY OF SUCH DAMAGE.
#
#  THE AUTHORS AND DISTRIBUTORS SPECIFICALLY DISCLAIM ANY WARRANTIES,
#  INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT.  THIS SOFTWARE
#  IS PROVIDED ON AN "AS IS" BASIS, AND THE AUTHORS AND DISTRIBUTORS HAVE
#  NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR
#  MODIFICATIONS.
#
#  GOVERNMENT USE: If you are acquiring this software on behalf of the
#  U.S. government, the Government shall have only "Restricted Rights"
#  in the software and related documentation as defined in the Federal
#  Acquisition Regulations (FARs) in Clause 52.227.19 (c) (2).  If you
#  are acquiring the software on behalf of the Department of Defense, the
#  software shall be classified as "Commercial Computer Software" and the
#  Government shall have only "Restricted Rights" as defined in Clause
#  252.227-7013 (c) (1) of DFARs.  Notwithstanding the foregoing, the
#  authors grant the U.S. Government and others acting in its behalf
#  permission to use and distribute the software in accordance with the
#  terms specified in this license.
#
#  The modifications in this file (the 2026 rewrite) are released under
#  the same terms.
# =====================================================================

namespace eval ::guard {
    # ------------------------- CONFIGURATION -------------------------
    variable trigger "!"
    variable triggers {1 $ 2 ! 3 ? 4 . 5 - 6 ² 7 % 8 & 9 * 10 :}
    variable default_ban_mins 60
    variable punish_ban_mins 15
    variable punish_all_kicks 1      ;# punish kicks by ops without bot access
    variable reveal_delayed 1        ;# after -D, voice+devoice hidden users once
    variable join_flood 5            ;# joins per second that suspend autoop

    variable services {
        Q TheQBot@CServe.quakenet.org
    }
    variable actions {deopall recover clearchan invite reop unbanall}
    variable reaction_defaults {
        bot-kick    deopall
        mass-mode   deopall
        mass-kick   deopall
        need-invite {clearchan invite}
        need-key    {clearchan invite}
        need-unban  {unbanall invite}
        need-op     {deopall reop}
    }
    variable levels {
        1 -|B  2 -|d  3 -|v  4 -|o  5 -|m  6 -|n
        7 v|-  8 o|-  9 m|-  10 n|-
    }
    variable level_names {
        0 "no access" 1 "channel autoban" 2 "channel autodeop" 3 "channel voice"
        4 "channel operator" 5 "channel master" 6 "channel owner" 7 "global voice"
        8 "global operator" 9 "global master" 10 "global owner"
    }
    # command -> {category allowed-levels...}
    #   % general   & needs protection on   + help   - everyone
    variable required {
        mytrigger    {% 3 4 5 6 7 8 9 10}
        levels       {% 3 4 5 6 7 8 9 10}
        methode      {% 3 4 5 6 7 8 9 10}
        protect      {& 5 6 9 10}
        topicsave    {& 5 6 9 10}
        status       {% 6 10}
        reaction     {& 5 6 9 10}
        adduser      {% 5 6 9 10}
        access       {% 5 6 9 10}
        deluser      {% 10}
        whois        {% 5 6 9 10}
        userlist     {% 5 6 9 10}
        remflags     {& 5 6 9 10}
        banlist      {% 4 5 6 8 9 10}
        maxmodes     {& 5 6 9 10}
        maxkicks     {& 5 6 9 10}
        bitchmode    {& 5 6 9 10}
        mode         {% 5 6 9 10}
        punish       {& 5 6 9 10}
        kickmsg      {% 4 5 6 8 9 10}
        kick         {% 4 5 6 8 9 10}
        ban          {% 4 5 6 8 9 10}
        unban        {% 4 5 6 8 9 10}
        autoop       {% 5 6 9 10}
        autovoice    {% 5 6 9 10}
        autolimit    {% 5 6 9 10}
        op           {% 4 5 6 8 9 10}
        voice        {% 3 4 5 6 7 8 9 10}
        deop         {% 4 5 6 8 9 10}
        devoice      {% 3 4 5 6 7 8 9 10}
        topic        {% 5 6 9 10}
        showcommands {+ 3 4 5 6 7 8 9 10}
        version      {- 0}
        copyright    {- 0}
    }
    # Levels whose mode changes are never treated as abuse
    variable trusted_levels {5 6 9 10}
    variable version "2.1.0"

    # --------------------- STATE (do not touch) ---------------------
    variable whois                   ;# whois(nick) -> pending lookup dict
    variable hits
    variable pending                 ;# pending(chan,offender) -> punishment queued
    variable reop                    ;# reop(chan) -> nicks deopped when the service left
    variable autoop_off              ;# autoop_off(chan) -> 1
    variable lastreact
}

# Same setting names as protection v1.4b: existing chanfiles keep working
apply {{} {
    foreach f {protection onjoin-voice onjoin-operator bitchmode topicsave first-use service-prot} {setudef flag $f}
    foreach s {kick-id kick-message protected-modes channel-topic punish-methode remove-flags
               maximal-modes maximal-kicks autolimit} {setudef str $s}
    foreach r [dict keys $::guard::reaction_defaults] {setudef str reaction-$r}
}}

# ============================== HELPERS ==============================

proc ::guard::level {hand chan} {
    variable levels
    if {$hand eq "" || $hand eq "*" || ![validuser $hand]} {return 0}
    set l 0
    dict for {n f} $levels {
        if {[matchattr $hand $f $chan]} {set l $n}
    }
    return $l
}

proc ::guard::lvl_name {l} {
    variable level_names
    dict get $level_names $l
}

# "Q" if Q is on the channel (verified host), or ""
proc ::guard::service {chan} {
    variable services
    dict for {nick host} $services {
        if {[onchan $nick $chan] && [string equal -nocase [getchanhost $nick $chan] $host]} {return $nick}
    }
    return ""
}

proc ::guard::is_service {nick uhost} {
    variable services
    expr {[dict exists $services $nick] && [string equal -nocase [dict get $services $nick] $uhost]}
}

proc ::guard::banmask {nick uhost} {
    set host [lindex [split $uhost @] end]
    if {[string match -nocase *.users.quakenet.org $host]} {return "*!*@$host"}
    return "*!*@$host"
}

proc ::guard::kickmsg {chan nick reason} {
    set tpl [channel get $chan kick-message]
    if {$tpl eq ""} {set tpl "(:counter:) :reason: (by :nickname:)"}
    set id [channel get $chan kick-id]
    if {![string is integer -strict $id]} {set id 0}
    string map [list :nickname: $nick :reason: $reason :counter: [expr {$id + 1}]] $tpl
}

proc ::guard::pair {chan setting default} {
    set v [channel get $chan $setting]
    if {![regexp {^(\d+):(\d+)$} $v -> a b] || $a < 1 || $b < 1} {return [split $default :]}
    list $a $b
}

proc ::guard::count {key window} {
    variable hits
    set now [clock seconds]
    set l {}
    if {[info exists hits($key)]} {
        foreach t $hits($key) {if {$now - $t < $window} {lappend l $t}}
    }
    lappend l $now
    set hits($key) $l
    llength $l
}

proc ::guard::defaults {chan} {
    variable reaction_defaults
    if {![string is integer -strict [channel get $chan kick-id]]} {channel set $chan kick-id 0}
    pair $chan maximal-modes 6:30
    if {![regexp {^\d+:\d+$} [channel get $chan maximal-modes]]} {channel set $chan maximal-modes 6:30}
    if {![regexp {^\d+:\d+$} [channel get $chan maximal-kicks]]} {channel set $chan maximal-kicks 3:10}
    if {[channel get $chan punish-methode] ni {1 2 3}} {channel set $chan punish-methode 3}
    if {[channel get $chan protected-modes] eq ""} {channel set $chan protected-modes "iksprDlb bCnNt"}
    if {[channel get $chan kick-message] eq ""} {channel set $chan kick-message "(:counter:) :reason: (by :nickname:)"}
    dict for {r v} $reaction_defaults {
        if {[channel get $chan reaction-$r] eq ""} {channel set $chan reaction-$r [join $v :]}
    }
}

# Wildcard match where [ ] in nicks are literal
proc ::guard::wmatch {pattern str} {
    string match -nocase [string map {\\ \\\\ [ \\[ ] \\]} $pattern] $str
}

proc ::guard::is_mask {s} {regexp {[*?!@]} $s}

# ============================== REPLIES ==============================

proc ::guard::method {hand} {
    if {[validuser $hand]} {
        set m [string toupper [getuser $hand XTRA methode]]
        if {$m in {NOTICE PRIVMSG}} {return $m}
    }
    return NOTICE
}

proc ::guard::say {ctx text} {
    puthelp "[method [dict get $ctx hand]] [dict get $ctx nick] :[::web::msg Guard $text]"
}

proc ::guard::usage {ctx args} {
    say $ctx "Usage: [dict get $ctx trig] \037?#channel?\037 [join $args]"
}

# ============================== WHOIS ==============================
# One permanent set of raw binds; lookups are keyed by nick, so several
# commands can wait for different (or the same) WHOIS at once.

proc ::guard::lookup {nick callback} {
    variable whois
    set n [string tolower $nick]
    if {[info exists whois($n)]} {
        dict lappend whois($n) callbacks $callback
        return
    }
    set whois($n) [dict create nick $nick user "" host "" account "" oper 0 callbacks [list $callback]]
    putquick "WHOIS $nick"
    utimer 15 [list ::guard::lookup_end $n]
}

proc ::guard::raw_field {key text} {
    variable whois
    set n [string tolower [lindex [split $text] 1]]
    if {![info exists whois($n)]} {return ""}
    return $n
}

bind raw - 311 ::guard::raw311
proc ::guard::raw311 {from key text} {
    variable whois
    set n [raw_field $key $text]
    if {$n ne ""} {
        dict set whois($n) user [lindex [split $text] 2]
        dict set whois($n) host [lindex [split $text] 3]
    }
    return 0
}

bind raw - 330 ::guard::raw330
proc ::guard::raw330 {from key text} {
    variable whois
    set n [raw_field $key $text]
    if {$n ne ""} {dict set whois($n) account [lindex [split $text] 2]}
    return 0
}

bind raw - 313 ::guard::raw313
proc ::guard::raw313 {from key text} {
    variable whois
    set n [raw_field $key $text]
    if {$n ne ""} {dict set whois($n) oper 1}
    return 0
}

bind raw - 318 ::guard::raw318
proc ::guard::raw318 {from key text} {
    lookup_end [string tolower [lindex [split $text] 1]]
    return 0
}

proc ::guard::lookup_end {n} {
    variable whois
    if {![info exists whois($n)]} return
    set w $whois($n)
    unset whois($n)
    set info [dict create nick [dict get $w nick] found [expr {[dict get $w user] ne ""}] \
        user [dict get $w user] host [dict get $w host] account [dict get $w account] \
        oper [dict get $w oper] masks [masks_of $w]]
    foreach cb [dict get $w callbacks] {
        if {[catch {{*}$cb $info} err]} {putlog "guard: $err"}
    }
}

# Masks to recognise/ban someone: their host (unless +x) and their account
proc ::guard::masks_of {w} {
    set out {}
    set host [dict get $w host]
    if {$host ne "" && ![string match -nocase *.users.quakenet.org $host]} {
        lappend out [maskhost "[dict get $w nick]![dict get $w user]@$host"]
    }
    if {[dict get $w account] ne ""} {lappend out "*!*@[dict get $w account].users.quakenet.org"}
    return $out
}

# Handle(s) whose hostmasks match any of the masks
proc ::guard::handles_for {masks {exclude ""}} {
    set out {}
    foreach h [userlist] {
        if {$h eq $exclude} continue
        foreach uh [getuser $h hosts] {
            foreach m $masks {
                if {([wmatch $m $uh] || [wmatch $uh $m]) && $h ni $out} {lappend out $h}
            }
        }
    }
    return $out
}

# ============================== DISPATCH ==============================

bind pubm - * ::guard::on_pubm
proc ::guard::on_pubm {nick uhost hand chan text} {
    variable trigger
    variable required
    set words [regexp -all -inline {\S+} $text]
    if {![llength $words]} return
    set utrig [expr {[validuser $hand] ? [getuser $hand XTRA trigger] : ""}]
    if {$utrig eq ""} {set utrig $trigger}
    set first [lindex $words 0]
    if {[string equal -nocase $first $::botnick]} {
        set cmd [string tolower [lindex $words 1]]
        set trig "$::botnick $cmd"
        set rest [lrange $words 2 end]
    } elseif {[string index $first 0] eq $utrig && [string length $first] > 1} {
        set cmd [string tolower [string range $first 1 end]]
        set trig $first
        set rest [lrange $words 1 end]
    } else {
        return
    }
    if {![dict exists $required $cmd]} return
    # Optional target channel
    if {[string index [lindex $rest 0] 0] eq "#" && [validchan [lindex $rest 0]]} {
        set chan [lindex $rest 0]
        set rest [lrange $rest 1 end]
    }
    set req [dict get $required $cmd]
    set lvl [level $hand $chan]
    set ctx [dict create nick $nick uhost $uhost hand $hand chan $chan trig $trig cmd $cmd args $rest level $lvl]
    if {0 ni [lrange $req 1 end] && $lvl ni [lrange $req 1 end]} {
        if {[validuser $hand]} {say $ctx "You don't have enough access on $chan to use [string toupper $cmd]."}
        return
    }
    if {[lindex $req 0] eq "&" && ![channel get $chan protection]} {
        say $ctx "[string toupper $cmd] needs the protection enabled on $chan (status on)."
        return
    }
    if {$cmd in {op deop voice devoice kick mode topic} && ![botisop $chan]} {
        say $ctx "I need op on $chan for [string toupper $cmd]."
        return
    }
    set proc $cmd
    switch -- $cmd {
        op - deop - voice - devoice {set proc usermode}
        autoop - autovoice {set proc automode}
        showcommands {set proc showcommands}
        version - copyright {set proc version}
    }
    if {[channel get $chan protection]} {defaults $chan}
    if {[catch {cmd_$proc $ctx} err]} {
        putlog "guard: error in $cmd: $err"
    }
}

# ============================== COMMANDS ==============================

proc ::guard::cmd_version {ctx} {
    variable version
    if {[count "ver,[dict get $ctx chan]" 90] > 1} return
    puthelp "PRIVMSG [dict get $ctx chan] :[::web::line Guard "guard.tcl v$version" [list [::web::lbl Project eggdrop-quakenet-utils]]]"
}

proc ::guard::cmd_levels {ctx} {
    variable level_names
    dict for {n name} $level_names {say $ctx [format "%2d %s" $n $name]}
}

proc ::guard::cmd_methode {ctx} {
    set m [string toupper [lindex [dict get $ctx args] 0]]
    if {$m ni {NOTICE PRIVMSG}} {
        say $ctx "You receive my messages by [method [dict get $ctx hand]]."
        usage $ctx "\037notice\037|\037privmsg\037"
        return
    }
    setuser [dict get $ctx hand] XTRA methode $m
    say $ctx "Messages will be sent by $m."
}

proc ::guard::cmd_mytrigger {ctx} {
    variable triggers
    variable trigger
    set id [lindex [dict get $ctx args] 0]
    if {![dict exists $triggers $id]} {
        set cur [getuser [dict get $ctx hand] XTRA trigger]
        say $ctx "Your trigger: [expr {$cur eq "" ? "$trigger (default)" : $cur}]"
        usage $ctx "\037id\037"
        say $ctx "Available: [join [lmap {k v} $triggers {string cat "#$k ($v)"}] {, }]"
        return
    }
    setuser [dict get $ctx hand] XTRA trigger [dict get $triggers $id]
    say $ctx "Your trigger is now: [dict get $triggers $id]"
}

proc ::guard::cmd_status {ctx} {
    set chan [dict get $ctx chan]
    switch -- [string tolower [lindex [dict get $ctx args] 0]] {
        on {
            if {[channel get $chan protection]} {say $ctx "Protection is already on in $chan."; return}
            set svc [service $chan]
            if {$svc eq ""} {say $ctx "Q must be on $chan."; return}
            channel set $chan +protection +service-prot
            if {[channel get $chan chanmode] eq ""} {channel set $chan chanmode "+Cnt"}
            defaults $chan
            say $ctx "Protection enabled on $chan (service: $svc). See [string index [dict get $ctx trig] 0]showcommands"
        }
        off {
            if {![channel get $chan protection]} {say $ctx "Protection is already off in $chan."; return}
            if {[channel get $chan autolimit] ne "" && [string match *l* [lindex [getchanmode $chan] 0]] && [botisop $chan]} {
                putquick "MODE $chan -l"
            }
            channel set $chan -protection autolimit ""
            say $ctx "Protection disabled on $chan."
        }
        default {
            say $ctx "Protection is [expr {[channel get $chan protection] ? "on" : "off"}] in $chan."
            usage $ctx "\037on\037|\037off\037"
        }
    }
}

proc ::guard::cmd_punish {ctx} {
    set chan [dict get $ctx chan]
    set m [lindex [dict get $ctx args] 0]
    if {$m ni {1 2 3}} {
        say $ctx "Punish method on $chan: [channel get $chan punish-methode] (1 deop, 2 kick, 3 kickban)"
        usage $ctx "\0371\037|\0372\037|\0373\037"
        return
    }
    channel set $chan punish-methode $m
    say $ctx "Punish method on $chan set to $m."
}

proc ::guard::cmd_reaction {ctx} {
    variable reaction_defaults
    variable actions
    set chan [dict get $ctx chan]
    set ev [string tolower [lindex [dict get $ctx args] 0]]
    set acts [string tolower [lrange [dict get $ctx args] 1 end]]
    if {![dict exists $reaction_defaults $ev]} {
        foreach e [dict keys $reaction_defaults] {
            say $ctx "[string toupper $e]: [join [split [channel get $chan reaction-$e] :] {, }]"
        }
        usage $ctx "\037[join [dict keys $reaction_defaults] \037|\037]\037" "\037actions\037"
        say $ctx "Actions: [join $actions {, }]"
        return
    }
    if {![llength $acts]} {
        say $ctx "[string toupper $ev] on $chan -> [join [split [channel get $chan reaction-$ev] :] {, }]"
        return
    }
    foreach a $acts {
        if {$a ni $actions} {say $ctx "Unknown action [string toupper $a]. Actions: [join $actions {, }]"; return}
    }
    channel set $chan reaction-$ev [join $acts :]
    say $ctx "[string toupper $ev] on $chan -> [join $acts {, }]"
}

proc ::guard::cmd_mode {ctx} {
    set chan [dict get $ctx chan]
    set a [dict get $ctx args]
    if {![llength $a] || ([string equal -nocase [lindex $a 0] -default] && [llength $a] == 1)} {
        say $ctx "Modes on $chan: [getchanmode $chan] - enforced: [expr {[channel get $chan chanmode] eq "" ? "none" : [channel get $chan chanmode]}]"
        usage $ctx "\037?-default?\037" "\037clear\037|\037+-modes\037"
        return
    }
    if {[string equal -nocase [lindex $a 0] -default]} {
        set m [lindex $a 1]
        if {[string equal -nocase $m clear]} {
            channel set $chan chanmode ""
            say $ctx "Enforced modes of $chan cleared."
            return
        }
        if {![regexp {^[-+cCnNtulikrspmDd]+$} $m]} {say $ctx "Invalid modes: $m"; return}
        channel set $chan chanmode $m
        say $ctx "Enforced modes of $chan set to $m."
        return
    }
    putquick "MODE $chan [join $a]"
}

proc ::guard::cmd_topic {ctx} {
    set chan [dict get $ctx chan]
    set a [dict get $ctx args]
    set saved [channel get $chan channel-topic]
    switch -- [string tolower [lindex $a 0]] {
        "" {
            if {$saved ne ""} {say $ctx "Saved topic of $chan: $saved"}
            usage $ctx "\037new topic\037|\037save\037|\037resynch\037|\037clear\037"
        }
        resynch {
            if {$saved eq ""} {say $ctx "No saved topic."; return}
            set_topic $chan $saved
        }
        clear {
            channel set $chan channel-topic ""
            set_topic $chan ""
            say $ctx "Topic of $chan cleared."
        }
        save {
            if {[topic $chan] eq ""} {say $ctx "$chan has no topic."; return}
            channel set $chan channel-topic [topic $chan]
            say $ctx "Topic of $chan saved."
        }
        default {
            channel set $chan channel-topic [join $a]
            set_topic $chan [join $a]
            say $ctx "Topic of $chan set and saved."
        }
    }
}

proc ::guard::set_topic {chan text} {
    set svc [service $chan]
    if {$svc eq "Q"} {
        putquick "PRIVMSG Q :SETTOPIC $chan $text"
    } else {
        putquick "TOPIC $chan :$text"
    }
}

proc ::guard::cmd_autolimit {ctx} {
    set chan [dict get $ctx chan]
    set a [string tolower [lindex [dict get $ctx args] 0]]
    if {$a eq "off"} {
        channel set $chan autolimit ""
        if {[botisop $chan] && [string match *l* [lindex [getchanmode $chan] 0]]} {putquick "MODE $chan -l"}
        say $ctx "Autolimit disabled on $chan."
        return
    }
    if {![regexp {^#(\d+)$} $a -> n] || $n < 1} {
        set cur [channel get $chan autolimit]
        if {$cur ne ""} {say $ctx "Autolimit on $chan: +$cur"}
        usage $ctx "\037#limit\037|\037off\037"
        return
    }
    channel set $chan autolimit $n
    say $ctx "Autolimit on $chan: users +$n."
    autolimit_chan $chan
}

proc ::guard::cmd_kickmsg {ctx} {
    set chan [dict get $ctx chan]
    set a [dict get $ctx args]
    if {![llength $a]} {
        say $ctx "Kick message of $chan: [channel get $chan kick-message]"
        say $ctx "Variables: :nickname: :reason: :counter:"
        usage $ctx "\037kick message\037"
        return
    }
    channel set $chan kick-message [join $a]
    say $ctx "Kick message of $chan set: [join $a]"
}

proc ::guard::cmd_protect {ctx} {
    set chan [dict get $ctx chan]
    set m [lindex [dict get $ctx args] 0]
    lassign [channel get $chan protected-modes] pos neg
    if {$m eq "" || ![regexp {^[-+cCnNbturkilmsDdp]+$} $m]} {
        say $ctx "Protected modes on $chan: +[string map {% ""} $pos]-[string map {% ""} $neg]"
        usage $ctx "\037+-modes\037 (e.g. +iksprDlb-bCnNt)"
        return
    }
    set pos ""
    set neg ""
    set sign ""
    foreach c [split $m ""] {
        if {$c in {+ -}} {set sign $c; continue}
        if {$c eq "o" || $sign eq ""} continue
        if {$sign eq "+"} {append pos $c} else {append neg $c}
    }
    if {$pos eq "" && $neg eq ""} {say $ctx "Invalid mode list."; return}
    channel set $chan protected-modes "[expr {$pos eq "" ? "%" : $pos}] [expr {$neg eq "" ? "%" : $neg}]"
    say $ctx "Protected modes on $chan: +$pos-$neg (use bitchmode for ops)."
}

proc ::guard::onoff {ctx flag label} {
    set chan [dict get $ctx chan]
    set a [string tolower [lindex [dict get $ctx args] 0]]
    if {$a ni {on off}} {
        say $ctx "$label on $chan: [expr {[channel get $chan $flag] ? "ON" : "OFF"}]"
        usage $ctx "\037on\037|\037off\037"
        return ""
    }
    channel set $chan [expr {$a eq "on" ? "+" : "-"}]$flag
    say $ctx "$label on $chan: [string toupper $a]"
    return $a
}

proc ::guard::cmd_bitchmode {ctx} {onoff $ctx bitchmode Bitchmode}

proc ::guard::cmd_topicsave {ctx} {
    set chan [dict get $ctx chan]
    set a [onoff $ctx topicsave "Topic lock"]
    if {$a eq "on" && [topic $chan] ne ""} {channel set $chan channel-topic [topic $chan]}
    if {$a eq "off"} {channel set $chan channel-topic ""}
}

proc ::guard::cmd_automode {ctx} {
    set chan [dict get $ctx chan]
    if {[dict get $ctx cmd] eq "autoop"} {
        set flag onjoin-operator; set other onjoin-voice
    } else {
        set flag onjoin-voice; set other onjoin-operator
    }
    set a [string tolower [lindex [dict get $ctx args] 0]]
    if {$a eq "on"} {
        channel set $chan +$flag -$other
    } elseif {$a eq "off"} {
        channel set $chan -$flag
    } else {
        say $ctx "[string totitle [dict get $ctx cmd]] on $chan: [expr {[channel get $chan $flag] ? "ON" : "OFF"}]"
        usage $ctx "\037on\037|\037off\037"
        return
    }
    say $ctx "[string totitle [dict get $ctx cmd]] on $chan: [string toupper $a]"
}

proc ::guard::cmd_maxmodes {ctx} {maxpair $ctx maximal-modes 12 modes}
proc ::guard::cmd_maxkicks {ctx} {maxpair $ctx maximal-kicks 5 kicks}
proc ::guard::maxpair {ctx setting limit what} {
    set chan [dict get $ctx chan]
    set a [lindex [dict get $ctx args] 0]
    if {![regexp {^(\d+):(\d+)$} $a -> n s] || $n < 1 || $n > $limit || $s < 1} {
        lassign [pair $chan $setting [expr {$what eq "modes" ? "6:30" : "3:10"}]] n s
        say $ctx "Maximum on $chan: $n $what in $s seconds."
        usage $ctx "\037$what:seconds\037 (max $limit $what)"
        return
    }
    channel set $chan $setting $a
    say $ctx "Maximum on $chan: $n $what in $s seconds."
}

proc ::guard::cmd_remflags {ctx} {
    set chan [dict get $ctx chan]
    set f [string tolower [lindex [dict get $ctx args] 0]]
    if {$f eq "none"} {
        channel set $chan remove-flags ""
        say $ctx "I won't remove service flags of abusers on $chan."
        return
    }
    set svc [service $chan]
    if {$f eq "" || ![regexp {[-+]} $f]} {
        set cur [channel get $chan remove-flags]
        if {$cur ne ""} {say $ctx "Flags removed from abusers on $chan: $cur"}
        usage $ctx "\037+-flags\037|\037none\037"
        return
    }
    if {$svc eq ""} {say $ctx "Q is not on $chan."; return}
    if {![regexp {^[-+amnotvbdq]+$} $f]} {say $ctx "Invalid Q flags: $f"; return}
    channel set $chan remove-flags $f
    say $ctx "Flags removed from abusers on $chan: $f"
    if {[string match *m* $f] || [string match *n* $f]} {
        say $ctx "For that the bot needs owner on $svc: /msg $svc CHANLEV $chan <botaccount> +n"
    } else {
        say $ctx "For that the bot needs master on $svc: /msg $svc CHANLEV $chan <botaccount> +amo"
    }
}

proc ::guard::cmd_showcommands {ctx} {
    variable required
    variable trigger
    set lvl [dict get $ctx level]
    set utrig [getuser [dict get $ctx hand] XTRA trigger]
    if {$utrig eq ""} {set utrig $trigger}
    say $ctx "[::web::b "Commands for level $lvl"] ([::web::fields [list [::web::lbl Level [lvl_name $lvl]] [::web::lbl Trigger $utrig]]])"
    foreach {cat title} {+ "help" % "general" & "protection (needs status on)" - "everyone"} {
        set list {}
        foreach cmd [lsort [dict keys $required]] {
            set r [dict get $required $cmd]
            if {[lindex $r 0] ne $cat} continue
            if {0 ni [lrange $r 1 end] && $lvl ni [lrange $r 1 end]} continue
            lappend list $cmd
        }
        if {[llength $list]} {say $ctx "[::web::lbl $title [join $list {, }]]"}
    }
}

# ---------------------------- user modes ----------------------------

proc ::guard::cmd_usermode {ctx} {
    set chan [dict get $ctx chan]
    set nick [dict get $ctx nick]
    set mode [dict get {op +o deop -o voice +v devoice -v} [dict get $ctx cmd]]
    set targets [dict get $ctx args]
    set lvl [dict get $ctx level]
    if {![llength $targets]} {set targets [list $nick]}
    if {$lvl in {3 4 7 8} && ([llength $targets] > 1 || ![string equal -nocase [lindex $targets 0] $nick])} {
        say $ctx "Your level can only [dict get $ctx cmd] yourself."
        return
    }
    foreach t $targets {
        foreach u [chanlist $chan] {
            if {[isbotnick $u]} continue
            set hit [expr {[string equal -nocase $t $u] ||
                ([is_mask $t] && ([wmatch $t "$u![getchanhost $u $chan]"] || [wmatch $t $u]))}]
            if {!$hit} continue
            set ul [level [nick2hand $u $chan] $chan]
            switch -- $mode {
                +o {if {[isop $u $chan] || $ul in {1 2}} continue}
                -o {if {![isop $u $chan] || ($ul in {4 5 6 8 9 10} && ![string equal -nocase $u $nick])} continue}
                +v {if {[isvoice $u $chan]} continue}
                -v {if {![isvoice $u $chan] || ($ul >= 3 && ![string equal -nocase $u $nick])} continue}
            }
            pushmode $chan $mode $u
        }
    }
    flushmode $chan
}

# ------------------------------- kick -------------------------------

proc ::guard::cmd_kick {ctx} {
    set chan [dict get $ctx chan]
    set nick [dict get $ctx nick]
    set lvl [dict get $ctx level]
    set a [dict get $ctx args]
    set t [lindex $a 0]
    if {$t eq ""} {usage $ctx "\037nickname\037|\037hostmask\037" "\037?reason?\037"; return}
    if {[is_mask $t] && $lvl in {4 8}} {say $ctx "Your level can't kick by hostmask."; return}
    set reason [join [lrange $a 1 end]]
    if {$reason eq ""} {set reason "You have been kicked from this channel."}
    set protect {4 {4 5 6 7 8 9 10} 5 {5 6 8 9 10} 8 {4 5 6 8 9 10} 9 {10}}
    set n 0
    foreach u [chanlist $chan] {
        if {[isbotnick $u] || [string equal -nocase $u $nick]} continue
        set hit [expr {[string equal -nocase $t $u] ||
            ([is_mask $t] && ([wmatch $t "$u![getchanhost $u $chan]"] || [wmatch $t $u]))}]
        if {!$hit} continue
        set ul [level [nick2hand $u $chan] $chan]
        if {[dict exists $protect $lvl] && $ul in [dict get $protect $lvl]} continue
        putkick $chan $u [kickmsg $chan $nick $reason]
        incr n
    }
    if {!$n} {say $ctx "Nobody to kick for \"$t\"."}
}

# -------------------------------- ban --------------------------------

# Turns "nick" / "#account" / "mask" into masks, then calls back
proc ::guard::resolve {target callback} {
    if {[string index $target 0] eq "#" && ![is_mask $target]} {
        {*}$callback [dict create found 1 oper 0 nick "" masks [list "*!*@[string range $target 1 end].users.quakenet.org"]]
    } elseif {[is_mask $target]} {
        if {![regexp {^.+!.+@.+$} $target]} {
            set target [expr {[string first @ $target] >= 0 ? "*!$target" : "$target!*@*"}]
        }
        {*}$callback [dict create found 1 oper 0 nick "" masks [list $target]]
    } else {
        lookup $target $callback
    }
}

proc ::guard::parse_duration {s} {
    # "%1h30m", "%2d", "%0" (permanent) -> minutes
    set s [string tolower [string trimleft $s %]]
    if {$s eq "0"} {return 0}
    set mins 0
    foreach {all n u} [regexp -all -inline {(\d+)([ywdhm])} $s] {
        incr mins [expr {$n * [dict get {y 525600 w 10080 d 1440 h 60 m 1} $u]}]
    }
    if {$mins == 0} {return ""}
    return $mins
}

proc ::guard::cmd_ban {ctx} {
    variable default_ban_mins
    set a [dict get $ctx args]
    set t [lindex $a 0]
    if {$t eq ""} {
        usage $ctx "\037nickname\037|\037#account\037|\037hostmask\037" "\037?-global?\037" "\037?%duration?\037" "\037?reason?\037"
        return
    }
    set rest [lrange $a 1 end]
    set global 0
    if {[string equal -nocase [lindex $rest 0] -global]} {set global 1; set rest [lrange $rest 1 end]}
    if {$global && [dict get $ctx level] ni {9 10}} {say $ctx "Only global masters can set global bans."; return}
    set mins $default_ban_mins
    if {[string index [lindex $rest 0] 0] eq "%"} {
        set mins [parse_duration [lindex $rest 0]]
        if {$mins eq ""} {say $ctx "Invalid duration [lindex $rest 0] (e.g. %1h30m, %2d, %0 = permanent)."; return}
        set rest [lrange $rest 1 end]
    }
    dict set ctx global $global
    dict set ctx mins $mins
    dict set ctx reason [join $rest]
    dict set ctx target $t
    resolve $t [list ::guard::ban_resolved $ctx]
}

proc ::guard::ban_resolved {ctx info} {
    set chan [dict get $ctx chan]
    set t [dict get $ctx target]
    if {![dict get $info found]} {say $ctx "$t is not online."; return}
    if {[dict get $info oper]} {say $ctx "You can't ban an IRC operator or service ($t)."; return}
    set masks [dict get $info masks]
    if {![llength $masks]} {say $ctx "I can't build a ban mask for $t."; return}
    foreach m $masks {
        if {[wmatch $m $::botname]} {say $ctx "$m would match me."; return}
        foreach h [userlist mno|mno $chan] {
            foreach uh [getuser $h hosts] {
                if {[string equal -nocase $uh $m] || [wmatch $m $uh]} {say $ctx "$m would match my user $h."; return}
            }
        }
    }
    set mins [dict get $ctx mins]
    set reason [dict get $ctx reason]
    if {$reason eq ""} {
        set reason [expr {$mins == 0 ? "You are permanently banned." : "You are banned for [::guard::dur [expr {$mins * 60}]]."}]
    }
    set msg [kickmsg $chan [dict get $ctx nick] $reason]
    foreach m $masks {
        if {[dict get $ctx global]} {
            newban $m [dict get $ctx hand] $msg $mins
        } else {
            newchanban $chan $m [dict get $ctx hand] $msg $mins
        }
    }
    # Kick right away if they're here
    set n [dict get $info nick]
    if {$n ne "" && [onchan $n $chan] && [botisop $chan]} {putkick $chan $n $msg}
    say $ctx "Ban [join $masks {, }] set [expr {[dict get $ctx global] ? "globally" : "on $chan"}] ([expr {$mins == 0 ? "permanent" : "expires in [dur [expr {$mins * 60}]]"}])."
}

proc ::guard::dur {secs} {
    if {[info commands ::duration] ne ""} {return [duration $secs]}
    return "${secs}s"
}

proc ::guard::cmd_unban {ctx} {
    set a [dict get $ctx args]
    set t [lindex $a 0]
    if {$t eq ""} {usage $ctx "\037all\037|\037nickname\037|\037hostmask\037|\037#number\037" "\037?-global?\037"; return}
    set global [string equal -nocase [lindex $a 1] -global]
    if {$global && [dict get $ctx level] ni {9 10}} {say $ctx "Only global masters can remove global bans."; return}
    dict set ctx global $global
    if {[string equal -nocase $t all] || [regexp {^#\d+$} $t] || [is_mask $t]} {
        unban_do $ctx [list $t]
    } else {
        lookup $t [list ::guard::unban_resolved $ctx]
    }
}

proc ::guard::unban_resolved {ctx info} {
    if {![dict get $info found]} {say $ctx "[dict get $info nick] is not online."; return}
    unban_do $ctx [dict get $info masks]
}

proc ::guard::unban_do {ctx targets} {
    set chan [dict get $ctx chan]
    set lvl [dict get $ctx level]
    set hand [dict get $ctx hand]
    set bans [expr {[dict get $ctx global] ? [banlist] : [banlist $chan]}]
    set n 0
    set i 0
    foreach b $bans {
        incr i
        lassign $b mask comment expire added active creator
        # Can't remove bans of users with more access (except owners)
        if {$lvl != 10 && ![string equal -nocase $creator $hand] && [level $creator $chan] >= $lvl} continue
        set hit 0
        foreach t $targets {
            if {[string equal -nocase $t all] || $t eq "#$i" || [wmatch $t $mask] || [wmatch $mask $t]} {set hit 1}
        }
        if {!$hit} continue
        if {[dict get $ctx global]} {killban $mask} else {killchanban $chan $mask}
        incr n
    }
    say $ctx "$n ban[expr {$n == 1 ? "" : "s"}] removed."
}

proc ::guard::cmd_banlist {ctx} {
    set chan [dict get $ctx chan]
    set global [string equal -nocase [lindex [dict get $ctx args] 0] -global]
    if {$global && [dict get $ctx level] ni {9 10}} {say $ctx "Only global masters can see the global banlist."; return}
    set bans [expr {$global ? [banlist] : [banlist $chan]}]
    set i 0
    foreach b $bans {
        incr i
        lassign $b mask comment expire added active creator
        set left [expr {$expire == 0 ? "permanent" : "expires in [dur [expr {max(0, $expire - [clock seconds])}]]"}]
        say $ctx "#$i $mask by $creator ($left) $comment"
    }
    say $ctx "End of [expr {$global ? "global" : $chan}] banlist ($i)."
}

# ---------------------------- user admin ----------------------------

proc ::guard::flags_for {lvl chan} {
    # returns {global-chattr channel-chattr}
    switch -- $lvl {
        10 {return {+amnov ""}}
        9  {return {-n+amov ""}}
        8  {return {-nm+aov ""}}
        7  {return {-nmo+av ""}}
        6  {return {"" |+amnov}}
        5  {return {"" |-n+amov}}
        4  {return {"" |-nm+aov}}
        3  {return {"" |-nmo+av}}
        2  {return {"" |-nmovaB+d}}
        1  {return {"" |-nmovad+B}}
    }
    return {"" ""}
}

proc ::guard::apply_level {hand lvl chan} {
    lassign [flags_for $lvl $chan] g c
    if {$g ne ""} {chattr $hand $g}
    if {$c ne ""} {chattr $hand $c $chan}
}

proc ::guard::cmd_adduser {ctx} {
    set may {10 {1 2 3 4 5 6 7 8 9 10} 9 {1 2 3 4 5 6 7 8} 6 {2 3 4 5 6} 5 {2 3 4}}
    set lvl [dict get $ctx level]
    lassign [dict get $ctx args] nick handle newlvl
    set allowed [expr {[dict exists $may $lvl] ? [dict get $may $lvl] : {}}]
    if {$newlvl eq "" || $newlvl ni $allowed || [string length $handle] > $::handlen || ![regexp {^[A-Za-z0-9_-]+$} $handle]} {
        usage $ctx "\037nickname\037" "\037handle\037 (max $::handlen chars)" "\037level\037 ([join $allowed {, }])"
        return
    }
    if {[validuser $handle]} {say $ctx "Handle $handle is already in use."; return}
    if {[isbotnick $nick]} {say $ctx "That's me."; return}
    dict set ctx handle $handle
    dict set ctx newlvl $newlvl
    lookup $nick [list ::guard::adduser_resolved $ctx]
}

proc ::guard::adduser_resolved {ctx info} {
    set chan [dict get $ctx chan]
    set nick [dict get $info nick]
    if {![dict get $info found] || ![llength [dict get $info masks]]} {say $ctx "$nick is not online."; return}
    set known [handles_for [dict get $info masks]]
    if {[llength $known]} {say $ctx "I already know $nick as [join $known {, }]."; return}
    set handle [dict get $ctx handle]
    set lvl [dict get $ctx newlvl]
    set masks [dict get $info masks]
    adduser $handle [lindex $masks 0]
    foreach m [lrange $masks 1 end] {setuser $handle HOSTS $m}
    apply_level $handle $lvl $chan
    if {[onchan $nick $chan] && [botisop $chan]} {
        switch -- $lvl {
            1 {foreach m $masks {newchanban $chan $m [dict get $ctx hand] [kickmsg $chan [dict get $ctx nick] "You are banned from this channel."] 0}}
            2 {pushmode $chan -o $nick}
            3 - 7 {pushmode $chan +v $nick}
            default {pushmode $chan +o $nick}
        }
    }
    say $ctx "$nick ([join $masks {, }]) added as $handle with level $lvl ([lvl_name $lvl])."
}

proc ::guard::cmd_access {ctx} {
    set a [dict get $ctx args]
    set t [lindex $a 0]
    if {$t eq ""} {usage $ctx "\037nickname\037|\037#handle\037" "\037?level|clear?\037" "\037?-global?\037"; return}
    if {[string index $t 0] eq "#"} {
        set h [string range $t 1 end]
        if {![validuser $h]} {say $ctx "Unknown handle $h."; return}
        access_do $ctx $h
    } else {
        lookup $t [list ::guard::access_resolved $ctx]
    }
}

proc ::guard::access_resolved {ctx info} {
    if {![dict get $info found]} {say $ctx "[dict get $info nick] is not online."; return}
    set hs [handles_for [dict get $info masks]]
    if {![llength $hs]} {say $ctx "I don't know [dict get $info nick]."; return}
    access_do $ctx [lindex $hs 0]
}

proc ::guard::access_do {ctx h} {
    set chan [dict get $ctx chan]
    set a [dict get $ctx args]
    set mine [dict get $ctx level]
    set what [string tolower [lindex $a 1]]
    set global [string equal -nocase [lindex $a end] -global]
    set theirs [level $h $chan]
    if {$what eq "" || $what eq "-global"} {
        say $ctx "$h has level $theirs ([lvl_name $theirs]) on $chan."
        return
    }
    if {$what eq "clear"} {
        if {$mine != 10 && $theirs >= $mine} {say $ctx "$h has equal or more access than you."; return}
        if {$global} {chattr $h -amnov} else {chattr $h |-amnovdB $chan}
        say $ctx "Access of $h cleared[expr {$global ? " (global)" : " on $chan"}]."
        return
    }
    if {![string is integer -strict $what] || $what < 1 || $what > 10} {say $ctx "Level must be 1-10 or clear."; return}
    if {$mine != 10 && ($what >= $mine || $theirs >= $mine)} {say $ctx "You can't set that level."; return}
    apply_level $h $what $chan
    say $ctx "$h now has level $what ([lvl_name $what])."
}

proc ::guard::cmd_deluser {ctx} {
    set t [lindex [dict get $ctx args] 0]
    if {$t eq ""} {usage $ctx "\037nickname\037|\037#handle\037"; return}
    if {[string index $t 0] eq "#"} {
        set h [string range $t 1 end]
        if {![validuser $h]} {say $ctx "Unknown handle $h."; return}
        if {[string equal -nocase $h [dict get $ctx hand]]} {say $ctx "You can't delete yourself."; return}
        deluser $h
        say $ctx "$h deleted."
        return
    }
    lookup $t [list ::guard::deluser_resolved $ctx]
}

proc ::guard::deluser_resolved {ctx info} {
    if {![dict get $info found]} {say $ctx "[dict get $info nick] is not online."; return}
    set hs [handles_for [dict get $info masks] [dict get $ctx hand]]
    if {![llength $hs]} {say $ctx "I don't know [dict get $info nick]."; return}
    foreach h $hs {deluser $h}
    say $ctx "Deleted: [join $hs {, }]"
}

proc ::guard::cmd_whois {ctx} {
    set t [lindex [dict get $ctx args] 0]
    if {$t eq ""} {usage $ctx "\037nickname\037|\037#handle\037"; return}
    if {[string index $t 0] eq "#"} {
        set h [string range $t 1 end]
        if {![validuser $h]} {say $ctx "Unknown handle $h."; return}
        whois_show $ctx $h
        return
    }
    lookup $t [list ::guard::whois_resolved $ctx]
}

proc ::guard::whois_resolved {ctx info} {
    if {![dict get $info found]} {say $ctx "[dict get $info nick] is not online."; return}
    set hs [handles_for [dict get $info masks]]
    set acc [dict get $info account]
    if {![llength $hs]} {
        say $ctx "[dict get $info nick] is not a bot user[expr {$acc ne "" ? " (Q account $acc)" : ""}]."
        return
    }
    whois_show $ctx [lindex $hs 0]
}

proc ::guard::whois_show {ctx h} {
    set nicks {}
    foreach chan [channels] {
        foreach n [chanlist $chan] {
            if {[nick2hand $n $chan] eq $h && $n ni $nicks} {lappend nicks $n}
        }
    }
    say $ctx "[::web::b $h] ([::web::lbl "Online as" [expr {[llength $nicks] ? [join $nicks {, }] : "nobody"}]])"
    say $ctx [::web::lbl Hosts [join [getuser $h HOSTS] {, }]]
    set g 0
    foreach {l f} {7 v 8 o 9 m 10 n} {if {[matchattr $h $f]} {set g $l}}
    if {$g} {say $ctx "Global level $g ([lvl_name $g])"}
    foreach chan [channels] {
        set l [level $h $chan]
        if {$l > 0 && $l < 7} {say $ctx "Level $l ([lvl_name $l]) on $chan"}
    }
}

proc ::guard::cmd_userlist {ctx} {
    set chan [dict get $ctx chan]
    set global [string equal -nocase [lindex [dict get $ctx args] 0] -global]
    if {$global && [dict get $ctx level] ni {9 10}} {say $ctx "Only global masters can see the global userlist."; return}
    set by {}
    foreach h [userlist] {
        set l [level $h $chan]
        if {$l == 0 || ($global && $l < 7) || (!$global && $l >= 7)} continue
        set on {}
        foreach n [chanlist $chan] {if {[nick2hand $n $chan] eq $h} {lappend on $n}}
        dict lappend by $l "$h[expr {[llength $on] ? " ([join $on {, }])" : ""}]"
    }
    say $ctx "Userlist: [expr {$global ? "global" : $chan}]"
    set total 0
    foreach l [lsort -integer -decreasing [dict keys $by]] {
        set users [dict get $by $l]
        incr total [llength $users]
        for {set i 0} {$i < [llength $users]} {incr i 6} {
            say $ctx "{$l} [lvl_name $l]: [join [lrange $users $i [expr {$i + 5}]] {, }]"
        }
    }
    say $ctx "End of list, $total user[expr {$total == 1 ? "" : "s"}]."
}

# ============================== PROTECTION ==============================

# Who may change modes/topic/kick without being treated as an abuser
proc ::guard::trusted {nick uhost hand chan} {
    variable trusted_levels
    if {$nick eq "" || [string first . $nick] >= 0 || [isbotnick $nick]} {return 1}
    if {[is_service $nick $uhost]} {return 1}
    if {[validuser $hand] && ([matchattr $hand b] || [islinked $hand])} {return 1}
    expr {[level $hand $chan] in $trusted_levels}
}

proc ::guard::react {chan event} {
    variable lastreact
    set svc [service $chan]
    if {$svc eq ""} return
    set now [clock seconds]
    if {[info exists lastreact($chan)] && $now - $lastreact($chan) < 2} return
    set lastreact($chan) $now
    foreach a [split [channel get $chan reaction-$event] :] {
        switch -- $a {
            reop      {if {![botisop $chan]} {putquick "PRIVMSG $svc :OP $chan" -next}}
            invite    {if {![botonchan $chan]} {putquick "PRIVMSG $svc :INVITE $chan" -next}}
            unbanall  {putquick "PRIVMSG $svc :BANCLEAR $chan" -next}
            deopall   {putquick "PRIVMSG $svc :DEOPALL $chan" -next}
            recover   {putquick "PRIVMSG $svc :RECOVER $chan" -next}
            clearchan {putquick "PRIVMSG $svc :CLEARCHAN $chan" -next}
        }
    }
    putlog "guard: $event on $chan -> [channel get $chan reaction-$event] via $svc"
}

# Punishment is queued for a second so a burst of modes counts once
proc ::guard::offence {nick uhost chan reason} {
    variable pending
    set k "[string tolower $chan],[string tolower $nick]"
    if {[info exists pending($k)]} return
    set pending($k) 1
    utimer 1 [list ::guard::punish $nick $uhost $chan $reason]
}

proc ::guard::punish {nick uhost chan reason} {
    variable pending
    variable punish_ban_mins
    unset -nocomplain pending([string tolower $chan],[string tolower $nick])
    if {![validchan $chan] || ![botisop $chan]} return
    set svc [service $chan]
    set rf [channel get $chan remove-flags]
    if {$rf ne "" && $svc ne ""} {putquick "PRIVMSG $svc :CHANLEV $chan $nick $rf" -next}
    set m [channel get $chan punish-methode]
    set msg [kickmsg $chan $::botnick $reason]
    if {[onchan $nick $chan] && [isop $nick $chan]} {pushmode $chan -o $nick}
    if {$m >= 2 && [onchan $nick $chan]} {
        if {$m == 3} {newchanban $chan [banmask $nick $uhost] guard $msg $punish_ban_mins}
        putkick $chan $nick $msg
    }
    flushmode $chan
    putlog "guard: punished $nick on $chan ($reason, method $m)"
}

bind mode - * ::guard::on_mode
proc ::guard::on_mode {nick uhost hand chan mode victim} {
    variable reveal_delayed
    if {![channel get $chan protection]} return
    # Q banned the bot: remove its ban
    if {$mode eq "+b" && [is_service $nick $uhost] && [wmatch $victim $::botname]} {
        putquick "PRIVMSG $nick :BANDEL $chan $victim" -next
        if {[botisop $chan]} {pushmode $chan -b $victim}
        return
    }
    if {$mode eq "-D" && [isbotnick $nick] && $reveal_delayed} {
        putserv "NAMES -d $chan"
        return
    }
    if {[trusted $nick $uhost $hand $chan]} return
    set sign [string index $mode 0]
    set m [string index $mode 1]
    lassign [channel get $chan protected-modes] pos neg
    set vlvl [expr {$victim ne "" && [onchan $victim $chan] ? [level [nick2hand $victim $chan] $chan] : 0}]

    # Mass deop counter
    if {$mode eq "-o"} {
        lassign [pair $chan maximal-modes 6:30] max secs
        if {[count "md,[string tolower $chan]" $secs] >= $max} {react $chan mass-mode}
    }
    set offence ""
    switch -- $mode {
        -o {
            if {[isbotnick $victim]} {
                react $chan need-op
                set offence "deopped me"
            } elseif {$vlvl in {4 5 6 8 9 10} && ![string equal -nocase $victim $nick]} {
                pushmode $chan +o $victim
                set offence "deopped a protected user"
            }
        }
        +o {
            if {[channel get $chan bitchmode] && $vlvl ni {4 5 6 8 9 10} && ![isbotnick $victim]} {
                pushmode $chan -o $victim
                set offence "bitchmode"
            }
        }
        -v {
            if {$vlvl >= 3 && [string first v $neg] >= 0 && ![string equal -nocase $victim $nick]} {
                pushmode $chan +v $victim
                set offence "devoiced a protected user"
            }
        }
        +b {
            set protected 0
            if {[wmatch $victim $::botname]} {set protected 1}
            foreach u [chanlist $chan] {
                if {[level [nick2hand $u $chan] $chan] >= 3 && [wmatch $victim "$u![getchanhost $u $chan]"]} {set protected 1}
            }
            if {$protected || [string first b $pos] >= 0 && ![wmatch $victim "$nick!$uhost"]} {
                pushmode $chan -b $victim
                set offence "banned a protected user"
            }
        }
        -b {
            if {[isban $victim $chan] || [isban $victim]} {
                pushmode $chan +b $victim
                set offence "removed a ban of mine"
            }
        }
        default {
            # Other channel modes: restore the protected ones
            if {$m in {o v b}} return
            if {$sign eq "+" && [string first $m $pos] >= 0} {
                pushmode $chan -$m [expr {$m eq "k" ? $victim : ""}]
                set offence "set +$m"
            } elseif {$sign eq "-" && [string first $m $neg] >= 0 && $m ni {k l}} {
                pushmode $chan +$m
                set offence "removed +$m"
            }
        }
    }
    if {$offence ne ""} {offence $nick $uhost $chan "Don't abuse your operator privileges ($offence)"}
}

# After the bot removes +D, voice and devoice users that were hidden
bind raw - 355 ::guard::raw355
proc ::guard::raw355 {from key text} {
    # :server 355 me = #chan :nick1 nick2 ...
    set parts [split [string trim $text] " "]
    set chan [lindex $parts 2]
    if {![validchan $chan] || ![botisop $chan]} {return 0}
    set nicks [string trimleft [join [lrange $parts 3 end]] :]
    foreach n [split $nicks] {
        set n [string trimleft $n "@+"]
        if {$n eq "" || [isbotnick $n]} continue
        putserv "MODE $chan +v $n"
        if {![channel get $chan onjoin-voice]} {utimer 2 [list putserv "MODE $chan -v $n"]}
    }
    return 0
}

bind topc - * ::guard::on_topic
proc ::guard::on_topic {nick uhost hand chan topic} {
    if {![channel get $chan protection] || ![channel get $chan topicsave]} return
    set saved [channel get $chan channel-topic]
    if {$topic eq $saved} return
    if {[trusted $nick $uhost $hand $chan]} {
        if {$topic ne ""} {channel set $chan channel-topic $topic}
        return
    }
    set_topic $chan $saved
    offence $nick $uhost $chan "Don't change the topic"
}

bind kick - * ::guard::on_kick
proc ::guard::on_kick {nick uhost hand chan victim reason} {
    variable punish_all_kicks
    if {[isbotnick $nick]} {
        set id [channel get $chan kick-id]
        channel set $chan kick-id [expr {([string is integer -strict $id] ? $id : 0) + 1}]
        return
    }
    if {![channel get $chan protection] || [trusted $nick $uhost $hand $chan] || [string equal -nocase $victim $nick]} return
    if {[isbotnick $victim]} {react $chan bot-kick}
    lassign [pair $chan maximal-kicks 3:10] max secs
    if {[count "mk,[string tolower $chan]" $secs] >= $max} {react $chan mass-kick}
    set vh [nick2hand $victim $chan]
    if {[validuser $vh] && [matchattr $vh mno|mno $chan] && [botisop $chan]} {putserv "INVITE $victim $chan"}
    if {$punish_all_kicks || [level $vh $chan] >= 3} {
        offence $nick $uhost $chan "Don't abuse your operator privileges (kick)"
    }
}

bind need - * ::guard::on_need
proc ::guard::on_need {chan type} {
    if {![validchan $chan] || ![channel get $chan protection]} return
    set svc [service $chan]
    if {$type eq "op"} {
        if {$svc ne ""} {putquick "PRIVMSG $svc :OP $chan" -next}
        return
    }
    if {$type eq "limit"} {set type invite}
    react $chan need-$type
}

# ============================ JOIN / SERVICES ============================

bind join - * ::guard::on_join
proc ::guard::on_join {nick uhost hand chan} {
    variable reop
    variable autoop_off
    variable join_flood
    if {[isbotnick $nick] || ![channel get $chan protection]} return
    set c [string tolower $chan]
    # The service came back: restore what we changed when it left
    if {[is_service $nick $uhost]} {
        if {[info exists reop($c)] && [botisop $chan]} {
            foreach n $reop($c) {if {[onchan $n $chan]} {pushmode $chan +o $n}}
            flushmode $chan
        }
        unset -nocomplain reop($c)
        if {[info exists autoop_off($c)]} {
            channel set $chan +onjoin-operator -onjoin-voice
            unset autoop_off($c)
        }
        return
    }
    if {![botisop $chan]} return
    set lvl [level $hand $chan]
    if {$lvl == 1} {
        newchanban $chan [banmask $nick $uhost] guard [kickmsg $chan $::botnick "You are banned from this channel."] 0
        putkick $chan $nick [kickmsg $chan $::botnick "You are banned from this channel."]
        return
    }
    if {[channel get $chan onjoin-operator] && $lvl != 2} {
        if {[count "j,$c" 1] >= $join_flood} {
            channel set $chan -onjoin-operator
            timer 1 [list channel set $chan +onjoin-operator]
            putlog "guard: join flood on $chan, autoop suspended for a minute"
            return
        }
        utimer 2 [list ::guard::delayed_op $chan $nick]
    } elseif {[channel get $chan onjoin-voice]} {
        pushmode $chan +v $nick
    }
}

proc ::guard::delayed_op {chan nick} {
    if {[validchan $chan] && [botisop $chan] && [onchan $nick $chan] && ![isop $nick $chan]} {
        pushmode $chan +o $nick
    }
}

bind part - * ::guard::on_part
bind sign - * ::guard::on_part
proc ::guard::on_part {nick uhost hand chan {reason ""}} {
    if {[is_service $nick $uhost]} {service_left $chan}
}

bind splt - * ::guard::on_split
proc ::guard::on_split {nick uhost hand chan} {
    if {[is_service $nick $uhost]} {service_left $chan}
}

# Q is gone: no autoop for strangers, and unknown ops are removed
proc ::guard::service_left {chan} {
    variable reop
    variable autoop_off
    if {![channel get $chan protection]} return
    set c [string tolower $chan]
    if {[channel get $chan onjoin-operator]} {
        channel set $chan -onjoin-operator +onjoin-voice
        set autoop_off($c) 1
    }
    if {[channel get $chan service-prot] && [botisop $chan]} {
        set reop($c) {}
        foreach n [chanlist $chan] {
            if {[isbotnick $n] || ![isop $n $chan]} continue
            set h [nick2hand $n $chan]
            if {[validuser $h] && [matchattr $h mno|mno $chan]} continue
            lappend reop($c) $n
            pushmode $chan -o $n
        }
        flushmode $chan
    }
    putlog "guard: service left $chan, autoop suspended"
}

# ============================== AUTOLIMIT ==============================

bind time - "* * * * *" ::guard::autolimit
proc ::guard::autolimit {args} {
    foreach chan [channels] {autolimit_chan $chan}
}

proc ::guard::autolimit_chan {chan} {
    set step [channel get $chan autolimit]
    if {![string is integer -strict $step] || $step < 1 || ![botisop $chan]} return
    set want [expr {[llength [chanlist $chan]] + $step}]
    # The limit is the argument of 'l', after the key if both are set
    set m [getchanmode $chan]
    set cur 0
    set i 1
    foreach ch [split [lindex $m 0] ""] {
        switch -- $ch {
            k {incr i}
            l {set cur [lindex $m $i]; incr i}
        }
    }
    set diff [expr {abs($want - $cur)}]
    if {$cur == $want} return
    if {$cur > 0 && (($step > 5 && $diff <= round($step * 0.5)) || ($step <= 5 && $diff < round($step * 0.38)))} return
    pushmode $chan +l $want
}

putlog "guard.tcl v$::guard::version loaded"
