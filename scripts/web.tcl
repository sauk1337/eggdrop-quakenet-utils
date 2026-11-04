# =====================================================================
#  web.tcl  v1.2.2  -  Shared HTTP, JSON and text helpers (library)
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Library used by ipinfo, utils, youtube, reminders, feeds, wiki,
#    dictionary, countdown and ask. No commands of its own. Every request
#    is asynchronous, so the bot never freezes waiting for a website.
#
#  REQUIREMENTS
#    tcl-tls for HTTPS: apt install tcl-tls
#    Load it before every script that uses it.
#
#  API
#    ::web::get url callback ?headers? ?timeout_ms?
#        GET, follows redirects:  {*}$callback ok code body  (ok = HTTP 200)
#    ::web::fetch url callback ?headers?
#        same, raw bytes + headers:  {*}$callback ok code body meta
#    ::web::post url json callback ?headers? ?timeout_ms?   JSON POST
#    ::web::json text           JSON -> Tcl dicts/lists (true/false -> 1/0)
#    ::web::json_raw text key   raw JSON of a top-level field
#    ::web::jstr s              Tcl string -> JSON string literal
#    ::web::dget dict key...    dict get, "" if the path is missing
#    ::web::query k v ...       URL-encoded query string
#    ::web::unhtml s | ::web::entities s | ::web::trim s n
#    ::web::throttle key secs   1 if the key was used less than secs ago
#    ::web::say target text ?queue?
#        PRIVMSG (or "notice:nick"), split at 400 bytes. queue: help
#        (default, slowest), serv, quick, or now (sent at once, for a
#        short answer someone is waiting for)
#
#  OUTPUT STYLE (shared by every script, so the bot looks the same everywhere)
#    YouTube :: Title (Channel: x | Views: 6.7M | Likes: 36K)
#    ::web::tag name            orange bold name           "YouTube"
#    ::web::b text              bold
#    ::web::lbl label value     blue "label:" + value      "Views: 6.7M"
#    ::web::sep                 orange " | "
#    ::web::dim text            grey (secondary details)
#    ::web::fields list         join non-empty items with ::web::sep
#    ::web::line tag title ?fields?   tag :: title (field | field)
#    ::web::msg tag text        tag :: text (errors, short answers)
#    Colours live in ::web::style, so they can be changed in one place.
# =====================================================================

package require http

namespace eval ::web {
    variable timeout 10000           ;# ms
    variable last
    # mIRC colour numbers: 07 orange, 12 light blue, 14 grey
    variable style
    array set style {tag 07 label 12 sep 07 dim 14}
}

# ----------------------------- STYLE -----------------------------

proc ::web::tag {name} {
    variable style
    return "\003$style(tag)\002$name\002\003"
}

proc ::web::b {text} {
    return "\002$text\002"
}

proc ::web::lbl {label value} {
    variable style
    return "\003$style(label)$label:\003 $value"
}

proc ::web::sep {} {
    variable style
    return " \003$style(sep)|\003 "
}

proc ::web::dim {text} {
    variable style
    return "\003$style(dim)$text\003"
}

proc ::web::fields {list} {
    set keep {}
    foreach f $list {
        if {$f ne ""} {lappend keep $f}
    }
    return [join $keep [sep]]
}

proc ::web::line {tag title {fields {}}} {
    set out "[tag $tag] :: [b $title]"
    set f [::web::fields $fields]
    if {$f ne ""} {append out " ($f)"}
    return $out
}

proc ::web::msg {tag text} {
    return "[tag $tag] :: $text"
}

if {[catch {package require tls}]} {
    putlog "web: WARNING - tcl-tls missing, HTTPS APIs will fail (apt install tcl-tls)"
} elseif {[package vsatisfies [package present tls] 1.7-]} {
    ::http::register https 443 [list ::tls::socket -autoservername true]
} else {
    ::http::register https 443 ::tls::socket
}

