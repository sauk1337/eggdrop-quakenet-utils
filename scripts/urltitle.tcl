# =====================================================================
#  urltitle.tcl  v1.2.0  -  Titles of links pasted on the channel
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Answers "Title :: page title (Site: host)" for pasted links. Follows redirects,
#    detects the charset, decodes HTML entities and prefers og:title.
#    Only downloads what it needs and only HTML. Never fetches private or
#    local IPs (SSRF protection). Per-channel cooldown, no repeats.
#    YouTube links go to youtube.tcl when the channel is +youtube.
#
#  REQUIREMENTS
#    web.tcl (output style; load it first), tcl-tls for https:// links
#
#  SETUP
#    .chanset #chan +urltitle
#
#  COMMANDS
#    none (automatic)
# =====================================================================

package require http

namespace eval ::urltitle {
    # ------------------------- CONFIGURATION -------------------------
    variable maxurls 2               ;# max URLs per line
    variable maxsize 262144          ;# max bytes to read
    variable timeout 8000            ;# ms
    variable maxredirs 4
    variable cooldown 4              ;# seconds between titles on a channel
    variable repeat_mins 10          ;# don't repeat the same URL within X minutes
    variable maxlen 200              ;# max title length
    variable ignore_domains {*.onion *.local localhost}
    variable ignore_nicks {Q L}      ;# e.g. other bots
    # Custom line, e.g. "\[ %title% \] - %host%". Empty = shared style:
    #   Title :: page title (Site: host)
    variable format ""
    variable useragent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    # --------------------- STATE (do not touch) ---------------------
    variable seq
    variable req
    variable lastchan
    variable seenurl
    if {![info exists seq]} {set seq 0}
}

setudef flag urltitle

# The User-Agent is global to the http package (it also applies to the
# other scripts); a browser-like one gets proper titles from more sites.
::http::config -useragent $::urltitle::useragent

if {![catch {package require tls}]} {
    if {[package vsatisfies [package present tls] 1.7-]} {
        ::http::register https 443 [list ::tls::socket -autoservername true]
    } else {
        ::http::register https 443 ::tls::socket
    }
} else {
    putlog "urltitle: WARNING - tcl-tls missing, only http:// URLs will work"
}

proc ::urltitle::is_private {ip} {
    if {[string first : $ip] >= 0} {
        set ip [string tolower $ip]
        return [expr {$ip eq "::1" || $ip eq "::" || [string match fe80:* $ip] ||
                      [string match fc* $ip] || [string match fd* $ip] || [string match ::ffff:* $ip]}]
    }
    lassign [split $ip .] a b
    set a [scan $a %d]
    set b [scan $b %d]
    expr {$a == 0 || $a == 10 || $a == 127 || $a >= 224 || ($a == 169 && $b == 254) ||
          ($a == 172 && $b >= 16 && $b <= 31) || ($a == 192 && $b == 168) ||
          ($a == 100 && $b >= 64 && $b <= 127)}
}

proc ::urltitle::is_ip {s} {
    expr {[regexp {^\d{1,3}(\.\d{1,3}){3}$} $s] || ([regexp {^[0-9A-Fa-f:]+$} $s] && [string first : $s] >= 0)}
}

