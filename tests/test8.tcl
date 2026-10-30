# Eighth batch: github.tcl (profile tracker) with canned API answers
source -encoding utf-8 "$::scripts/web.tcl"
source -encoding utf-8 "$::scripts/timeutil.tcl"
source -encoding utf-8 "$::scripts/github.tcl"
puts "== github"

set ::github::datadir ghdata
set ::github::backoff 0
array unset ::github::subs
array unset ::github::users
proc ::web::throttle {key secs} {return 0}
proc matchattr {h f {c ""}} {return 1}
proc validchan {c} {expr {$c eq "#test"}}
channel set #test +github

# Every fetch answers synchronously with ::gh_reply = {code body ?meta?}
set ::gh_fetches {}
# The repository list of a profile answers with ::gh_repos instead
set ::gh_repos [list 200 {[]}]
proc ::web::fetch {url callback {headers {}}} {
    lappend ::gh_fetches $url
    if {[string match */repos?sort=created* $url]} {
        lassign $::gh_repos code body meta
    } else {
        lassign $::gh_reply code body meta
    }
    {*}$callback [expr {$code == 200}] $code [encoding convertto utf-8 $body] $meta
}
proc iso {secs} {clock format $secs -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1}
proc ev {id type payload {age 60}} {
    return "{\"id\":\"$id\",\"type\":\"$type\",\"actor\":{\"login\":\"torvalds\",\"display_login\":\"torvalds\"},\"repo\":{\"name\":\"torvalds/linux\"},\"payload\":$payload,\"created_at\":\"[iso [expr {[clock seconds] - $age}]]\"}"
}
proc events {args} {return "\[[join $args ,]\]"}
set push_full {{"ref":"refs/heads/master","head":"bbbbbbbbbbbbbbbbbbbb","before":"aaaaaaaaaaaaaaaaaaaa","size":2,"commits":[{"sha":"1","message":"First"},{"sha":"2","message":"Fix the scheduler\n\nLong body"}]}}
set push_bare {{"ref":"refs/heads/master","head":"dddddddddddddddddddd","before":"cccccccccccccccccccc"}}
set release {{"action":"published","release":{"tag_name":"v6.20","name":"Linux 6.20","prerelease":false,"html_url":"https://github.com/torvalds/linux/releases/tag/v6.20"}}}

# add: checks that the user exists first
set ::gh_reply [list 200 {{"login":"torvalds","type":"User","html_url":"https://github.com/torvalds"}}]
set ::out {}
set ::utimers {}
::github::pub_gh pepe p@h * #test "add Torvalds"
expect "PRIVMSG #test :GitHub :: Now tracking user torvalds on #test (Announces: push, release, create, fork, public, pr, issues | https://github.com/torvalds)" "!gh add verifies the user"
check {[string match "*poll torvalds*" $::utimers]} "first check scheduled"