proc ::web::get {url callback {headers {}} {timeout 0}} {
    request GET $url "" $callback $headers $timeout 0
}

# Like get, but the callback also receives the response headers:
#   {*}$callback ok code body meta     (meta = dict, lower-case keys)
proc ::web::fetch {url callback {headers {}}} {
    request GET $url "" $callback $headers 0 1
}

# POST a JSON body (a Tcl string already encoded as JSON).
#   {*}$callback ok code body          (body is returned on errors too)
proc ::web::post {url json callback {headers {}} {timeout 0}} {
    request POST $url $json $callback $headers $timeout 0
}

proc ::web::request {method url body callback headers timeout_ms withmeta {redirs 0}} {
    variable timeout
    if {$timeout_ms <= 0} {set timeout_ms $timeout}
    if {[lsearch -exact -nocase $headers Accept-Encoding] < 0} {
        lappend headers Accept-Encoding identity
    }
    set opts [list -timeout $timeout_ms -strict 0 -headers $headers \
        -command [list ::web::done $method $url $body $callback $headers $timeout_ms $withmeta $redirs]]
    # fetch returns raw bytes: the caller decodes them (feeds declare
    # their encoding inside the XML, which the http package can't see)
    if {$withmeta} {lappend opts -binary 1}
    if {$method eq "POST"} {
        # http sends the query as raw bytes: encode to UTF-8 first
        lappend opts -query [encoding convertto utf-8 $body] -type "application/json; charset=utf-8"
    }
    if {[catch {::http::geturl $url {*}$opts} err]} {
        putlog "web: $url: $err"
        set args [list 0 0 ""]
        if {$withmeta} {lappend args {}}
        after idle [list {*}$callback {*}$args]
    }
}

