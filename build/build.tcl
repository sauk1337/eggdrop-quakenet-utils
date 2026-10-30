# Builds the single-file version of every script:
#   tclsh build/build.tcl   ->   dist/eggdrop-quakenet-utils.tcl
#
# The scripts in scripts/ stay the source of truth. This joins them in
# load order, with the guide from help.tcl and a table of contents on
# top, so a bot can load everything with one "source" line.
# guard.tcl is not included: it is optional and has its own license.
encoding system utf-8
set root [file dirname [file dirname [file normalize [info script]]]]
set src [file join $root scripts]

# Load order: libraries first, help.tcl last (it lists what is loaded)
set modules {
    web       "Shared HTTP, JSON, text and output style (library)"
    timeutil  "Date and duration parsing, English and Spanish (library)"
    qauth     "Q auth with CHALLENGEAUTH"
    antiproxy "Proxy / VPN / Tor detection on join, invite gate"
    tools     "Op commands, !seen and join greeting"
    ipinfo    "Full IP lookups"
    utils     "Weather, time, currency, crypto, countries, DNS, calc, quotes"
    youtube   "YouTube link info and search"
    urltitle  "Titles of pasted links"
    chanstats "Channel statistics and web page"
    reminders "Reminders and alarms"
    feeds     "RSS/Atom feed announcer"
    github    "GitHub profile tracker"
    wiki      "Wikipedia and on this day"
    dictionary "Dictionary, synonyms, Urban Dictionary, word of the day"
    countdown "Event countdowns"
    ask       "AI answers"
    help      "!commands, !help, !scripts and .guide"
}

proc readfile {path} {
    set fd [open $path r]
    fconfigure $fd -encoding utf-8
    set data [read $fd]
    close $fd
    return [string map {\r\n \n} $data]
}

proc banner {text} {
    set line [string repeat # 72]
    return "$line\n#  $text\n$line\n"
}

# The guide is the ::help::guide variable inside help.tcl
set help [readfile [file join $src help.tcl]]
if {![regexp {variable guide \{\n(.*?)\n\}} $help -> guide]} {
    error "guide not found in help.tcl"
}
regexp {eggdrop-quakenet-utils\s+(v[\d.]+)} $guide -> version

set present {}
foreach {name desc} $modules {
    if {[file exists [file join $src $name.tcl]]} {
        lappend present $name $desc
    } else {
        puts "skipped $name.tcl (not found)"
    }
}

set out ""
append out [banner "eggdrop-quakenet-utils.tcl  $version  -  every script in one file"]
append out "#\n"
append out "#  GENERATED FILE: edit the scripts in scripts/ and run\n"
append out "#  \"tclsh build/build.tcl\". Changes made here are lost on the next build.\n"
append out "#\n"
append out "#  INSTALL\n"
append out "#    1. Copy this file to the bot's scripts/ directory.\n"
append out "#    2. In the bot's .conf, instead of one source line per script:\n"
append out "#         source scripts/eggdrop-quakenet-utils.tcl\n"
append out "#         if {\[file exists secrets.tcl\]} {source secrets.tcl}\n"
append out "#    3. .rehash, then .guide on the partyline or !commands on IRC.\n"
append out "#  License: MIT (see LICENSE).\n"
append out "#\n"
foreach l [split $guide \n] {
    append out [string trimright "#  $l"] \n
}
append out "#\n#  CONTENTS\n"
set n 0
set total [expr {[llength $present] / 2}]
foreach {name desc} $present {
    append out [format "#    \[%02d\] %-14s %s\n" [incr n] $name.tcl $desc]
}
append out "#\n#  Each section below starts with the script's own header: what it\n"
append out "#  does, its settings and every command.\n"
append out [string repeat # 72]\n\n

set n 0
foreach {name desc} $present {
    append out \n[banner [format "\[%02d/%02d\]  %s  -  %s" [incr n] $total $name.tcl $desc]]\n
    append out [string trimright [readfile [file join $src $name.tcl]]]\n
}
append out "\nputlog \"eggdrop-quakenet-utils.tcl $version loaded ($total scripts)\"\n"

file mkdir [file join $root dist]
set dest [file join $root dist eggdrop-quakenet-utils.tcl]
set fd [open $dest w]
fconfigure $fd -encoding utf-8 -translation lf
puts -nonewline $fd $out
close $fd
puts "built $dest ($total scripts, [llength [split $out \n]] lines)"