bind pubm - * ::urltitle::on_pubm
proc ::urltitle::on_pubm {nick uhost hand chan text} {
    variable maxurls
    variable cooldown
    variable repeat_mins
    variable ignore_nicks
    variable lastchan
    variable seenurl
    if {![channel get $chan urltitle] || [isbotnick $nick]} return
    if {[lsearch -exact -nocase $ignore_nicks $nick] >= 0 || [matchattr $hand b]} return
    set c [string tolower $chan]
    set now [clock seconds]
    if {[info exists lastchan($c)] && $now - $lastchan($c) < $cooldown} return

    set n 0
    foreach url [regexp -all -inline -nocase {(?:https?://|www\.)[^\s<>\"']+} [stripcodes bcruag $text]] {
        # Strip trailing punctuation; ")" only if the URL has no "(" (Wikipedia)
        set url [string trimright $url ".,;:!?\]'\""]
        if {[string index $url end] eq ")" && [string first ( $url] < 0} {
            set url [string range $url 0 end-1]
        }
        if {[string match -nocase www.* $url]} {set url "http://$url"}
        # youtube.tcl gives richer info for YouTube links
        if {[namespace exists ::youtube] && [::youtube::wants $chan $url]} continue
        set k "$c,$url"
        if {[info exists seenurl($k)] && $now - $seenurl($k) < $repeat_mins * 60} continue
        set seenurl($k) $now
        set lastchan($c) $now
        start $chan $url
        if {[incr n] >= $maxurls} break
    }
}

proc ::urltitle::start {chan url} {
    variable seq
    variable req
    set id [incr seq]
    set req($id) [dict create chan $chan url $url orig $url redirs 0]
    resolve $id
}

# Checks the host (ignore list + non-private IP) and starts the download
proc ::urltitle::resolve {id} {
    variable req
    variable ignore_domains
    set url [dict get $req($id) url]
    if {![regexp -nocase {^https?://([^/:?#]+)} $url -> host]} {
        unset req($id)
        return
    }
    set host [string tolower $host]
    foreach p $ignore_domains {
        if {[string match $p $host]} {unset req($id); return}
    }
    dict set req($id) host $host
    if {[is_ip $host]} {
        resolved $host $host 1 $id
    } else {
        dnslookup $host ::urltitle::resolved $id
    }
}

proc ::urltitle::resolved {ip host status id} {
    variable req
    if {![info exists req($id)]} return
    if {!$status || [is_private $ip]} {
        if {$status} {putlog "urltitle: blocked URL pointing to a private IP ($host -> $ip)"}
        unset req($id)
        return
    }
    fetch $id
}

proc ::urltitle::fetch {id} {
    variable req
    variable timeout
    set url [dict get $req($id) url]
    # YouTube: oEmbed returns JSON with the title without fetching the page
    if {[regexp -nocase {^https?://(?:www\.|m\.|music\.)?(?:youtube\.com/(?:watch|shorts/|live/)|youtu\.be/)} $url]} {
        dict set req($id) yt 1
        set url "https://www.youtube.com/oembed?[::http::formatQuery format json url $url]"
    }
    set hdrs [list Accept "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.5" \
        Accept-Language "en-US,en;q=0.9" Accept-Encoding identity]
    if {[catch {
        ::http::geturl $url -timeout $timeout -binary 1 -strict 0 -headers $hdrs \
            -blocksize 8192 -progress ::urltitle::progress \
            -command [list ::urltitle::done $id]
    } err]} {
        putlog "urltitle: $url: $err"
        unset -nocomplain req($id)
    }
}

# Aborts the download if it isn't HTML/JSON or is too large
proc ::urltitle::progress {tok total current} {
    variable maxsize
    upvar #0 $tok state
    # http 2.9 can call -progress once more after the request completed
    if {![info exists state(type)] || $state(status) ne ""} return
    set type [string tolower [lindex [split $state(type) ";"] 0]]
    if {$type ne "" && ![string match *html* $type] && ![string match *json* $type]} {
        ::http::reset $tok nothtml
    } elseif {$current > $maxsize} {
        ::http::reset $tok toolarge
    }
}

proc ::urltitle::header {tok name} {
    foreach {k v} [::http::meta $tok] {
        if {[string equal -nocase $k $name]} {return $v}
    }
    return ""
}

proc ::urltitle::done {id tok} {
    variable req
    variable maxredirs
    if {![info exists req($id)]} {::http::cleanup $tok; return}
    set status [::http::status $tok]
    set code [::http::ncode $tok]
    set body [::http::data $tok]
    set ctype [header $tok Content-Type]
    set location [header $tok Location]
    ::http::cleanup $tok

    if {$code in {301 302 303 307 308} && $location ne ""} {
        if {[dict get $req($id) redirs] >= $maxredirs} {unset req($id); return}
        dict incr req($id) redirs
        dict set req($id) url [absurl [dict get $req($id) url] $location]
        resolve $id
        return
    }
    set r $req($id)
    unset req($id)
    if {$status ni {ok toolarge} || $code != 200} return

    if {[dict exists $r yt]} {
        set title [json_str $body title]
        set author [json_str $body author_name]
        if {$author ne ""} {append title " | $author"}
        set host "youtube.com"
    } else {
        set title [extract_title [decode $body $ctype]]
        set host [dict get $r host]
    }
    if {$title ne ""} {output [dict get $r chan] $title $host}
}

proc ::urltitle::absurl {base loc} {
    if {[regexp -nocase {^https?://} $loc]} {return $loc}
    regexp -nocase {^(https?://[^/?#]+)([^?#]*)} $base -> root path
    if {[string match //* $loc]} {return "[lindex [split $root :] 0]:$loc"}
    if {[string match /* $loc]} {return "$root$loc"}
    set dir [string range $path 0 [string last / $path]]
    if {$dir eq ""} {set dir /}
    return "$root$dir$loc"
}

# Converts the bytes using the right charset (HTTP header or <meta>)
proc ::urltitle::decode {body ctype} {
    set cs ""
    regexp -nocase {charset=["']?([\w-]+)} $ctype -> cs
    if {$cs eq ""} {
        regexp -nocase {<meta[^>]+charset=["']?([\w-]+)} [string range $body 0 4096] -> cs
    }
    set cs [string tolower $cs]
    set map {utf8 utf-8 latin1 iso8859-1 iso-8859-1 iso8859-1 iso-8859-15 iso8859-15
             windows-1252 cp1252 windows-1251 cp1251 shift_jis shiftjis euc-jp euc-jp}
    if {[dict exists $map $cs]} {set cs [dict get $map $cs]}
    if {$cs eq "" || $cs ni [encoding names]} {set cs utf-8}
    if {[catch {encoding convertfrom $cs $body} txt]} {set txt $body}
    return $txt
}

proc ::urltitle::extract_title {html} {
    set t ""
    if {![regexp -nocase {<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']} $html -> t] &&
        ![regexp -nocase {<meta[^>]+content=["']([^"']*)["'][^>]+property=["']og:title["']} $html -> t]} {
        regexp -nocase {<title[^>]*>(.*?)</title>} $html -> t
    }
    return [clean [entities $t]]
}

proc ::urltitle::json_str {json key} {
    set v ""
    regexp "\"$key\"\\s*:\\s*\"((?:\[^\"\\\\\]|\\\\.)*)\"" $json -> v
    # \uXXXX and simple escapes
    while {[regexp -indices {\\u([0-9a-fA-F]{4})} $v all hex]} {
        set ch [format %c 0x[string range $v {*}$hex]]
        set v [string replace $v {*}$all $ch]
    }
    set v [string map {\\/ / \\\" \" \\n " " \\t " " \\\\ \\} $v]
    return [clean $v]
}

proc ::urltitle::entities {s} {
    set s [string map {&amp; & &lt; < &gt; > &quot; \" &apos; ' &nbsp; " " &ndash; – &mdash; —
        &hellip; … &laquo; « &raquo; » &ldquo; “ &rdquo; ” &lsquo; ‘ &rsquo; ’ &euro; € &copy; ©
        &reg; ® &trade; ™ &middot; · &aacute; á &eacute; é &iacute; í &oacute; ó &uacute; ú
        &Aacute; Á &Eacute; É &Iacute; Í &Oacute; Ó &Uacute; Ú &ntilde; ñ &Ntilde; Ñ &uuml; ü
        &iexcl; ¡ &iquest; ¿ &ccedil; ç} $s]
    while {[regexp -indices {&#[xX]([0-9a-fA-F]{1,6});} $s all hex]} {
        set s [string replace $s {*}$all [format %c 0x[string range $s {*}$hex]]]
    }
    while {[regexp -indices {&#([0-9]{1,7});} $s all dec]} {
        set s [string replace $s {*}$all [format %c [scan [string range $s {*}$dec] %d]]]
    }
    return $s
}

proc ::urltitle::clean {s} {
    variable maxlen
    # Strip newlines and control codes (prevents IRC command injection)
    regsub -all {[\x00-\x1f\x7f]+} $s " " s
    regsub -all {\s+} [string trim $s] " " s
    if {[string length $s] > $maxlen} {set s "[string range $s 0 [expr {$maxlen - 4}]]..."}
    return $s
}

proc ::urltitle::output {chan title host} {
    variable format
    regsub {^www\.} $host "" host
    if {$format eq ""} {
        set line [::web::line Title $title [list [::web::lbl Site $host]]]
    } else {
        set line [string map [list %title% $title %host% $host] $format]
    }
    puthelp "PRIVMSG $chan :$line"
}

proc ::urltitle::housekeeping {} {
    variable seenurl
    variable repeat_mins
    set now [clock seconds]
    foreach k [array names seenurl] {
        if {$now - $seenurl($k) > $repeat_mins * 60} {unset seenurl($k)}
    }
    timer 15 ::urltitle::housekeeping
}

apply {{} {
    foreach t [timers] {
        if {[string match ::urltitle::* [lindex $t 1]]} {killtimer [lindex $t 2]}
    }
}}
timer 15 ::urltitle::housekeeping

putlog "urltitle.tcl loaded"