proc ::web::done {method url body callback headers timeout_ms withmeta redirs tok} {
    set ok 0
    set code 0
    set data ""
    set meta [dict create]
    catch {
        set code [::http::ncode $tok]
        set data [::http::data $tok]
        set ok [expr {[::http::status $tok] eq "ok" && $code == 200}]
        foreach {k v} [::http::meta $tok] {dict set meta [string tolower $k] $v}
    }
    ::http::cleanup $tok
    # Follow redirects (rdap.org sends you to the right registry)
    set location [expr {[dict exists $meta location] ? [dict get $meta location] : ""}]
    if {$code in {301 302 303 307 308} && $location ne "" && $redirs < 4} {
        if {![regexp -nocase {^https?://} $location]} {
            regexp -nocase {^https?://[^/]+} $url root
            set location "$root$location"
        }
        request $method $location $body $callback $headers $timeout_ms $withmeta [incr redirs]
        return
    }
    set args [list $ok $code $data]
    if {$withmeta} {lappend args $meta}
    if {[catch {{*}$callback {*}$args} err]} {
        putlog "web: callback error: $err"
    }
}

proc ::web::query {args} {
    ::http::formatQuery {*}$args
}

proc ::web::dget {d args} {
    foreach k $args {
        if {[catch {dict exists $d $k} e] || !$e} {return ""}
        set d [dict get $d $k]
    }
    return $d
}

proc ::web::throttle {key secs} {
    variable last
    set now [clock seconds]
    if {[info exists last($key)] && $now - $last($key) < $secs} {return 1}
    set last($key) $now
    return 0
}

# Typographic punctuation from websites -> ASCII, so old mIRC versions
# (no UTF-8) don't show it as garbage. Letters with accents are kept.
# Set ::web::ascii_punct 0 to send everything untouched.
namespace eval ::web {variable ascii_punct 1}
proc ::web::ascii {text} {
    if {!$::web::ascii_punct || ![regexp {[^\x00-\x7f]} $text]} {return $text}
    string map [list \u2013 - \u2014 - \u2015 - \u2026 ... \u201c \" \u201d \" \u201e \" \
        \u2018 ' \u2019 ' \u201a ' \u00ab \" \u00bb \" \u00b7 - \u2022 - \u00a0 " " \
        \u2009 " " \u200b "" \u2122 (TM)] $text
}

# putnow skips Eggdrop's flood control, so it is capped here: at most
# now_burst lines every now_window seconds, the rest go by putquick.
namespace eval ::web {
    variable now_burst 4
    variable now_window 4
    variable now_sent {}
}
proc ::web::putnow {line} {
    variable now_burst
    variable now_window
    variable now_sent
    set t [clock seconds]
    set keep {}
    foreach s $now_sent {if {$t - $s < $now_window} {lappend keep $s}}
    set now_sent $keep
    if {[info commands ::putnow] ne "" && [llength $now_sent] < $now_burst} {
        lappend now_sent $t
        ::putnow $line
    } else {
        putquick $line
    }
}

# Sends text to a channel or nick; "notice:nick" sends a NOTICE.
# Long text is split on spaces at ~400 bytes (IRC line limit).
proc ::web::say {target text {queue help}} {
    set cmd PRIVMSG
    if {[string match notice:* $target]} {
        set cmd NOTICE
        set target [string range $target 7 end]
    }
    switch -- $queue {
        now     {set put ::web::putnow}
        quick   {set put putquick}
        serv    {set put putserv}
        default {set put puthelp}
    }
    regsub -all {[\r\n]+} $text " " text
    set text [ascii $text]
    while {[string length $text] > 400} {
        set cut [string last " " $text 400]
        if {$cut < 100} {set cut 400}
        $put "$cmd $target :[string range $text 0 [expr {$cut - 1}]]"
        set text [string trimleft [string range $text $cut end]]
    }
    if {$text ne ""} {$put "$cmd $target :$text"}
}

# ----------------------------- JSON -----------------------------
# Small recursive-descent parser: objects -> dicts, arrays -> lists.

proc ::web::json {text} {
    set i 0
    set v [jvalue $text i]
    return $v
}

proc ::web::jskip {s iv} {
    upvar 1 $iv i
    while {[string is space -strict [string index $s $i]]} {incr i}
}

proc ::web::jvalue {s iv} {
    upvar 1 $iv i
    jskip $s i
    set c [string index $s $i]
    switch -- $c {
        "\{" {
            incr i
            set d [dict create]
            jskip $s i
            if {[string index $s $i] eq "\}"} {incr i; return $d}
            while 1 {
                jskip $s i
                set k [jstring $s i]
                jskip $s i
                if {[string index $s $i] ne ":"} {error "JSON: ':' expected at $i"}
                incr i
                dict set d $k [jvalue $s i]
                jskip $s i
                set c [string index $s $i]
                incr i
                if {$c eq "\}"} {return $d}
                if {$c ne ","} {error "JSON: ',' or '\}' expected at $i"}
            }
        }
        "\[" {
            incr i
            set l {}
            jskip $s i
            if {[string index $s $i] eq "\]"} {incr i; return $l}
            while 1 {
                lappend l [jvalue $s i]
                jskip $s i
                set c [string index $s $i]
                incr i
                if {$c eq "\]"} {return $l}
                if {$c ne ","} {error "JSON: ',' or '\]' expected at $i"}
            }
        }
        "\"" {
            return [jstring $s i]
        }
        default {
            if {![regexp {^(?:-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false|null)} \
                    [string range $s $i [expr {$i + 40}]] m]} {
                error "JSON: unexpected character at $i"
            }
            incr i [string length $m]
            return [string map {true 1 false 0 null ""} $m]
        }
    }
}

proc ::web::jstring {s iv} {
    upvar 1 $iv i
    if {[string index $s $i] ne "\""} {error "JSON: string expected at $i"}
    set j [expr {$i + 1}]
    while 1 {
        set q [string first "\"" $s $j]
        if {$q < 0} {error "JSON: unterminated string"}
        # Count the backslashes before the quote
        set b 0
        while {[string index $s [expr {$q - $b - 1}]] eq "\\"} {incr b}
        if {$b % 2 == 0} break
        set j [expr {$q + 1}]
    }
    set raw [string range $s [expr {$i + 1}] [expr {$q - 1}]]
    set i [expr {$q + 1}]
    if {[string first "\\" $raw] < 0} {return $raw}
    # Tcl's own backslash rules match JSON's (\n \t \" \\ \/ \uXXXX)
    return [subst -nocommands -novariables $raw]
}

# JSON string literal from a Tcl string (quotes included)
proc ::web::jstr {s} {
    set map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"]
    set s [string map $map $s]
    # Remaining control characters
    while {[regexp -indices {[\x00-\x1f]} $s r]} {
        set c [string index $s [lindex $r 0]]
        set s [string replace $s {*}$r [format "\\u%04x" [scan $c %c]]]
    }
    return "\"$s\""
}

# Raw JSON text of a top-level field, byte for byte (used to send an API
# response back unchanged, e.g. an assistant message's "content" array)
proc ::web::json_raw {text key} {
    set i 0
    jskip $text i
    if {[string index $text $i] ne "\{"} {return ""}
    incr i
    while 1 {
        jskip $text i
        if {[string index $text $i] eq "\}"} {return ""}
        set k [jstring $text i]
        jskip $text i
        incr i                       ;# the ':'
        jskip $text i
        set start $i
        jvalue $text i
        if {$k eq $key} {return [string range $text $start [expr {$i - 1}]]}
        jskip $text i
        if {[string index $text $i] eq ","} {incr i} else {return ""}
    }
}

# HTML -> plain text: drops tags, decodes entities, collapses whitespace
proc ::web::unhtml {s} {
    regsub -all {<!\[CDATA\[(.*?)\]\]>} $s {\1} s
    regsub -all -nocase {<(script|style)[^>]*>.*?</\1>} $s " " s
    regsub -all -nocase {<br\s*/?>|</p>|</li>|</div>} $s " " s
    regsub -all {<[^>]*>} $s "" s
    set s [entities $s]
    regsub -all {[\x00-\x1f\x7f]+} $s " " s
    regsub -all {\s+} [string trim $s] " " s
    return $s
}

proc ::web::entities {s} {
    if {[string first & $s] < 0} {return $s}
    set s [string map {&lt; < &gt; > &quot; \" &apos; ' &#39; ' &nbsp; " " &ndash; - &mdash; -
        &hellip; ... &laquo; \" &raquo; \" &ldquo; \" &rdquo; \" &lsquo; ' &rsquo; ' &euro; EUR &copy; (c)
        &reg; (R) &trade; (TM) &middot; - &aacute; á &eacute; é &iacute; í &oacute; ó &uacute; ú
        &Aacute; Á &Eacute; É &Iacute; Í &Oacute; Ó &Uacute; Ú &ntilde; ñ &Ntilde; Ñ &uuml; ü
        &iexcl; ¡ &iquest; ¿ &ccedil; ç &deg; ° &times; x &bull; -} $s]
    while {[regexp -indices {&#[xX]([0-9a-fA-F]{1,6});} $s all hex]} {
        set s [string replace $s {*}$all [format %c 0x[string range $s {*}$hex]]]
    }
    while {[regexp -indices {&#([0-9]{1,7});} $s all dec]} {
        set s [string replace $s {*}$all [format %c [scan [string range $s {*}$dec] %d]]]
    }
    string map {&amp; &} $s
}

# Cuts text to n characters on a word boundary, adding "..." (ASCII, so
# old mIRC versions show it right)
proc ::web::trim {s n} {
    if {[string length $s] <= $n} {return $s}
    set cut [string last " " $s $n]
    if {$cut < $n / 2} {set cut $n}
    return "[string trimright [string range $s 0 [expr {$cut - 1}]] " ,.;:"]..."
}

putlog "web.tcl loaded"
