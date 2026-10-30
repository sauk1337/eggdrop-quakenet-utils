# =====================================================================
#  help.tcl  v1.2.0  -  What scripts are loaded and which commands you can use
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Builds the answer from the scripts that are really loaded, the
#    channel settings that enable them, and the flags of whoever asks,
#    so nobody sees commands they can't use. Answers go by NOTICE through
#    the slow help queue, are capped at a few lines and throttled, so
#    they never lag the bot or the channel.
#    Load it last, after every other script.
#
#  REQUIREMENTS
#    web.tcl loaded before (output style)
#
#  COMMANDS (channel)
#    !commands | !help          the commands YOU can use here (by notice)
#    !help <script>             what a script does and its commands
#    !help <!command>           syntax of one command, e.g. !help !remind
#    !scripts                   loaded scripts and whether they're on here
#    !scripts <name>            same as !help <script>
#  COMMANDS (private)
#    /msg <bot> help [script]   same, without a channel
#  PARTYLINE
#    .scripts                   every loaded script and the channels using it
#    .guide                     the full guide (quick start + every command)
# =====================================================================

namespace eval ::help {
    # ------------------------- CONFIGURATION -------------------------
    variable throttle 10             ;# seconds between help requests per user
    variable max_lines 4             ;# lines per answer

    # name namespace {channel flags (any enables it; "" = always on)} description
    #   commands: {syntax who description}   who: - everyone, o ops, m masters
    variable catalog {
        antiproxy ::antiproxy {antiproxy antiproxy-gate} "Proxy/VPN/Tor check on join; +i gate with invites" {
            {"/msg $bot enter #chan" - "get invited after an IP check (gate channels)"}
            {"!pcheck <ip|nick>" o "check an IP by hand"}
        }
        ipinfo ::ipinfo {ipinfo} "Full IP lookup: location, network, abuse contact, proxy/VPN/Tor verdict" {
            {"!ip <ip|host>" - "IP information"}
            {"!ip <nick>" o "look up a user's IP (answer by notice)"}
        }
        utils ::utils {utils} "Weather, time, currency, crypto, countries, DNS, calculator, quotes" {
            {"!weather|!w <city>" - "current weather"}
            {"!forecast <city>" - "4-day forecast"}
            {"!time <city>" - "local time"}
            {"!convert <n> <FROM> <TO>" - "currency conversion"}
            {"!crypto <coin> [cur]" - "crypto price"}
            {"!country <name>" - "country facts"}
            {"!dns <host> [type]" - "DNS records"}
            {"!calc <expr>" - "calculator"}
            {"!quote [n|add|search]" - "channel quotes"}
            {"!quote del <n>" o "delete a quote"}
        }
        youtube ::youtube {youtube} "YouTube link info and search" {
            {"!yt <search|link>" - "video details (search needs an API key)"}
        }
        urltitle ::urltitle {urltitle} "Shows the title of pasted links" {}
        chanstats ::chanstats {chanstats} "Channel statistics and web page" {
            {"!stats [nick]" - "your stats"}
            {"!top [type]" - "rankings"}
            {"!hours | !today | !words" - "activity and words"}
            {"!chanstats" - "channel totals"}
        }
        reminders ::reminders {reminders} "Reminders and alarms" {
            {"!remind <when> <text>" - "remind me (10m, 18:30, tomorrow 9:00...)"}
            {"!remind <nick> <when> <text>" - "remind someone"}
            {"!remind every <interval> <text>" - "recurring"}
            {"!at <time> <text>" - "alarm"}
            {"!reminders | !remind del <id>" - "list / delete"}
            {"!remind tz <Area/City> | !snooze" - "timezone / snooze"}
        }
        feeds ::feeds {feeds} "RSS/Atom feeds (GitHub, YouTube, Reddit, Mastodon...)" {
            {"!feed list | latest <name>" - "subscriptions / latest items"}
            {"!feed test <url>" - "preview a feed"}
            {"!feed add|del|pause|filter ..." o "manage feeds"}
        }
        github ::github {github} "GitHub profiles tracker and lookups" {
            {"!gh <user>" - "GitHub profile"}
            {"!gh repo <owner/repo|user>" - "repository details / latest repositories"}
            {"!gh list" - "tracked profiles on this channel"}
            {"!gh add|del <user>" o "track / stop tracking a profile"}
            {"!gh filter <user> <types>" o "events to announce"}
            {"!gh check" o "check the tracked profiles now (says if nothing is new)"}
        }
        wiki ::wiki {wiki} "Wikipedia summaries and on this day" {
            {"!wiki [lang:] <query>" - "article summary"}
            {"!wikisearch | !wikirandom" - "search / random article"}
            {"!otd" - "on this day"}
        }
        dictionary ::dictionary {dict ud} "Dictionary, synonyms, Urban Dictionary, word of the day" {
            {"!define [lang:]<word>" - "definitions"}
            {"!synonyms | !antonyms | !rhymes <word>" - "related words"}
            {"!ud <term> [n]" - "Urban Dictionary (if enabled)"}
            {"!wotd" - "word of the day"}
        }
        countdown ::countdown {countdown} "Event countdowns with announcements" {
            {"!cd [name]" - "upcoming events / details"}
            {"!cd add|del|edit|alerts ..." o "manage events"}
        }
        ask ::ask {ask} "AI answers" {
            {"!ask <question>" - "ask the AI (!ai)"}
            {"!ask reset" - "new conversation"}
        }
        tools ::tools {} "Channel commands and !seen" {
            {"!seen <nick>" - "last time someone was seen"}
            {"!op|!deop|!voice|!devoice [nicks]" o "modes"}
            {"!kick|!kb <nick> [reason]" o "kick / kickban"}
            {"!ban|!unban <mask>" o "bans"}
            {"!topic <text>" o "set the topic"}
        }
        guard ::guard {protection} "Channel protection with Q and access levels" {
            {"!showcommands" o "guard's commands for your access level"}
        }
        qauth ::qauth {} "Authenticates the bot with Q (no commands)" {}
    }