set ::gh_reply [list 404 {{"message":"Not Found"}}]
::github::pub_gh pepe p@h * #test "add nobody-here"
expect "PRIVMSG #test :GitHub :: No GitHub user or organisation called \"nobody-here\"." "!gh add of a missing user"
check {![info exists ::github::subs(#test\ nobody-here)]} "missing user not saved"

# First check: records what's there, announces nothing
set ::gh_reply [list 200 [events [ev 10 PushEvent $push_full]] {etag {W/"e1"}}]
set ::out {}
::github::poll torvalds
check {![llength $::out]} "priming announces nothing"
check {[dict get $::github::users(torvalds) primed] && "10" in [dict get $::github::users(torvalds) seen]} "priming records the seen events"

# 304 with the ETag
set ::gh_reply [list 304 ""]
::github::poll torvalds
check {![llength $::out]} "304: nothing new"

# New push with commits + release, announced oldest first
set ::gh_reply [list 200 [events [ev 12 PushEvent $push_full 30] [ev 11 ReleaseEvent $release 90] [ev 10 PushEvent $push_full]]]
::github::poll torvalds
check {[llength $::out] == 2 && [string match "*released*" [lindex $::out 0]]} "two new events, oldest first"
expect "PRIVMSG #test :GitHub :: torvalds pushed 2 commits to torvalds/linux (Branch: master | Last: \"Fix the scheduler\" | https://github.com/torvalds/linux/compare/aaaaaaaaaaaa...bbbbbbbbbbbb)" "push with commits"
set ::out {}
::github::poll torvalds
check {![llength $::out]} "seen events are not repeated"

# Push without commits/size (newer API payloads)
set ::gh_reply [list 200 [events [ev 13 PushEvent $push_bare]]]
::github::poll torvalds
expect "PRIVMSG #test :GitHub :: torvalds pushed to torvalds/linux (Branch: master | https://github.com/torvalds/linux/compare/cccccccccccc...dddddddddddd)" "push without commits"

# Release line
set ::gh_reply [list 200 [events [ev 14 ReleaseEvent $release]]]
::github::poll torvalds
expect "PRIVMSG #test :GitHub :: torvalds released torvalds/linux v6.20 (Name: Linux 6.20 | https://github.com/torvalds/linux/releases/tag/v6.20)" "release"

# Stars are off by default; too old events are skipped
set ::gh_reply [list 200 [events [ev 15 WatchEvent {{"action":"started"}}] [ev 16 PushEvent $push_bare 200000]]]
::github::poll torvalds
check {![llength $::out]} "star off by default, old event skipped"

# Filter: only releases
::github::pub_gh pepe p@h * #test "filter torvalds release"
expect "PRIVMSG #test :GitHub :: torvalds now announces: release" "!gh filter"
set ::gh_reply [list 200 [events [ev 18 ReleaseEvent $release] [ev 17 PushEvent $push_bare]]]
::github::poll torvalds
check {[llength $::out] == 1 && [string match "*released*" [lindex $::out 0]]} "filter keeps only releases"
set ::out {}
::github::pub_gh pepe p@h * #test "filter torvalds bogus"
expect "*Unknown type: bogus*" "unknown filter type refused"
::github::pub_gh pepe p@h * #test "filter torvalds default"
set ::out {}

# Many events: max 3, then "...and N more"
set ::gh_reply [list 200 [events [ev 25 PushEvent $push_bare] [ev 24 PushEvent $push_bare] [ev 23 PushEvent $push_bare] [ev 22 PushEvent $push_bare] [ev 21 PushEvent $push_bare]]]
::github::poll torvalds
check {[llength $::out] == 4} "three events and a summary"
expect "PRIVMSG #test :GitHub :: ...and 2 more from torvalds https://github.com/torvalds" "...and N more"

# Rate limit: wait until the reset time, then no polling
set ::gh_reply [list 200 "\[\]" [list x-ratelimit-remaining 0 x-ratelimit-reset [expr {[clock seconds] + 900}]]]
::github::poll torvalds
check {[::github::limited]} "rate limit detected"
set n [llength $::gh_fetches]
dict set ::github::users(torvalds) checked 0
set ::github::lastpoll 0
::github::tick
check {[llength $::gh_fetches] == $n} "no checks while rate limited"
set ::github::backoff 0
set ::gh_reply [list 304 ""]
::github::tick
check {[llength $::gh_fetches] == $n + 2} "tick checks the overdue profile (events + repositories)"
::github::tick
check {[llength $::gh_fetches] == $n + 2} "tick respects the gap between checks"
set ::gh_reply [list 403 {{"message":"rate limited"}} {retry-after 60}]
::github::poll torvalds
check {[::github::limited]} "403 with retry-after backs off"
set ::github::backoff 0

# Cards
set ::gh_reply [list 200 {{"login":"torvalds","name":"Linus Torvalds","type":"User","bio":null,"public_repos":8,"followers":245000,"following":0,"created_at":"2011-09-03T15:26:22Z","location":"Portland, OR","blog":"","html_url":"https://github.com/torvalds"}}]
set ::out {}
::github::pub_gh pepe p@h * #test "torvalds"
expect "PRIVMSG #test :GitHub :: Linus Torvalds (torvalds) (Repos: 8 | Followers: 245K | Following: 0 | Since: Sep 2011 | Location: Portland, OR | https://github.com/torvalds)" "!gh <user> card"
set ::gh_reply [list 200 {{"full_name":"torvalds/linux","description":"Linux kernel source tree","stargazers_count":190000,"forks_count":55000,"language":"C","open_issues_count":2,"pushed_at":"2026-10-29T10:00:00Z","license":{"spdx_id":"NOASSERTION"},"archived":false,"fork":false,"html_url":"https://github.com/torvalds/linux"}}]
::github::pub_gh pepe p@h * #test "repo https://github.com/torvalds/linux"
expect "PRIVMSG #test :GitHub :: torvalds/linux (Linux kernel source tree | Stars: 190K | Forks: 55K | Language: C | Issues: 2 | Updated: * ago | https://github.com/torvalds/linux)" "!gh repo card"

# Persistence, list, del
# New repositories come from the repository list, without waiting for
# the events feed (which GitHub may publish hours later)
proc repo {name {age 60} {fork false}} {
    return "{\"name\":\"$name\",\"full_name\":\"torvalds/$name\",\"fork\":$fork,\"description\":\"A new thing\",\"language\":\"Tcl\",\"html_url\":\"https://github.com/torvalds/$name\",\"created_at\":\"[iso [expr {[clock seconds] - $age}]]\"}"
}
set ::gh_reply [list 304 ""]
set ::gh_repos [list 200 "\[[repo newthing]\]"]
set ::out {}
::github::poll torvalds
expect "PRIVMSG #test :GitHub :: torvalds created repository torvalds/newthing (A new thing | Language: Tcl | https://github.com/torvalds/newthing)" "new repository announced from the repository list"
set ::out {}
::github::poll torvalds
check {![llength $::out]} "new repository not repeated"
set ::gh_reply [list 200 [events [ev 900 CreateEvent {{"ref_type":"repository","ref":null}}]]]
proc ev {id type payload {age 60}} {
    return "{\"id\":\"$id\",\"type\":\"$type\",\"actor\":{\"login\":\"torvalds\",\"display_login\":\"torvalds\"},\"repo\":{\"name\":\"torvalds/newthing\"},\"payload\":$payload,\"created_at\":\"[iso [expr {[clock seconds] - $age}]]\"}"
}
set ::gh_reply [list 200 [events [ev 901 CreateEvent {{"ref_type":"repository","ref":null}}]]]
set ::out {}
::github::poll torvalds
check {![llength $::out]} "late CreateEvent of an announced repository is skipped"

set ::gh_repos [list 200 "\[[repo forked 60 true],[repo newthing]\]"]
set ::out {}
::github::poll torvalds
check {![llength $::out]} "forks are left to the events feed"

# !gh check always answers
set ::gh_reply [list 304 ""]
set ::gh_repos [list 304 ""]
set ::out {}
set ::utimers {}
::github::pub_gh pepe p@h * #test "check"
foreach t $::utimers {eval $t}
expect "PRIVMSG #test :GitHub :: Nothing new from torvalds*" "!gh check says when there is nothing new"

# A profile tracked before this version: its first repository read
# announces only what was created after !gh add
dict set ::github::subs(#test\ torvalds) added [expr {[clock seconds] - 600}]
dict set ::github::users(torvalds) rprimed 0
dict set ::github::users(torvalds) repos {}
set ::gh_repos [list 200 "\[[repo justnow 120],[repo ancient 86400]\]"]
set ::out {}
::github::poll torvalds
check {[string match "*created repository torvalds/justnow*" [plain [join $::out]]] && ![string match "*ancient*" [join $::out]]} "first read: only repositories created after !gh add"

# !gh repo <user>: latest repositories
set ::gh_reply [list 200 "\[{\"name\":\"linux\",\"language\":\"C\",\"stargazers_count\":190000},{\"name\":\"tool\",\"language\":null,\"stargazers_count\":0}\]"]
set ::out {}
::github::pub_gh pepe p@h * #test "repo torvalds"
expect "PRIVMSG #test :GitHub :: Latest repositories of torvalds (linux C, 190K stars | tool | https://github.com/torvalds?tab=repositories)" "!gh repo <user>"

::github::pub_gh pepe p@h * #test "list"
expect "PRIVMSG #test :GitHub :: Tracking 1 profile on #test (torvalds)" "!gh list"
::github::save
array unset ::github::subs
array unset ::github::users
::github::load
check {[info exists ::github::subs(#test\ torvalds)] && [dict get $::github::users(torvalds) primed]} "tracked profiles survive a restart"
::github::pub_gh pepe p@h * #test "del torvalds"
expect "PRIVMSG #test :GitHub :: No longer tracking torvalds on #test." "!gh del"
check {![array size ::github::users]} "profile state dropped with its last channel"
::github::pub_gh pepe p@h * #test "list"
expect "PRIVMSG #test :GitHub :: No profiles tracked here. Ops: !gh add <user>" "!gh list empty"

proc matchattr {h f {c ""}} {return 0}
::github::pub_gh pepe p@h * #test "add someone"
expect "NOTICE pepe :Only bot ops can change*" "add needs op"
