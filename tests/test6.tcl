# Sixth batch: help.tcl (loaded last, sees every script loaded so far)
source -encoding utf-8 "$::scripts/help.tcl"
puts "== help"
proc matchattr {h f {c ""}} {expr {$h eq "op"}}
set ::chanset(#test,youtube) 0
set ::out {}
::help::pub_commands pepe p@hh1 * #test ""
set all [plain [join $::out \n]]
check {[string match "*reminders: !remind !at !reminders !snooze*" $all] && [string match "*ipinfo: !ip*" $all] && [string match "*!weather !w *" $all]} "!commands lists enabled scripts"
check {[string match "*\002!remind\002 \002!at\002*" [join $::out]]} "commands in bold"
check {![string match "*!kick*" $all] && ![string match "*!pcheck*" $all]} "no op commands for a normal user"
check {![string match "*youtube:*" $all]} "scripts off on the channel are hidden"
check {[llength $::out] <= 6} "short answer ([llength $::out] lines)"
check {![regexp {[^\x01-\x7f]} [join $::out]]} "ASCII only (old mIRC)"
set ::out {}
::help::pub_commands opguy o@hh2 op #test ""
check {[string match "*!kick !kb*" [plain [join $::out]]] && [string match "*!pcheck*" [join $::out]]} "ops see op commands"
set ::out {}
::help::pub_scripts pepe p@hh3 * #test ""
check {[string match "*scripts loaded on #test*youtube off*reminders on*" [plain [join $::out]]]} "!scripts shows on/off"
set ::out {}
::help::pub_scripts pepe p@hh4 * #test "reminders"
check {[string match "NOTICE pepe :Help :: reminders (Reminders and alarms | Status: on here)" [plain [lindex $::out 0]]] && [string match "*!remind <when> <text>*" [plain [join $::out]]]} "!scripts <name>"
set ::out {}
::help::pub_scripts pepe p@hh4 * #test "reminders"
check {![llength $::out]} "throttled"
set ::out {}
::help::pub_scripts pepe p@hh5 * #test "nope"
expect "NOTICE pepe :Help :: No script called \"nope\"*" "unknown script"
set ::out {}
::help::pub_commands pepe p@hh6 * #test "!remind"
check {[string match "*Help :: !remind (Script: reminders)*!remind <when> <text>*" [plain [join $::out]]]} "!help <!command>"
set ::out {}
::help::dcc_guide boss 5 ""
check {[llength $::out] > 40 && [string match "*QUICK START*" [join $::out]] && ![regexp {[^\x01-\x7f]} [join $::out]]} ".guide prints the ASCII guide"
