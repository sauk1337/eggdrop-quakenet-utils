# Fourth batch: youtube.tcl (uses the canned ::web::get from test3.tcl)
source "$::scripts/youtube.tcl"
proc matchattr {h f {c ""}} {return 0}

puts "== youtube parsing"
set ok 1
foreach {url want} {
    https://www.youtube.com/watch?v=dQw4w9WgXcQ                 {video dQw4w9WgXcQ 0}
    https://youtu.be/dQw4w9WgXcQ?t=83                           {video dQw4w9WgXcQ 83}
    https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m23s&list=X  {video dQw4w9WgXcQ 83}
    youtube.com/shorts/shortshort1                              {short shortshort1 0}
    https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ     {video dQw4w9WgXcQ 0}
    https://music.youtube.com/watch?v=dQw4w9WgXcQ               {video dQw4w9WgXcQ 0}
    https://www.youtube.com/live/liveliveli1?si=abc             {live liveliveli1 0}
    https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?start=30 {video dQw4w9WgXcQ 30}
    https://www.youtube.com/playlist?list=PLtest                {playlist PLtest 0}
    https://www.youtube.com/@somechannel                        {}
    https://notyoutube.com/watch?v=dQw4w9WgXcQ                  {}
} {
    set got [::youtube::parse_url $url]
    if {$got ne $want} {puts "  $url -> '$got' (want '$want')"; set ok 0}
}
check $ok "URL forms (watch, youtu.be, t=, shorts, mobile, music, live, embed, playlist)"
check {[::youtube::iso_duration PT1H2M3S] == 3723 && [::youtube::iso_duration PT42S] == 42 && [::youtube::iso_duration P1DT1M] == 86460} "ISO 8601 durations"
check {[::youtube::short_num 999] eq "999" && [::youtube::short_num 1234] eq "1.2K" && [::youtube::short_num 45000] eq "45K" && [::youtube::short_num 1500000000] eq "1.5B"} "short numbers"
check {[::youtube::clock_str 754] eq "12:34" && [::youtube::clock_str 3723] eq "1:02:03"} "clock format"

