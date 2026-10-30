# Test harness: stubs the Eggdrop Tcl API and exercises the scripts.
# Run from anywhere:  tclsh tests/run.tcl
encoding system utf-8
set ::here [file dirname [file normalize [info script]]]
set ::scripts [file join [file dirname $::here] scripts]
# Minimal Eggdrop stubs
set ::botnick MiBot
set ::out {}
proc emit {s} { lappend ::out $s; puts "  >> $s" }
proc putlog {s} { puts "  LOG $s" }
foreach c {putserv puthelp putquick} { proc $c {s args} { emit $s } }
proc putkick {chan nick msg} { emit "KICK $chan $nick :$msg" }
proc putdcc {idx s} { emit "DCC($idx) $s" }
proc newchanban {chan mask by msg t} { emit "BAN $chan $mask ($t min) $msg" }
proc bind {args} {}
proc setudef {args} {}
proc timer {args} {}
proc utimer {s cmd} { lappend ::utimers $cmd }
proc timers {} {return {}}
proc utimers {} {return {}}
proc validchan {c} {return 1}
proc valididx {i} {return 1}
proc botonchan {c} {return 1}
proc botisop {c} {return 1}
proc isbotnick {n} {string equal -nocase $n $::botnick}
proc onchan {n c} {expr {$n in {pepe juan torero}}}
proc isop {n c} {return 0}
proc isvoice {n c} {return 0}
proc matchattr {h f {c ""}} {return 0}
proc getchanhost {n {c ""}} { if {$n eq "pepe"} {return "pepe@1.2.3.4"}; return "" }
array set ::chanset {}
proc channel {op chan args} {
    if {$op eq "get"} { set k [lindex $args 0]; if {[info exists ::chanset($chan,$k)]} {return $::chanset($chan,$k)}; return 0 }
    foreach a $args { set ::chanset($chan,[string range $a 1 end]) [expr {[string index $a 0] eq "+"}] }
}
proc channels {} {return {#test}}
proc stripcodes {f s} {return $s}
proc duration {s} {return "${s}s"}

# Fake DNS: synchronous, the worst case
proc dnslookup {name cb args} {
    set fake {
        4.3.2.1.dnsbl.dronebl.org 127.0.0.19
        9.9.9.9.dnsbl.dronebl.org ""
        vpn.example.net 5.6.7.8
        8.7.6.5.torexit.dan.me.uk 127.0.0.100
    }
    if {[regexp {^[\d.]+$} $name]} {
        {*}$cb $name "host-$name.example.com" 1 {*}$args
        return
    }
    set ip ""
    if {[dict exists $fake $name]} {set ip [dict get $fake $name]}
    {*}$cb [expr {$ip eq "" ? "0.0.0.0" : $ip}] $name [expr {$ip ne ""}] {*}$args
}

set ::tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] eggdrop-tests-[pid]]
file mkdir $::tmp
cd $::tmp

source -encoding utf-8 "$::scripts/web.tcl"
source "$::scripts/antiproxy.tcl"
source "$::scripts/qauth.tcl"
source "$::scripts/tools.tcl"
source "$::scripts/urltitle.tcl"
source "$::scripts/chanstats.tcl"

# No real network in tests: HTTP methods disabled
set ::antiproxy::proxycheck 0
set ::antiproxy::ipapi 0
set ::antiproxy::allow_authed 0
set ::antiproxy::torlist(5.6.7.8) 1

channel set #test +antiproxy +antiproxy-gate
# Colours and bold are compared stripped: tests check the text, and
# test_style checks the codes themselves.
proc plain {s} {
    regsub -all {\003(\d{1,2}(,\d{1,2})?)?|[\002\017\026\037]} $s "" s
    return $s
}
proc expect {pat what} {
    set ok 0
    set pat [plain $pat]
    foreach l $::out { if {[string match $pat [plain $l]]} {set ok 1} }
    puts [expr {$ok ? "OK   $what" : "FAIL $what"}]
    if {!$ok} {set ::fail 1}
    set ::out {}
}
set ::fail 0

puts "== rev_ip"
puts [::antiproxy::rev_ip 1.2.3.4]
puts [::antiproxy::rev_ip 2001:db8::1]

puts "== join DroneBL"
::antiproxy::on_join pepe pepe@1.2.3.4 * #test
expect "BAN #test *!*@1.2.3.4*" "kickban on DroneBL hit"

puts "== clean join"
::antiproxy::on_join juan juan@9.9.9.9 * #test
puts "  pending: [array size ::antiproxy::checks]"
if {[array size ::antiproxy::checks] == 0} {puts "OK   clean user, no action"} else {puts "FAIL checks left pending"; set ::fail 1}
set ::out {}

puts "== join by hostname (Tor + rDNS)"
::antiproxy::on_join torero x@vpn.example.net * #test
expect "KICK #test torero*Tor exit node*" "kick on Tor (resolved host)"

puts "== +x authed user"
::antiproxy::on_join juan juan@juan.users.quakenet.org * #test
if {![llength $::out]} {puts "OK   +x user let through"} else {puts "FAIL"; set ::fail 1}

puts "== cache"
::antiproxy::on_join pepe pepe@1.2.3.4 * #test
expect "KICK*" "kick from cache"

puts "== gate"
::antiproxy::msg_gate nuevo n@9.9.9.9 * #test
expect "INVITE nuevo #test" "invites clean IP"
set ::antiproxy::gatelast(1.2.3.4) 0
::antiproxy::msg_gate malo m@1.2.3.4 * #test
expect "NOTICE malo :Access to #test denied*" "refuses proxy"

puts "== manual"
::antiproxy::dcc_check h 7 1.2.3.4
expect "DCC(7) Antiproxy :: 1.2.3.4: proxy detected (Score: 3 | Reasons: DNSBL*" "pcheck"

proc onchan {n {c ""}} {return 1}

puts "== qauth challenge"
set ::qauth::user "MiCuenta"
set ::qauth::pass "secret"
if {$::qauth::sha} {
    ::qauth::on_notice Q TheQBot@CServe.quakenet.org * "CHALLENGE 3afabede5c2859fd821e315f889d9a6c HMAC-MD5 HMAC-SHA1 HMAC-SHA256 LEGACY-MD5" MiBot
    expect "PRIVMSG Q@CServe.quakenet.org :CHALLENGEAUTH MiCuenta * HMAC-SHA256" "challengeauth"
}
::qauth::on_notice Q TheQBot@CServe.quakenet.org * "You are now logged in as MiCuenta." MiBot
expect "MODE MiBot +x" "+x after auth"

puts "== tools seen"
::tools::seen_part ana a@b.c * #test "bye"
proc onchan {n c} {return 0}
::tools::cmd_seen x x@y * #test ana
expect "PRIVMSG #test :Seen :: ana (Host: a@b.c | Last seen: * ago | Doing: *bye*)" "seen"
::tools::seen_save

source [file join $::here test2.tcl]
source [file join $::here test3.tcl]
source [file join $::here test4.tcl]
source [file join $::here test5.tcl]
source [file join $::here test6.tcl]
source [file join $::here test7.tcl]
source [file join $::here test8.tcl]

puts [expr {$::fail ? "\n*** FAILURES ***" : "\nALL OK"}]