    # The guide shown by .guide (partyline) and at the top of the
    # single-file build. Plain ASCII, 72 columns.
    variable guide {
+----------------------------------------------------------------------+
|                    eggdrop-quakenet-utils  v1.2.1                    |
|        Utility bot for QuakeNet - Eggdrop 1.9/1.10 - Tcl 8.6         |
+----------------------------------------------------------------------+

 QUICK START
   1. secrets.tcl  ->  Q account, password and optional API keys
   2. .+chan #chan
   3. .chanset #chan +antiproxy +ipinfo +utils +youtube +urltitle
      .chanset #chan +chanstats +reminders +feeds +github +wiki
      .chanset #chan +dict +countdown +ask
   4. .save   and on IRC:  !commands

 ON IRC (everyone)                      answers by notice where noted
   !commands  !help <script|!cmd>       what YOU can use here (notice)
   !scripts [name]                      loaded scripts, on/off here
   !ip <ip|host>                        location, network, abuse, proxy
   !weather !forecast !time <city>      weather and local time
   !convert <n> <FROM> <TO>  !crypto    currencies and crypto
   !country !dns !calc !quote           facts, DNS, maths, quotes
   !yt <search|link>                    YouTube (links are automatic)
   !stats !top !hours !today !words     channel statistics
   !remind <when> <text>  !at  !snooze  reminders and alarms
   !feed list|latest <name>             RSS/Atom feeds
   !gh <user>  !gh repo <owner/repo>    GitHub profiles and repos
   !wiki [lang:]<query>  !otd           Wikipedia, on this day
   !define !synonyms !rhymes !ud !wotd  dictionary
   !cd [name]                           countdowns
   !ask <question>                      AI answers
   !seen <nick>                         last time someone was seen
   /msg <bot> enter #chan               invite after an IP check (+i)

 ON IRC (channel ops)
   !op !deop !voice !devoice !kick !kb !ban !unban !topic
   !pcheck <ip|nick>   !ip <nick>       proxy check, IP of a user
   !feed add|del|pause|filter ...       manage feeds
   !gh add|del|filter|check ...         manage tracked GitHub profiles
   !cd add|del|edit|alerts ...          manage countdowns
   !quote del <n>

 PARTYLINE
   .guide                    this guide
   .scripts                  loaded scripts and where they're on
   .pcheck .pwhite .pcache .pstats      antiproxy
   .qauth  .reminders  .github  .askstats  .askreset

 ANTIPROXY IN ONE LINE
   Each method adds points; at 3 the user is kickbanned (or warned).
   BNC with a hostname: 2, allowed.  Bare VPS IP: 3, banned.
   Real proxy / Tor / DNSBL: 3+, banned.  Q-authed users: always in.

 MORE:  !help <script>  -  the header of every .tcl  -  README.md
+----------------------------------------------------------------------+
}