set now [clock format [expr {[clock seconds] - 3 * 86400 - 60}] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
set soon [clock format [expr {[clock seconds] + 2 * 3600 + 60}] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
proc yt_api {id extra} {
    return "{\"items\":\[{\"id\":\"$id\",$extra}\]}"
}
lappend ::canned \
    *googleapis.com/youtube/v3/videos*id=dQw4w9WgXcQ* \
    [yt_api dQw4w9WgXcQ "\"snippet\":{\"title\":\"Never Gonna Give You Up\",\"channelTitle\":\"Rick Astley\",\"publishedAt\":\"$now\",\"liveBroadcastContent\":\"none\"},\"contentDetails\":{\"duration\":\"PT3M33S\",\"definition\":\"hd\"},\"statistics\":{\"viewCount\":\"1612345678\",\"likeCount\":\"18234567\",\"commentCount\":\"2400000\"}"] \
    *googleapis.com/youtube/v3/videos*id=liveliveli1* \
    [yt_api liveliveli1 "\"snippet\":{\"title\":\"Lofi radio\",\"channelTitle\":\"Lofi Girl\",\"publishedAt\":\"$now\",\"liveBroadcastContent\":\"live\"},\"contentDetails\":{\"duration\":\"P0D\",\"definition\":\"hd\"},\"statistics\":{\"viewCount\":\"1\",\"likeCount\":\"500\"},\"liveStreamingDetails\":{\"concurrentViewers\":\"23456\"}"] \
    *googleapis.com/youtube/v3/videos*id=premiere001* \
    [yt_api premiere001 "\"snippet\":{\"title\":\"New song\",\"channelTitle\":\"Band\",\"publishedAt\":\"$now\",\"liveBroadcastContent\":\"upcoming\"},\"contentDetails\":{\"duration\":\"P0D\"},\"statistics\":{},\"liveStreamingDetails\":{\"scheduledStartTime\":\"$soon\"}"] \
    *googleapis.com/youtube/v3/videos*id=shortshort1* \
    [yt_api shortshort1 "\"snippet\":{\"title\":\"Cat\",\"channelTitle\":\"Pets\",\"publishedAt\":\"$now\",\"liveBroadcastContent\":\"none\"},\"contentDetails\":{\"duration\":\"PT42S\",\"definition\":\"hd\",\"contentRating\":{\"ytRating\":\"ytAgeRestricted\"},\"regionRestriction\":{\"blocked\":\[\"ES\",\"DE\"\]}},\"statistics\":{\"viewCount\":\"9100000\"}"] \
    *googleapis.com/youtube/v3/videos*id=nonexistent* \
    {{"items":[]}} \
    *googleapis.com/youtube/v3/search*q=never*gonna* \
    {{"items":[{"id":{"kind":"youtube#video","videoId":"dQw4w9WgXcQ"}}]}} \
    *googleapis.com/youtube/v3/playlists*id=PLtest* \
    {{"items":[{"snippet":{"title":"80s hits","channelTitle":"DJ"},"contentDetails":{"itemCount":57}}]}} \
    *youtube.com/oembed*dQw4w9WgXcQ* \
    {{"title":"Never Gonna Give You Up","author_name":"Rick Astley"}} \
    *returnyoutubedislikeapi.com/votes*videoId=dQw4w9WgXcQ* \
    {{"id":"dQw4w9WgXcQ","likes":18234567,"dislikes":456789,"viewCount":1612345678}}

puts "== youtube with API key"
channel set #test +youtube
set ::youtube::key TESTKEY
set ::youtube::region ES
proc yt {text} {
    set ::out {}
    array unset ::youtube::seenvid
    set ::web::last(yt,#test) 0
    ::youtube::on_pubm pepe p@h * #test $text
    return [plain [join $::out \n]]
}
set r [yt "look https://youtu.be/dQw4w9WgXcQ"]
check {[string match "PRIVMSG #test :YouTube :: Never Gonna Give You Up (Channel: Rick Astley | Duration: 3:33 | Views: 1.6B | Likes: 18M | Comments: 2.4M | Published: 3 days ago | HD)" $r]} "normal video, all fields"
check {[string match "PRIVMSG #test :\00307\002YouTube\002\003 :: \002Never Gonna*\00312Channel:\003 Rick Astley \00307|\003 *" [join $::out]]} "shared style: orange tag, bold title, blue labels, orange pipes"
check {[string match "*Duration: 3:33 (from 1:23)*" [yt "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=83"]]} "timestamp shown"
check {[string match "*YouTube LIVE :: Lofi radio (Channel: Lofi Girl | Watching: 23K*" [yt "https://www.youtube.com/live/liveliveli1"]]} "live stream with viewers"
check {[string match "*YouTube Premiere :: New song (Channel: Band | Starts: in 2 hours*" [yt "https://youtu.be/premiere001"]]} "premiere countdown"
set r [yt "https://youtube.com/shorts/shortshort1"]
check {[string match "*YouTube Shorts :: Cat (Channel: Pets | Duration: 0:42 | Views: 9.1M*18+*blocked in ES*" $r]} "Shorts, age restricted, region blocked"
check {[string match "*YouTube :: Video unavailable*" [yt "https://youtu.be/nonexistent"]]} "unavailable video"
check {[string match "*YouTube Playlist :: 80s hits (Channel: DJ | Videos: 57)" [yt "https://www.youtube.com/playlist?list=PLtest"]]} "playlist"

# Cached: a second paste must not hit the API again
set calls 0
rename ::web::get ::web::get_canned
proc ::web::get {args} {incr ::calls; ::web::get_canned {*}$args}
yt "https://youtu.be/dQw4w9WgXcQ"
check {$::calls == 0} "second lookup served from cache"
rename ::web::get ""
rename ::web::get_canned ::web::get

set ::out {}
set ::web::last(yts,h) 0
::youtube::cmd_yt pepe p@h * #test "never gonna"
check {[string match "*Never Gonna Give You Up*https://youtu.be/dQw4w9WgXcQ)" [plain [join $::out]]]} "!yt search returns details + link"

puts "== youtube key-free"
set ::youtube::key ""
array unset ::youtube::cache
check {[string match "*YouTube :: Never Gonna Give You Up (Channel: Rick Astley | Views: 1.6B | Likes: 18M | Dislikes: 457K)" [yt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"]]} "oEmbed + Return YouTube Dislike"
set ::out {}
set ::web::last(yts,h) 0
::youtube::cmd_yt pepe p@h * #test "some search"
expect "*needs a YouTube API key*" "search explains the key requirement"

puts "== youtube integration"
# Restore the real throttle: a chat line must not swallow a link right after it
proc ::web::throttle {key secs} {
    set now [clock seconds]
    if {[info exists ::web::last($key)] && $now - $::web::last($key) < $secs} {return 1}
    set ::web::last($key) $now
    return 0
}
unset -nocomplain ::web::last(yt,#test)
array unset ::youtube::seenvid
set ::out {}
::youtube::on_pubm pepe p@h * #test "hello everyone"
::youtube::on_pubm pepe p@h * #test "https://youtu.be/dQw4w9WgXcQ"
check {[llength $::out] == 1} "chat line doesn't trigger the cooldown"
check {[::youtube::wants #test https://youtu.be/dQw4w9WgXcQ] && ![::youtube::wants #test https://example.com/]} "urltitle hand-off"
