# Fifth batch: reminders, feeds, wiki, dictionary, countdown, ask, guard
# Stubs that know which channel settings are flags (0) and strings ("")
array set ::udef {}
proc setudef {type name} {set ::udef($name) $type}
proc channel {op chan args} {
    if {$op eq "get"} {
        set k [lindex $args 0]
        if {[info exists ::chanset($chan,$k)]} {return $::chanset($chan,$k)}
        if {[info exists ::udef($k)] && $::udef($k) eq "flag"} {return 0}
        return ""
    }
    # channel set #chan +flag -flag name value ...
    set i 0
    while {$i < [llength $args]} {
        set a [lindex $args $i]
        if {[string index $a 0] in {+ -} && [string length $a] > 1} {
            set ::chanset($chan,[string range $a 1 end]) [expr {[string index $a 0] eq "+"}]
            incr i
        } else {
            set ::chanset($chan,$a) [lindex $args [expr {$i + 1}]]
            incr i 2
        }
    }
}
set ::utimers {}
proc utimer {s cmd} {lappend ::utimers $cmd; return "timer[llength $::utimers]"}
proc run_utimers {} {set l $::utimers; set ::utimers {}; foreach c $l {uplevel #0 $c}}
proc timer {args} {}
proc putquick {s args} {emit $s}
proc pushmode {c m {a ""}} {emit "MODE $c $m $a"}
proc flushmode {c} {}
proc botonchan {c} {return 1}
proc botisop {c} {return 1}
proc isbotnick {n} {string equal -nocase $n $::botnick}
proc channels {} {return {#test}}
proc validchan {c} {expr {$c eq "#test"}}
proc matchattr {h f {c ""}} {return 0}
proc validuser {h} {return 0}
proc nick2hand {n {c ""}} {return "*"}
proc islinked {h} {return 0}
proc md5 {s} {return [string length $s]-[string range $s 0 20]}
set ::chanusers {pepe juan}
proc onchan {n {c ""}} {expr {[lsearch -nocase $::chanusers $n] >= 0}}
proc chanlist {c} {return $::chanusers}
proc getchanhost {n {c ""}} {return "$n@host.$n.example"}
proc isop {n c} {return 0}
proc isvoice {n c} {return 0}

foreach f {timeutil reminders feeds wiki dictionary countdown ask guard} {
    source -encoding utf-8 "$::scripts/$f.tcl"
}

# ------------------------------ reminders ------------------------------
puts "== reminders"
set ::reminders::datadir rmdata
channel set #test +reminders
set ::out {}
::reminders::pub_remind pepe p@host.pepe.example * #test "10m make tea"
expect "PRIVMSG #test :Reminder :: pepe: OK #1: I'll remind you * (in 10m)." "!remind 10m"
set ::reminders::last(host.pepe.example) 0
::reminders::pub_remind pepe p@host.pepe.example * #test "juan in 1 hour call mum"
expect "*OK #2: I'll remind juan*" "!remind <nick>"
set ::reminders::last(host.pepe.example) 0
::reminders::pub_remind pepe p@host.pepe.example * #test "sometime maybe"
expect "*I don't understand when*" "bad time"
set ::reminders::last(host.pepe.example) 0
::reminders::pub_remind pepe p@host.pepe.example * #test "every 5m spam"
expect "*at least 10m*" "recurring minimum"
# Make #1 due and tick
set l {}
foreach r $::reminders::list {if {[dict get $r id] == 1} {dict set r due [expr {[clock seconds] - 1}]}; lappend l $r}
set ::reminders::list $l
set ::out {}
::reminders::tick
expect "PRIVMSG #test :Reminder :: pepe: make tea (Set: *ago)" "delivered when due"
check {[llength $::reminders::list] == 1} "one-off reminder removed after delivery"
# Offline target: waits, then delivered on join
set l {}
foreach r $::reminders::list {dict set r due [expr {[clock seconds] - 1}]; lappend l $r}
set ::reminders::list $l
set ::chanusers {pepe}
set ::out {}
::reminders::tick
check {![llength $::out] && [dict get [lindex $::reminders::list 0] waiting]} "offline target: waiting"
set ::chanusers {pepe juan}
::reminders::on_join juan j@host.juan.example * #test
expect "PRIVMSG #test :Reminder :: juan: call mum (From: pepe | Set: *ago)" "delivered on join"
# Snooze
set ::reminders::last(host.juan.example) 0
::reminders::pub_snooze juan j@host.juan.example * #test "15m"
expect "*snoozed*15m*" "!snooze"
check {[llength $::reminders::list] == 1} "snoozed reminder re-added"
# Persistence
array unset ::reminders::tzs
set n [llength $::reminders::list]
set ::reminders::list {}
::reminders::load
check {[llength $::reminders::list] == $n} "reminders saved and loaded"

# -------------------------------- feeds --------------------------------
puts "== feeds"
set rss {<?xml version="1.0"?><rss><channel><title>My Blog</title>
<item><title>Second &amp; newer</title><link>https://blog.example/2</link><guid>2</guid><pubDate>Mon, 26 Oct 2026 10:00:00 +0000</pubDate></item>
<item><title><![CDATA[First <b>post</b>]]></title><link>https://blog.example/1</link><guid>1</guid></item>
</channel></rss>}
lassign [::feeds::parse $rss] t items
check {$t eq "My Blog" && [llength $items] == 2 && [dict get [lindex $items 0] title] eq "Second & newer" && [dict get [lindex $items 1] title] eq "First post"} "RSS 2.0 parsing (entities, CDATA)"
set atom {<feed xmlns="http://www.w3.org/2005/Atom"><title>Releases</title>
<entry><id>tag:github.com,2008:Repository/1/v2.0</id><title>v2.0</title><link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/v2.0"/><updated>2026-10-25T09:00:00Z</updated></entry>
</feed>}
lassign [::feeds::parse $atom] t items
check {$t eq "Releases" && [dict get [lindex $items 0] link] eq "https://github.com/o/r/releases/tag/v2.0" && [dict get [lindex $items 0] date] ne ""} "Atom parsing"
check {[::feeds::expand github:eggheads/eggdrop] eq "https://github.com/eggheads/eggdrop/releases.atom" &&
       [::feeds::expand youtube:UCabcdefghijklmnopqrstuv] eq "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv" &&
       [::feeds::expand mastodon:@bob@mastodon.social] eq "https://mastodon.social/@bob.rss"} "shortcuts"
check {[::feeds::matches {eggdrop -beta} "Eggdrop 1.10 released"] && ![::feeds::matches {eggdrop -beta} "eggdrop beta 2"] && ![::feeds::matches {tcl} "nothing"]} "filters"
set ::feeds::datadir fddata
channel set #test +feeds
lassign [::feeds::new_feed #test https://blog.example/rss blog 15 pepe] fid data
set ::feeds::feeds($fid) $data
set ::out {}
::feeds::polled $fid 1 200 [encoding convertto utf-8 $rss] {}
check {![llength $::out]} "first fetch primes silently"
set rss2 [string map {"<item><title>Second" "<item><title>Third café</title><link>https://blog.example/3</link><guid>3</guid></item><item><title>Second"} $rss]
::feeds::polled $fid 1 200 [encoding convertto utf-8 $rss2] {}
expect "PRIVMSG #test :Feed :: blog Third café | https://blog.example/3" "new item announced once (UTF-8 decoded)"
::feeds::polled $fid 1 200 [encoding convertto utf-8 $rss2] {}
check {![llength $::out]} "no repeats"
::feeds::polled $fid 0 304 "" {}
check {[dict get $::feeds::feeds($fid) fails] == 0} "304 Not Modified"

# --------------------------------- wiki ---------------------------------
puts "== wiki"
lappend ::canned \
    {*es.wikipedia.org/w/api.php*srsearch=Madrid*} {{"query":{"search":[{"title":"Madrid"},{"title":"Real Madrid"}]}}} \
    {*es.wikipedia.org/api/rest_v1/page/summary/Madrid} {{"type":"standard","title":"Madrid","description":"capital de España","extract":"Madrid es la capital de España.","content_urls":{"desktop":{"page":"https://es.wikipedia.org/wiki/Madrid"}}}} \
    {*en.wikipedia.org/w/api.php*srsearch=Mercury*} {{"query":{"search":[{"title":"Mercury"},{"title":"Mercury (planet)"},{"title":"Mercury (element)"}]}}} \
    {*en.wikipedia.org/api/rest_v1/page/summary/Mercury} {{"type":"disambiguation","title":"Mercury","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Mercury"}}}} \
    {*en.wikipedia.org/api/rest_v1/feed/onthisday/selected/*} {{"selected":[{"text":"Event A","year":1955},{"text":"Event B","year":1881}]}}
channel set #test +wiki
set ::out {}
::wiki::pub_wiki pepe p@h1 * #test "es: Madrid"
expect "PRIVMSG #test :Wikipedia :: Madrid (capital de España) Madrid es la capital de España. | https://es.wikipedia.org/wiki/Madrid" "!wiki with language"
::wiki::pub_wiki pepe p@h2 * #test "Mercury"
expect "*Wikipedia :: Mercury may refer to several things (Mercury (planet) | Mercury (element)) | https://en.wikipedia.org/wiki/Mercury" "disambiguation"
::wiki::pub_otd pepe p@h3 * #test ""
expect "*On this day :: * (1881: Event B | 1955: Event A)" "!otd sorted by year"

# ------------------------------ dictionary ------------------------------
puts "== dictionary"
lappend ::canned \
    {*dictionaryapi.dev/api/v2/entries/en/hello} {[{"word":"hello","phonetic":"/həˈləʊ/","meanings":[{"partOfSpeech":"noun","definitions":[{"definition":"A greeting.","example":"Hello, world"}],"synonyms":["hi"]},{"partOfSpeech":"verb","definitions":[{"definition":"To greet."}]}]}]} \
    {*en.wiktionary.org/api/rest_v1/page/definition/casa} {{"es":[{"partOfSpeech":"Noun","language":"Spanish","definitions":[{"definition":"<a href=\"x\">house</a>, home"}]}]}} \
    {*datamuse.com/words?rel_syn=happy*} {[{"word":"glad"},{"word":"content"}]} \
    {*urbandictionary.com/v0/define?term=yeet*} {{"list":[{"word":"yeet","definition":"to [throw] hard","example":"he yeeted it","thumbs_up":10,"thumbs_down":1},{"word":"yeet","definition":"best one","example":"","thumbs_up":99,"thumbs_down":2}]}} \
    {*merriam-webster.com/wotd*} {<rss><channel><item><title>serendipity</title><link>https://mw.example/serendipity</link><merriam:shortdef>luck in finding good things</merriam:shortdef></item></channel></rss>}
channel set #test +dict
channel set #test +ud
set ::out {}
::dictionary::pub_define pepe p@d1 * #test "hello"
expect "PRIVMSG #test :Define :: hello /həˈləʊ/ (noun) 1. A greeting. (verb) 2. To greet. (Example: \"Hello, world\" | Synonyms: hi)" "!define (dictionaryapi.dev)"
::dictionary::pub_define pepe p@d2 * #test "es:casa"
expect "*Define :: casa ?Spanish? (noun) 1. house, home" "!define es: via Wiktionary"
::dictionary::pub_datamuse rel_syn synonyms pepe p@d3 * #test "happy"
expect "*Synonyms :: happy glad, content" "!synonyms"
::dictionary::pub_ud pepe p@d4 * #test "yeet"
expect "*Urban :: yeet ?1/2? best one (Up: 99 | Down: 2)" "!ud sorted by votes"
::dictionary::pub_ud pepe p@d5 * #test "yeet 2"
expect "*?2/2? to throw hard (Example: he yeeted it | Up: 10 | Down: 1)" "!ud n-th, brackets removed"
::dictionary::pub_wotd pepe p@d6 * #test ""
expect "*Word of the day :: serendipity luck in finding good things | https://mw.example/serendipity" "!wotd"

# ------------------------------- countdown -------------------------------
puts "== countdown"
set ::countdown::datadir cddata
channel set #test +countdown
proc matchattr {h f {c ""}} {return [expr {$h eq "op"}]}
set ::out {}
::countdown::pub_cd pepe p@c1 * #test "add party 24/12 20:00 | big party"
expect "NOTICE pepe :Only bot ops*" "add needs op"
::countdown::pub_cd pepe p@c2 op #test "add party 24/12 20:00 | big party"
expect "*Countdown :: Added. party in * (When: * | ?----------? 0% | big party)" "!cd add"
::countdown::pub_cd pepe p@c3 op #test "add -yearly bday 1/1"
::countdown::pub_cd pepe p@c4 * #test ""
expect "*Countdown :: party: * | bday: *" "!cd list"
# Alert 1h before
set e [lindex [::countdown::get_events #test] 0]
dict set e when [expr {[clock seconds] + 3590}]
::countdown::set_events #test [lreplace [::countdown::get_events #test] 0 0 $e]
set ::out {}
::countdown::tick
expect "PRIVMSG #test :Countdown :: party in 59m (When: *)" "1h milestone announced"
::countdown::tick
check {![llength [lsearch -all -inline $::out "*party*"]]} "milestone not repeated"
dict set e when [expr {[clock seconds] - 1}]
dict set e done {604800 86400 3600 600}
::countdown::set_events #test [lreplace [::countdown::get_events #test] 0 0 $e]
set ::out {}
::countdown::tick
expect "PRIVMSG #test :Countdown :: party is happening NOW! big party" "start announced"

# ---------------------------------- ask ----------------------------------
puts "== ask"
set ::posts {}
set ::ask_reply {{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"sig1"},{"type":"text","text":"**Madrid** is the capital.\n\n- second line\n- third line\n- fourth line"}],"stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":20}}}
proc ::web::post {url json callback {headers {}} {timeout 0}} {
    lappend ::posts [list $url $json $headers]
    {*}$callback 1 200 $::ask_reply
}
proc matchattr {h f {c ""}} {return 0}
channel set #test +ask
set ::ask::api_key "sk-test"
set ::out {}
::ask::pub_ask pepe p@a1 * #test "capital of spain?"
lassign [lindex $::posts 0] url body hdr
check {$url eq "https://api.anthropic.com/v1/messages" && [string match {*"model":"claude-opus-5-5"*} $body] && [string match {*"output_config":{"effort":"low"}*} $body] && [string match {*"fallbacks":"default"*} $body]} "Claude request body"
check {[dict get $hdr anthropic-version] eq "2026-10-21" && [dict get $hdr anthropic-beta] eq "server-side-fallback-2026-07-01" && [dict get $hdr x-api-key] eq "sk-test"} "Claude request headers"
check {[catch {::web::json $body}] == 0} "request body is valid JSON"
check {[lindex $::out 0] eq "PRIVMSG #test :[::web::msg Ask "pepe: \002Madrid\002 is the capital."]" &&[lindex $::out 1] eq "PRIVMSG #test :- second line" && [llength $::out] == 3} "answer as 3 plain IRC lines"
set ::ask::last(u,a2) 0
set ::ask::last(c,#test) 0
set ::ask_first [list $::ask_reply]
::ask::pub_ask pepe p@a2 * #test "and of france?"
lassign [lindex $::posts 1] url body hdr
set raw [::web::json_raw [lindex $::ask_first 0] content]
set want "{\"role\":\"user\",\"content\":\"pepe: capital of spain?\"},{\"role\":\"assistant\",\"content\":$raw},{\"role\":\"user\",\"content\":\"pepe: and of france?\"}"
check {[string first $want $body] >= 0 && [string first {"signature":"sig1"} $body] >= 0} "assistant turn replayed byte for byte (thinking block kept)"
set ::ask_reply {{"content":[],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":0}}}
set ::out {}
set ::ask::last(u,a3) 0
set ::ask::last(c,#test) 0
::ask::pub_ask juan j@a3 * #test "bad question"
expect "PRIVMSG #test :Ask :: juan: sorry, I can't help with that." "refusal handled"
set ::ask::api_key ""
set ::out {}
set ::ask::last(u,a4) 0
::ask::pub_ask juan j@a4 * #test "hi"
expect "NOTICE juan :Ask :: The AI is not configured*" "missing key"

# --------------------------------- guard ---------------------------------
puts "== guard"
proc validuser {h} {expr {$h in {owner op1 voice1 banned}}}
array set ::flags {owner {n|} op1 {|o} voice1 {|v} banned {|B}}
proc matchattr {h f {c ""}} {
    if {![info exists ::flags($h)]} {return 0}
    lassign [split $::flags($h) |] hg hc
    lassign [split $f |] fg fc
    foreach x [split $fg ""] {if {$x ne "-" && [string first $x $hg] >= 0} {return 1}}
    foreach x [split $fc ""] {if {$x ne "-" && [string first $x $hc] >= 0} {return 1}}
    return 0
}
proc getuser {h type {k ""}} {return ""}
set ::botname "MiBot!bot@MiBot.users.quakenet.org"
proc userlist {{f ""} {c ""}} {return {owner op1 voice1 banned}}
proc banlist {{c ""}} {return {}}
proc maskhost {nuh {type 3}} {return "*!*[lindex [split $nuh !] 1]"}
proc newchanban {chan mask by msg t} {emit "BAN $chan $mask ($t min) $msg"}
proc nick2hand {n {c ""}} {set m {boss owner opguy op1 vguy voice1 bad banned}; expr {[dict exists $m $n] ? [dict get $m $n] : "*"}}
check {[::guard::level owner #test] == 10 && [::guard::level op1 #test] == 4 && [::guard::level voice1 #test] == 3 && [::guard::level banned #test] == 1 && [::guard::level "*" #test] == 0} "levels 0-10 (1 = autoban, consistent)"
check {[::guard::parse_duration %1h30m] == 90 && [::guard::parse_duration %2d] == 2880 && [::guard::parse_duration %0] == 0 && [::guard::parse_duration %x] eq ""} "ban durations"
set ::out {}
::guard::on_pubm vguy v@h voice1 #test "!kick bad"
expect "NOTICE vguy :Guard :: You don't have enough access*" "command level check"
::guard::on_pubm boss b@h owner #test "!punish 1"
expect "NOTICE boss :*needs the protection*" "protection commands need status on"
# Enable protection (needs Q on the channel)
set ::chanusers {Q boss opguy vguy bad evil}
proc getchanhost {n {c ""}} {expr {$n eq "Q" ? "TheQBot@CServe.quakenet.org" : "$n@host.$n.example"}}
proc isop {n c} {expr {$n in {opguy evil}}}
set ::out {}
::guard::on_pubm boss b@h owner #test "!status on"
expect "NOTICE boss :Guard :: Protection enabled on #test (service: Q)*" "!status on"
check {[channel get #test punish-methode] == 3 && [channel get #test reaction-need-op] eq "deopall:reop"} "defaults applied"
# An op without access deops a protected op: reverted + punished
set ::out {}
set ::utimers {}
::guard::on_mode evil e@host.evil.example * #test -o opguy
expect "MODE #test +o opguy" "protected op re-opped"
run_utimers
check {[lsearch -glob $::out "KICK #test evil *abuse*"] >= 0 && [lsearch -glob $::out "BAN #test *!*@host.evil.example*"] >= 0} "abuser kickbanned (method 3)"
# Q deopping someone is never punished
set ::out {}
set ::utimers {}
::guard::on_mode Q TheQBot@CServe.quakenet.org * #test -o opguy
run_utimers
check {![llength $::out]} "Q is trusted"
# Bot deopped -> reaction through Q
set ::out {}
::guard::on_mode evil e@host.evil.example * #test -o MiBot
check {"PRIVMSG Q :DEOPALL #test" in $::out && "PRIVMSG Q :OP #test" ni $::out} "need-op reaction (botisop stub = 1, so no OP)"
# WHOIS-driven ban: two lookups at once don't mix
set ::out {}
::guard::on_pubm boss b@h owner #test "!ban someone %2h spamming"
::guard::on_pubm boss b@h owner #test "!whois other"
check {"WHOIS someone" in $::out && "WHOIS other" in $::out} "parallel WHOIS lookups"
set ::out {}
::guard::raw311 srv 311 "MiBot someone ident 1.2.3.4 * :Real"
::guard::raw330 srv 330 "MiBot someone SomeAcc :is authed as"
::guard::raw311 srv 311 "MiBot other x 5.6.7.8 * :Other"
::guard::raw318 srv 318 "MiBot someone :End of /WHOIS list."
expect "*Ban *!*@SomeAcc.users.quakenet.org* set on #test (expires in*" "ban by account from WHOIS 330"
::guard::raw318 srv 318 "MiBot other :End of /WHOIS list."
expect "NOTICE boss :Guard :: other is not a bot user." "second lookup answered separately"
