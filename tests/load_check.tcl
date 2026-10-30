# Loads every script with minimal stubs to catch syntax/load errors
encoding system utf-8
set ::botnick MiBot; set ::botname "MiBot!bot@MiBot.users.quakenet.org"; set ::handlen 32
foreach c {putlog putserv puthelp putquick putkick putdcc bind unbind setudef timer utimer killtimer killutimer pushmode flushmode} {proc $c args {}}
proc timers {} {}; proc utimers {} {}; proc channels {} {}
proc channel {args} {return ""}
set here [file dirname [file normalize [info script]]]
cd [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}]]
foreach f {web timeutil antiproxy qauth tools ipinfo utils youtube urltitle chanstats reminders feeds github wiki dictionary countdown ask guard help} {
    if {[catch {source -encoding utf-8 [file join $here .. scripts $f.tcl]} err]} {
        puts "FAIL $f.tcl: $err"
    } else {
        puts "OK   $f.tcl"
    }
}

# The single-file build (tclsh build/build.tcl), loaded in a clean interpreter
set bundle [file join $here .. dist eggdrop-quakenet-utils.tcl]
if {[file exists $bundle]} {
    set i [interp create]
    $i eval [list set ::botnick MiBot]
    $i eval {
        set ::botname "MiBot!bot@MiBot.users.quakenet.org"; set ::handlen 32
        foreach c {putserv puthelp putquick putkick putdcc bind unbind setudef timer utimer killtimer killutimer pushmode flushmode} {proc $c args {}}
        proc putlog {s} {lappend ::logs $s}
        proc timers {} {}; proc utimers {} {}; proc channels {} {}
        proc channel {args} {return ""}
    }
    if {[catch {$i eval [list source -encoding utf-8 $bundle]} err]} {
        puts "FAIL bundle: $err"
    } else {
        puts "OK   bundle: [lindex [$i eval {set ::logs}] end]"
    }
    interp delete $i
}
