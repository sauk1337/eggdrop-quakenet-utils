# =====================================================================
#  youtube.tcl  v1.2.0  -  YouTube link info and search
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Pasted YouTube links (watch, youtu.be, shorts, live, embed, music,
#    mobile, playlists, ?t=) are answered with one line:
#      YouTube :: Title (Channel: x | Duration: 12:34 | Views: 1.2M | Likes: 45K | ...)
#      YouTube LIVE :: Title (Channel: x | Watching: 2.3K)
#      YouTube Premiere :: Title (Channel: x | Starts: in 2 hours)
#      YouTube Playlist :: Title (Channel: x | Videos: 57)
#    With a YouTube Data API v3 key (free, 10,000 units/day): all fields
#    and !yt search. Without a key: title and channel (oEmbed) plus
#    views/likes/dislikes from Return YouTube Dislike. Results cached.
#    urltitle.tcl leaves YouTube links to this script.
#
#  REQUIREMENTS
#    web.tcl (load it first), tcl-tls
#
#  SETUP
#    .chanset #chan +youtube
#    Optional key in secrets.tcl:  set ::youtube::key "AIza..."
#
#  COMMANDS (channel)
#    !yt | !youtube <search terms>     first result + link (needs the key)
#    !yt <link or id>                  details on demand
# =====================================================================

namespace eval ::youtube {
    # ------------------------- CONFIGURATION -------------------------
    variable key ""                  ;# YouTube Data API v3 key ("" = key-free mode)
    variable dislikes 1              ;# show Return YouTube Dislike estimates (key-free mode)
    variable cooldown 3              ;# seconds between answers on a channel
    variable repeat_mins 5           ;# don't repeat the same video within X minutes
    variable maxlinks 2              ;# links handled per line
    variable cache_mins 30
    variable search_throttle 15      ;# seconds between !yt searches per user
    variable ignore_nicks {Q L}
    variable region ""               ;# e.g. ES: warn when blocked there ("" = off)
    variable show_url_on_paste 0     ;# repeat the short link when someone pastes one

    # --------------------- STATE (do not touch) ---------------------
    variable cache                   ;# cache(id) -> {expire info}
    variable lastchan
    variable seenvid
}

setudef flag youtube

# ----------------------------- PARSING -----------------------------

# Returns {type id start} for a YouTube URL, or "" if it isn't one.
# type: video | short | live | playlist
proc ::youtube::parse_url {url} {
    if {![regexp -nocase {^(?:https?://)?(?:www\.|m\.|music\.)?(youtube\.com|youtu\.be|youtube-nocookie\.com)(/[^\s]*)?$} $url -> dom rest]} {
        return ""
    }
    set path $rest
    set query ""
    regexp {^([^?#]*)\??([^#]*)} $rest -> path query
    set params [dict create]
    foreach kv [split $query &] {
        lassign [split $kv =] k v
        if {$k ne ""} {dict set params $k $v}
    }
    set start [expr {[dict exists $params t] ? [parse_t [dict get $params t]] : 0}]
    if {[dict exists $params start] && !$start} {set start [parse_t [dict get $params start]]}
    set id ""
    set type video
    if {[string equal -nocase $dom youtu.be]} {
        regexp {^/([A-Za-z0-9_-]{11})} $path -> id
    } elseif {[regexp {^/shorts/([A-Za-z0-9_-]{11})} $path -> id]} {
        set type short
    } elseif {[regexp {^/live/([A-Za-z0-9_-]{11})} $path -> id]} {
        set type live
    } elseif {[regexp {^/(?:embed|v)/([A-Za-z0-9_-]{11})} $path -> id]} {
    } elseif {[dict exists $params v] && [regexp {^[A-Za-z0-9_-]{11}$} [dict get $params v]]} {
        set id [dict get $params v]
    } elseif {[string match /playlist* $path] && [dict exists $params list]} {
        return [list playlist [dict get $params list] 0]
    }
    if {$id eq ""} {return ""}
    list $type $id $start
}

# "1h2m3s", "90s", "90" -> seconds
proc ::youtube::parse_t {t} {
    if {[string is integer -strict $t]} {return $t}
    set s 0
    foreach {all n u} [regexp -all -inline {(\d+)([hms])} $t] {
        incr s [expr {$n * ($u eq "h" ? 3600 : $u eq "m" ? 60 : 1)}]
    }
    return $s
}

# ISO 8601 duration (PT1H2M3S, P1DT2H) -> seconds
proc ::youtube::iso_duration {d} {
    set s 0
    if {[regexp {^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$} $d -> dd hh mm ss]} {
        foreach {v m} [list $dd 86400 $hh 3600 $mm 60 $ss 1] {
            if {$v ne ""} {incr s [expr {$v * $m}]}
        }
    }
    return $s
}

proc ::youtube::clock_str {s} {
    if {$s >= 3600} {
        return [format "%d:%02d:%02d" [expr {$s / 3600}] [expr {$s % 3600 / 60}] [expr {$s % 60}]]
    }
    format "%d:%02d" [expr {$s / 60}] [expr {$s % 60}]
}

# 1234 -> 1.2K, 5600000 -> 5.6M
proc ::youtube::short_num {n} {
    if {![string is wideinteger -strict $n]} {return $n}
    foreach {lim suf} {1000000000 B 1000000 M 1000 K} {
        if {$n >= $lim} {
            set v [expr {double($n) / $lim}]
            set f [format [expr {$v < 10 ? "%.1f" : "%.0f"}] $v]
            regsub {\.0$} $f "" f
            return $f$suf
        }
    }
    return $n
}

proc ::youtube::ago {iso} {
    if {[catch {clock scan $iso -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1} t]} {return ""}
    set d [expr {[clock seconds] - $t}]
    set future [expr {$d < 0}]
    set d [expr {abs($d)}]
    set txt "moments"
    foreach {secs unit} {31536000 year 2592000 month 604800 week 86400 day 3600 hour 60 minute} {
        if {$d >= $secs} {
            set n [expr {$d / $secs}]
            set txt "$n $unit[expr {$n == 1 ? "" : "s"}]"
            break
        }
    }
    expr {$future ? "in $txt" : "$txt ago"}
}

# --------------------------- FETCHING ---------------------------

# Gets info for a video and calls {*}$callback $info  (dict, or "" if unavailable)
proc ::youtube::video {id callback} {
    variable cache
    variable key
    if {[info exists cache($id)] && [lindex $cache($id) 0] > [clock seconds]} {
        {*}$callback [lindex $cache($id) 1]
        return
    }
    if {$key ne ""} {
        set q [list part snippet,contentDetails,statistics,liveStreamingDetails,status id $id key $key]
        ::web::get "https://www.googleapis.com/youtube/v3/videos?[::web::query {*}$q]" \
            [list ::youtube::api_done $id $callback]
    } else {
        set url "https://www.youtube.com/watch?v=$id"
        ::web::get "https://www.youtube.com/oembed?[::web::query format json url $url]" \
            [list ::youtube::oembed_done $id $callback]
    }
}

proc ::youtube::remember {id info} {
    variable cache
    variable cache_mins
    # Live streams change fast: cache them briefly
    set mins [expr {[dict exists $info live] && [dict get $info live] ne "" ? 2 : $cache_mins}]
    set cache($id) [list [expr {[clock seconds] + $mins * 60}] $info]
}

proc ::youtube::api_done {id callback ok code body} {
    variable region
    if {!$ok || [catch {::web::json $body} d]} {
        if {$code == 403} {putlog "youtube: API key rejected or quota exhausted (HTTP 403)"}
        {*}$callback ""
        return
    }
    set it [lindex [::web::dget $d items] 0]
    if {$it eq ""} {{*}$callback ""; return}
    set sn [::web::dget $it snippet]
    set cd [::web::dget $it contentDetails]
    set st [::web::dget $it statistics]
    set ls [::web::dget $it liveStreamingDetails]
    set live ""
    switch -- [::web::dget $sn liveBroadcastContent] {
        live     {set live live}
        upcoming {set live upcoming}
    }
    set blocked 0
    if {$region ne ""} {
        set rr [::web::dget $cd regionRestriction]
        if {[string toupper $region] in [::web::dget $rr blocked] ||
            ([llength [::web::dget $rr allowed]] && [string toupper $region] ni [::web::dget $rr allowed])} {
            set blocked 1
        }
    }
    set info [dict create id $id title [::web::dget $sn title] channel [::web::dget $sn channelTitle] \
        duration [iso_duration [::web::dget $cd duration]] views [::web::dget $st viewCount] \
        likes [::web::dget $st likeCount] comments [::web::dget $st commentCount] \
        published [::web::dget $sn publishedAt] hd [string equal [::web::dget $cd definition] hd] \
        age [string equal [::web::dget $cd contentRating ytRating] ytAgeRestricted] \
        live $live watching [::web::dget $ls concurrentViewers] \
        scheduled [::web::dget $ls scheduledStartTime] blocked $blocked dislikes ""]
    remember $id $info
    {*}$callback $info
}

proc ::youtube::oembed_done {id callback ok code body} {
    variable dislikes
    if {!$ok || [catch {::web::json $body} d]} {{*}$callback ""; return}
    set info [dict create id $id title [::web::dget $d title] channel [::web::dget $d author_name] \
        duration 0 views "" likes "" comments "" published "" hd 0 age 0 live "" \
        watching "" scheduled "" blocked 0 dislikes ""]
    if {!$dislikes} {
        remember $id $info
        {*}$callback $info
        return
    }
    ::web::get "https://returnyoutubedislikeapi.com/votes?[::web::query videoId $id]" \
        [list ::youtube::ryd_done $id $info $callback]
}

proc ::youtube::ryd_done {id info callback ok code body} {
    if {$ok && ![catch {::web::json $body} d]} {
        dict set info views [::web::dget $d viewCount]
        dict set info likes [::web::dget $d likes]
        dict set info dislikes [::web::dget $d dislikes]
    }
    remember $id $info
    {*}$callback $info
}

proc ::youtube::playlist {id callback} {
    variable key
    if {$key eq ""} {
        # oEmbed also knows playlists (title + author only)
        set url "https://www.youtube.com/playlist?list=$id"
        ::web::get "https://www.youtube.com/oembed?[::web::query format json url $url]" \
            [list ::youtube::pl_oembed_done $id $callback]
        return
    }
    ::web::get "https://www.googleapis.com/youtube/v3/playlists?[::web::query part snippet,contentDetails id $id key $key]" \
        [list ::youtube::pl_api_done $id $callback]
}

proc ::youtube::pl_api_done {id callback ok code body} {
    set it ""
    if {$ok && ![catch {::web::json $body} d]} {set it [lindex [::web::dget $d items] 0]}
    if {$it eq ""} {{*}$callback ""; return}
    {*}$callback [dict create title [::web::dget $it snippet title] \
        channel [::web::dget $it snippet channelTitle] count [::web::dget $it contentDetails itemCount]]
}

proc ::youtube::pl_oembed_done {id callback ok code body} {
    if {!$ok || [catch {::web::json $body} d]} {{*}$callback ""; return}
    {*}$callback [dict create title [::web::dget $d title] channel [::web::dget $d author_name] count ""]
}

# ----------------------------- OUTPUT -----------------------------

#   YouTube :: Title (Channel: x | Duration: 3:33 | Views: 1.6B | ...)
proc ::youtube::format_video {info type start {url ""}} {
    variable region
    dict with info {}
    set f {}
    switch -- $live {
        live     {set tag "YouTube LIVE"}
        upcoming {set tag "YouTube Premiere"}
        default  {set tag [expr {$type eq "short" ? "YouTube Shorts" : "YouTube"}]}
    }
    if {$channel ne ""} {lappend f [::web::lbl Channel $channel]}
    if {$live eq "live"} {
        if {$watching ne ""} {lappend f [::web::lbl Watching [short_num $watching]]}
    } elseif {$live eq "upcoming"} {
        if {$scheduled ne ""} {lappend f [::web::lbl Starts [ago $scheduled]]}
    } else {
        if {$duration > 0} {
            set d [clock_str $duration]
            if {$start > 0 && $start < $duration} {append d " (from [clock_str $start])"}
            lappend f [::web::lbl Duration $d]
        }
        if {$views ne ""} {lappend f [::web::lbl Views [short_num $views]]}
    }
    if {$likes ne ""} {lappend f [::web::lbl Likes [short_num $likes]]}
    if {$dislikes ne ""} {lappend f [::web::lbl Dislikes [short_num $dislikes]]}
    if {$comments ne ""} {lappend f [::web::lbl Comments [short_num $comments]]}
    if {$published ne "" && $live eq ""} {lappend f [::web::lbl Published [ago $published]]}
    set tags {}
    if {$hd} {lappend tags HD}
    if {$age} {lappend tags "\0030418+\003"}
    if {$blocked} {lappend tags "\00304blocked in [string toupper $region]\003"}
    if {[llength $tags]} {lappend f [join $tags " "]}
    if {$url ne ""} {lappend f $url}
    ::web::line $tag $title $f
}

proc ::youtube::show_video {target type start withurl info} {
    if {$info eq ""} {
        ::web::say $target [::web::msg YouTube "Video unavailable (private, deleted or wrong link)."]
        return
    }
    set u ""
    if {$withurl} {
        set u "https://youtu.be/[dict get $info id]"
        if {$start > 0} {append u "?t=$start"}
    }
    ::web::say $target [format_video $info $type $start $u]
}

proc ::youtube::show_playlist {target info} {
    if {$info eq ""} {
        ::web::say $target [::web::msg YouTube "Playlist unavailable."]
        return
    }
    set f {}
    if {[dict get $info channel] ne ""} {lappend f [::web::lbl Channel [dict get $info channel]]}
    if {[dict get $info count] ne ""} {lappend f [::web::lbl Videos [dict get $info count]]}
    ::web::say $target [::web::line "YouTube Playlist" [dict get $info title] $f]
}

proc ::youtube::handle {target url withurl} {
    set p [parse_url $url]
    if {$p eq ""} {return 0}
    lassign $p type id start
    if {$type eq "playlist"} {
        playlist $id [list ::youtube::show_playlist $target]
    } else {
        video $id [list ::youtube::show_video $target $type $start $withurl]
    }
    return 1
}

# ------------------------------ EVENTS ------------------------------

# Other scripts (urltitle.tcl) ask this before handling a URL
proc ::youtube::wants {chan url} {
    expr {[channel get $chan youtube] && [parse_url $url] ne ""}
}

bind pubm - * ::youtube::on_pubm
proc ::youtube::on_pubm {nick uhost hand chan text} {
    variable cooldown
    variable repeat_mins
    variable maxlinks
    variable ignore_nicks
    variable seenvid
    variable show_url_on_paste
    if {![channel get $chan youtube] || [isbotnick $nick] || [string match !yt* $text]} return
    if {[lsearch -exact -nocase $ignore_nicks $nick] >= 0 || [matchattr $hand b]} return
    set urls [regexp -all -inline -nocase {(?:https?://)?(?:www\.|m\.|music\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/[^\s<>\"']+} [stripcodes bcruag $text]]
    if {![llength $urls]} return
    set c [string tolower $chan]
    set now [clock seconds]
    if {[::web::throttle "yt,$c" $cooldown]} return
    set n 0
    foreach url $urls {
        set p [parse_url $url]
        if {$p eq ""} continue
        set k "$c,[lindex $p 1]"
        if {[info exists seenvid($k)] && $now - $seenvid($k) < $repeat_mins * 60} continue
        set seenvid($k) $now
        handle $chan $url $show_url_on_paste
        if {[incr n] >= $maxlinks} break
    }
}

bind pub - !yt ::youtube::cmd_yt
bind pub - !youtube ::youtube::cmd_yt
proc ::youtube::cmd_yt {nick uhost hand chan text} {
    variable key
    variable search_throttle
    if {![channel get $chan youtube]} {return 0}
    set q [string trim $text]
    if {$q eq ""} {
        ::web::say $chan [::web::msg YouTube "Usage: [::web::b !yt] <search terms | link>"]
        return 0
    }
    if {[::web::throttle "yts,[lindex [split $uhost @] end]" $search_throttle]} {return 0}
    # A link or a bare video id
    if {[handle $chan $q 1]} {return 1}
    if {[regexp {^[A-Za-z0-9_-]{11}$} $q] && ![regexp {^[a-z]+$} $q]} {
        video $q [list ::youtube::show_video $chan video 0 1]
        return 1
    }
    if {$key eq ""} {
        ::web::say $chan [::web::msg YouTube "Searching needs a YouTube API key (set ::youtube::key). Paste a link instead."]
        return 0
    }
    set p [list part snippet type video maxResults 1 safeSearch moderate q $q key $key]
    ::web::get "https://www.googleapis.com/youtube/v3/search?[::web::query {*}$p]" \
        [list ::youtube::search_done $chan $q]
    return 1
}

proc ::youtube::search_done {chan q ok code body} {
    set id ""
    if {$ok && ![catch {::web::json $body} d]} {
        set id [::web::dget [lindex [::web::dget $d items] 0] id videoId]
    }
    if {$id eq ""} {
        ::web::say $chan [::web::msg YouTube "No results for \"$q\"[expr {$code == 403 ? " (API quota exhausted)" : ""}]."]
        return
    }
    video $id [list ::youtube::show_video $chan video 0 1]
}

proc ::youtube::housekeeping {} {
    variable cache
    variable seenvid
    variable repeat_mins
    set now [clock seconds]
    foreach id [array names cache] {
        if {[lindex $cache($id) 0] < $now} {unset cache($id)}
    }
    foreach k [array names seenvid] {
        if {$now - $seenvid($k) > $repeat_mins * 60} {unset seenvid($k)}
    }
    timer 15 ::youtube::housekeeping
}

apply {{} {
    foreach t [timers] {
        if {[string match ::youtube::* [lindex $t 1]]} {killtimer [lindex $t 2]}
    }
}}
timer 15 ::youtube::housekeeping

putlog "youtube.tcl loaded ([expr {$::youtube::key ne "" ? "Data API v3" : "key-free: oEmbed + Return YouTube Dislike"}])"
