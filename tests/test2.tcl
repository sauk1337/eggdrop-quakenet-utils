# Second batch: urltitle + chanstats (sourced after test.tcl)
proc check {cond what} {
    set cond [uplevel 1 [list expr $cond]]
    puts [expr {$cond ? "OK   $what" : "FAIL $what"}]
    if {!$cond} {set ::fail 1}
}

puts "== urltitle helpers"
set t [::urltitle::extract_title "<html><head><title>  Hola &amp; adi&oacute;s &#8211; caf&#xe9;\n</title>"]
check {$t eq "Hola & adiós – café"} "title + entities ($t)"
set t [::urltitle::extract_title {<meta property="og:title" content="OG Title"><title>x</title>}]
check {$t eq "OG Title"} "og:title"
set t [::urltitle::json_str {{"title":"Rick á \"Roll\"","author_name":"X"}} title]
check {$t eq {Rick á "Roll"}} "json_str ($t)"
set ok 1
foreach {b l want} {
    http://a.com/x/y.html /z     http://a.com/z
    http://a.com/x/y.html z      http://a.com/x/z
    https://a.com/        //b.com/q https://b.com/q
} {
    if {[::urltitle::absurl $b $l] ne $want} {set ok 0}
}
check $ok "absurl"
set ok 1
foreach ip {127.0.0.1 10.1.1.1 192.168.0.1 172.20.0.1 ::1 169.254.1.1} {
    if {![::urltitle::is_private $ip]} {set ok 0}
}
check {$ok && ![::urltitle::is_private 8.8.8.8]} "is_private"
set t [::urltitle::clean "a\r\nPRIVMSG #x :hack"]
check {[string first "\n" $t] < 0 && [string first "\r" $t] < 0} "no newline injection"
set u "https://www.youtube.com/oembed?[::http::formatQuery format json url https://youtu.be/abc]"
check {$u eq "https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fyoutu.be%2Fabc"} "oembed url"
set ::out {}
::urltitle::output #test "Hola & adiós" www.example.com
expect "PRIVMSG #test :Title :: Hola & adiós (Site: example.com)" "title line in the shared style"

puts "== chanstats"
set ::out {}
channel set #test +chanstats
foreach {n l} {
    ana "hola que tal estais todos hoy?"
    ana "HOLA A TODOS LOS DEL CANAL"
    bob "me gusta mucho programar en tcl :)"
    ana "programar programar programar es genial ;)"
} {
    ::chanstats::on_pubm $n x@y * #test $l
}
::chanstats::on_action bob x@y * #test ACTION "se rie"
::chanstats::on_kick ana x@y * #test bob "fuera"
::chanstats::cmd_stats ana x * #test ""
expect "PRIVMSG #test :Stats :: ana (Lines: 3 (#1 of 2) | *" "!stats"
set ::chanstats::lastcmd(#test) 0
::chanstats::cmd_top ana x * #test ""
expect "PRIVMSG #test :Top :: lines on #test: 1. ana (3) | 2. bob (2)*" "!top"
set ::chanstats::lastcmd(#test) 0
::chanstats::cmd_words ana x * #test ""
expect "*programar (4)*" "!words"
set ::chanstats::lastcmd(#test) 0
::chanstats::cmd_hours ana x * #test ""
expect "*Activity by hour*" "!hours"
set ::chanstats::lastcmd(#test) 0
::chanstats::cmd_today ana x * #test ""
expect "*Today: 5 lines*" "!today"
set u $::chanstats::users(#test,ana)
check {[dict get $u questions] == 1 && [dict get $u shouts] == 1 && [dict get $u smileys] == 1 && [dict get $u kicks] == 1} "counters"

set ::chanstats::datadir csdata
::chanstats::save
array unset ::chanstats::users
array unset ::chanstats::names
::chanstats::load
check {[dict get $::chanstats::users(#test,ana) lines] == 3} "save/load"
set ::chanstats::htmldir html
::chanstats::write_html
set f [open html/test.html]
set h [read $f]
close $f
check {[string match "*<td>ana</td>*" $h] && [string match "*Most used words*" $h]} "html page"