    # --------------------- STATE (do not touch) ---------------------
    variable last
}

proc ::help::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

# Loaded scripts: list of {name ns flags desc cmds}
proc ::help::loaded {} {
    variable catalog
    set out {}
    foreach {name ns flags desc cmds} $catalog {
        if {[namespace exists $ns]} {lappend out [list $name $ns $flags $desc $cmds]}
    }
    return $out
}

proc ::help::enabled {flags chan} {
    if {![llength $flags]} {return 1}
    if {$chan eq "" || ![validchan $chan]} {return 1}
    foreach f $flags {
        if {![catch {channel get $chan $f} v] && $v eq "1"} {return 1}
    }
    return 0
}

proc ::help::allowed {who hand chan} {
    switch -- $who {
        -       {return 1}
        o       {return [expr {$chan ne "" ? [matchattr $hand o|o $chan] : [matchattr $hand o]}]}
        m       {return [expr {$chan ne "" ? [matchattr $hand m|m $chan] : [matchattr $hand m]}]}
    }
    return 0
}

proc ::help::syntax {s} {
    string map [list {$bot} $::botnick] $s
}

proc ::help::note {nick text} {
    puthelp "NOTICE $nick :$text"
}

# Sends at most max_lines notices, packing items up to ~380 bytes per line
proc ::help::send {nick items} {
    variable max_lines
    set sep [::web::sep]
    set lines {}
    set cur ""
    foreach it $items {
        if {$cur ne "" && [string length "$cur$sep$it"] > 380} {
            lappend lines $cur
            set cur $it
        } elseif {$cur eq ""} {
            set cur $it
        } else {
            append cur $sep$it
        }
    }
    if {$cur ne ""} {lappend lines $cur}
    if {[llength $lines] > $max_lines} {
        set lines [lrange $lines 0 [expr {$max_lines - 1}]]
        lset lines end "[lindex $lines end] ..."
    }
    foreach l $lines {note $nick $l}
}

# "!remind <when> <text>" -> bold command, plain arguments
proc ::help::pretty {syn} {
    set syn [syntax $syn]
    set i [string first " " $syn]
    if {[string match /msg* $syn]} {
        # "/msg Bot enter #chan": the whole command is what you type
        set parts [split $syn]
        return "[::web::b [join [lrange $parts 0 2]]] [join [lrange $parts 3 end]]"
    }
    if {$i < 0} {return [::web::b $syn]}
    return "[::web::b [string range $syn 0 [expr {$i - 1}]]][string range $syn $i end]"
}

# ------------------------------ ANSWERS ------------------------------

proc ::help::commands {nick hand chan} {
    set items {}
    foreach s [loaded] {
        lassign $s name ns flags desc cmds
        if {![enabled $flags $chan]} continue
        set mine {}
        foreach c $cmds {
            lassign $c syn who
            if {![allowed $who $hand $chan]} continue
            set syn [syntax $syn]
            if {[string match /msg* $syn]} {
                # "/msg Bot enter #chan" stays whole
                set found [list [join [lrange [split $syn] 0 2]]]
            } else {
                # every !command in the line: "!op|!deop [nicks]" -> !op !deop
                set found [regexp -all -inline {![a-z]+} $syn]
            }
            foreach f $found {if {$f ni $mine} {lappend mine $f}}
        }
        if {[llength $mine]} {
            set bold {}
            foreach m $mine {lappend bold [::web::b $m]}
            lappend items [::web::lbl $name [join $bold " "]]
        }
    }
    if {![llength $items]} {
        note $nick [::web::msg Help "No commands available for you[expr {$chan ne "" ? " on $chan" : ""}]."]
        return
    }
    note $nick [::web::msg Help "Commands you can use[expr {$chan ne "" ? " on $chan" : ""}]"]
    send $nick $items
    note $nick [::web::msg Help "[::web::b {!help <script>}] explains a script, [::web::b {!help <!command>}] a command (e.g. !help [lindex [lindex [loaded] 0] 0])"]
}

proc ::help::scripts {nick chan} {
    set items {}
    foreach s [loaded] {
        lassign $s name ns flags
        if {$chan eq "" || ![llength $flags]} {
            lappend items [::web::b $name]
        } elseif {[enabled $flags $chan]} {
            lappend items "[::web::b $name] \00303on\003"
        } else {
            lappend items [::web::dim "$name off"]
        }
    }
    note $nick [::web::msg Help "[llength $items] scripts loaded[expr {$chan ne "" ? " on $chan" : ""}]"]
    send $nick $items
    note $nick [::web::msg Help "[::web::b {!scripts <name>}] for details, [::web::b !commands] for the commands you can use"]
}

proc ::help::script {nick hand chan name} {
    if {[string index $name 0] eq "!"} {
        command $nick $hand $chan $name
        return
    }
    set s ""
    foreach x [loaded] {if {[string equal -nocase [lindex $x 0] $name]} {set s $x}}
    if {$s eq ""} {
        note $nick [::web::msg Help "No script called \"$name\" is loaded (see !scripts)."]
        return
    }
    lassign $s name ns flags desc cmds
    set state ""
    if {[llength $flags] && $chan ne ""} {
        set state [expr {[enabled $flags $chan] ? "on here" : "off here: .chanset $chan +[lindex $flags 0]"}]
    }
    note $nick [::web::line Help $name [list $desc [expr {$state ne "" ? [::web::lbl Status $state] : ""}]]]
    set items {}
    foreach c $cmds {
        lassign $c syn who what
        if {[allowed $who $hand $chan]} {lappend items "[pretty $syn] [::web::dim $what]"}
    }
    if {[llength $items]} {
        send $nick $items
    } elseif {[llength $cmds]} {
        note $nick [::web::msg Help "You can't use its commands here."]
    }
}

# !help !remind -> every catalog line that mentions that command
proc ::help::command {nick hand chan cmd} {
    set cmd [string tolower $cmd]
    set items {}
    set script ""
    foreach s [loaded] {
        lassign $s name ns flags desc cmds
        foreach c $cmds {
            lassign $c syn who what
            set found [regexp -all -inline {![a-z]+} [string tolower $syn]]
            if {$cmd ni $found} continue
            if {$script eq ""} {set script $name}
            set line "[pretty $syn] [::web::dim $what]"
            if {![allowed $who $hand $chan]} {append line " [::web::dim (ops)]"}
            lappend items $line
        }
    }
    if {![llength $items]} {
        note $nick [::web::msg Help "Unknown command $cmd (see !commands)."]
        return
    }
    note $nick [::web::line Help $cmd [list [::web::lbl Script $script]]]
    send $nick $items
}

# ----------------------------- COMMANDS -----------------------------

bind pub - !commands ::help::pub_commands
bind pub - !help ::help::pub_commands
bind pub - !comandos ::help::pub_commands
bind pub - !ayuda ::help::pub_commands
proc ::help::pub_commands {nick uhost hand chan text} {
    if {[flood $uhost]} {return 0}
    if {[string trim $text] ne ""} {
        script $nick $hand $chan [lindex [split [string trim $text]] 0]
    } else {
        commands $nick $hand $chan
    }
    return 1
}

bind pub - !scripts ::help::pub_scripts
proc ::help::pub_scripts {nick uhost hand chan text} {
    if {[flood $uhost]} {return 0}
    set name [lindex [split [string trim $text]] 0]
    if {$name eq ""} {scripts $nick $chan} else {script $nick $hand $chan $name}
    return 1
}

bind msg - help ::help::msg_help
proc ::help::msg_help {nick uhost hand text} {
    if {[flood $uhost]} {return 0}
    set name [lindex [split [string trim $text]] 0]
    if {$name eq ""} {
        scripts $nick ""
        commands $nick $hand ""
    } else {
        script $nick $hand "" $name
    }
    return 1
}

bind dcc - scripts ::help::dcc_scripts
proc ::help::dcc_scripts {hand idx text} {
    foreach s [loaded] {
        lassign $s name ns flags desc
        set on {}
        foreach chan [channels] {if {[llength $flags] && [enabled $flags $chan]} {lappend on $chan}}
        putdcc $idx [format "%-11s %-9s %s" $name [expr {![llength $flags] ? "always" : [llength $on] ? [join $on ,] : "off"}] $desc]
    }
    return 1
}

bind dcc - guide ::help::dcc_guide
proc ::help::dcc_guide {hand idx text} {
    variable guide
    foreach l [split [string trim $guide \n] \n] {putdcc $idx $l}
    return 1
}

putlog "help.tcl loaded ([llength [::help::loaded]] scripts registered)"
