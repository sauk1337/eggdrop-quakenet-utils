# =====================================================================
#  antiproxy.tcl  v1.2.2  -  Proxy / VPN / Tor detection on join
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Checks the IP of every user joining and decides by SCORE: each
#    method adds a weight, and at the threshold the bot acts.
#      1. DNSBL (DroneBL, EFnetRBL, dan.me.uk Tor)   async DNS
#      2. proxycheck.io (better with a free key)
#      3. ip-api.com (proxy / hosting / country)
#      4. Tor exit node list (check.torproject.org, refreshed every 6 h)
#      5. Reverse DNS heuristics (vpn, proxy, hosting...)
#    Results are cached; whitelist by mask or IP. Users with a
#    *.users.quakenet.org host (Q account + +x) hide their IP and are let
#    through; combine with channel mode +r for a fully verified channel.
#    BNC friendly: a "VPN"/datacenter IP alone doesn't reach the
#    threshold, and users authed with Q are let through even if their IP
#    scores as a proxy (allow_authed, checked with WHOX before acting).
#    Stricter on throwaway proxies: a bare IP with no reverse DNS that
#    already has datacenter/VPN hints gets an extra point (bare_ip_weight),
#    and a proxycheck.io "VPN" with a high risk score counts as a proxy.
#      BNC with a hostname, hosting + VPN        1 + 1     = 2  allowed
#      bare VPS IP, hosting + VPN                1 + 1 + 1 = 3  kickban
#      any IP flagged as a real proxy / Tor / DNSBL   3+        kickban
#
#  REQUIREMENTS
#    tcl-tls for HTTPS (proxycheck.io and the Tor list)
#    Works on its own; with web.tcl loaded it shares its colours.
#
#  SETUP
#    .chanset #chan +antiproxy         check on join: kickban | kick | warn
#    .chanset #chan +antiproxy-gate    for +i channels: invite after a check
#    Optional key in secrets.tcl:  set ::antiproxy::proxycheck_key "..."
#
#  COMMANDS
#    /msg <bot> enter #chan            ask for an invite (gate channels)
#    !pcheck <ip|host|nick>            check by hand (ops). A nick on a
#                                      +antiproxy channel is also kickbanned
#                                      if detected (unless authed with Q)
#    !pwhite add|del|list [mask]       whitelist (global o, by notice)
#    !pcache [clear]                   cache: blocked IPs / empty it (global o)
#    !pstats                           counters (ops)
#  PARTYLINE
#    .pcheck <ip|host|nick>  .pwhite add|del|list [mask]  .pcache [clear]  .pstats
# =====================================================================

package require http

# Output style. web.tcl provides it; when this script runs on its own,
# a minimal copy of the same helpers is defined here. If web.tcl is
# loaded later, it simply replaces them.
if {[info commands ::web::line] eq ""} {
    namespace eval ::web {
        variable style
        if {![array exists style]} {array set style {tag 07 label 12 sep 07 dim 14}}
    }
    proc ::web::tag {name} {return "\003$::web::style(tag)\002$name\002\003"}
    proc ::web::b {text} {return "\002$text\002"}
    proc ::web::lbl {label value} {return "\003$::web::style(label)$label:\003 $value"}
    proc ::web::sep {} {return " \003$::web::style(sep)|\003 "}
    proc ::web::dim {text} {return "\003$::web::style(dim)$text\003"}
    proc ::web::fields {list} {
        set keep {}
        foreach f $list {if {$f ne ""} {lappend keep $f}}
        return [join $keep [sep]]
    }
    proc ::web::line {tag title {fields {}}} {
        set out "[tag $tag] :: [b $title]"
        set f [fields $fields]
        if {$f ne ""} {append out " ($f)"}
        return $out
    }
    proc ::web::msg {tag text} {return "[tag $tag] :: $text"}
}

namespace eval ::antiproxy {
    # ------------------------- CONFIGURATION -------------------------

    # Score at which a user is considered a proxy.
    variable threshold 3

    # DNSBLs: {zone weight}. Any 127.x.x.x answer counts as a hit.
    # (Don't use zen.spamhaus.org with a public resolver: it blocks those queries.)
    variable dnsbls {
        {dnsbl.dronebl.org  3}
        {rbl.efnetrbl.org   3}
        {torexit.dan.me.uk  3}
    }

    # proxycheck.io  (no key: ~100 queries/day, free key: 1000/day)
    variable proxycheck 1
    variable proxycheck_key ""
    variable proxycheck_vpn 1        ;# 1 = VPNs count too
    variable proxycheck_weight 3     ;# open proxies, SOCKS, compromised hosts...
    # "VPN" also covers datacenter ranges, where BNCs and shells live:
    # alone it must not reach the threshold
    variable proxycheck_vpn_weight 1
    # proxycheck.io risk score (0-100): a "VPN" at or above this counts
    # as much as a real proxy (0 = ignore the risk score)
    variable proxycheck_risk 75

    # ip-api.com (free, HTTP only, max 45 queries/minute)
    variable ipapi 1
    variable ipapi_proxy_weight 3
    variable ipapi_hosting_weight 1  ;# datacenter/hosting: suspicious, not conclusive
    variable ipapi_maxpermin 40
    # Blocked countries (ISO codes, e.g. {CN RU}). Empty = none.
    variable country_block {}

    # Tor exit node list (downloaded and refreshed automatically)
    variable tor 1
    variable tor_url "https://check.torproject.org/torbulkexitlist"
    variable tor_weight 3
    variable tor_refresh 360         ;# minutes

    # Extra points for a bare IP (no reverse DNS shown on IRC) that already
    # has datacenter/VPN hints. BNCs and shells nearly always have a real
    # hostname (freakshells.net, xshellz.com...); throwaway VPS proxies don't.
    variable bare_ip_weight 1

    # Reverse DNS heuristics
    variable rdns 1
    variable rdns_weight 1
    variable rdns_patterns {
        *proxy* *vpn* *tor-exit* *torexit* *.tor.* *exit-node* *anonym*
        *.amazonaws.com *.googleusercontent.com *.cloud.* *.compute.*
        *.vultr.com *.linode.com *.linodeusercontent.com *.digitalocean.com
        *.ovh.net *.ip-*.eu *.your-server.de *.hetzner.* *.contabo.*
        *.leaseweb.* *.choopa.net *.m247.* *.datacamp* *.hosted-by-* *vps*
        *dedicated* *.colo* *hosting*
    }

    # What to do in +antiproxy mode: kickban | kick | warn (report only)
    variable action "kickban"
    variable bantime 120             ;# minutes (0 = permanent)
    variable kickmsg "Proxy/VPN/Tor not allowed (%reasons%). If this is a mistake, contact an op."

    # Bot users with these flags are not checked
    variable exempt_flags "fov|fov"

    # Users authed with Q are let through even if their IP scores as a
    # proxy (BNC users usually are). Checked with WHOX before acting.
    variable allow_authed 1

    # Channel where detections are reported (empty = log only)
    variable logchan ""

    # Cache (minutes)
    variable cache_clean 360
    variable cache_bad 1440

    variable http_timeout 8000       ;# ms
    variable datadir "antiproxy"     ;# relative to the bot directory

    # --------------------- STATE (do not touch) ---------------------
    variable seq
    variable checks
    variable cache
    variable torlist
    variable white
    variable gatelast
    variable stats
    variable ipapi_win
    variable ipapi_cnt
    if {![info exists seq]} {set seq 0}
    if {![info exists white]} {set white {}}
    if {![info exists ipapi_win]} {set ipapi_win 0; set ipapi_cnt 0}
    if {![array exists stats]} {array set stats {checked 0 blocked 0 clean 0 cached 0}}
}

setudef flag antiproxy
setudef flag antiproxy-gate

::http::config -useragent "Eggdrop-antiproxy/1.0"
if {[catch {package require tls}]} {
    putlog "antiproxy: WARNING - tls package (tcl-tls) missing: proxycheck.io and the Tor list will not work."
} elseif {[package vsatisfies [package present tls] 1.7-]} {
    ::http::register https 443 [list ::tls::socket -autoservername true]
} else {
    ::http::register https 443 ::tls::socket
}

# ----------------------------- HELPERS -----------------------------

# msg may carry colours (for the log channel); the bot log gets plain text
proc ::antiproxy::log {msg} {
    variable logchan
    regsub -all {\003(\d{1,2}(,\d{1,2})?)?|[\002\017\026\037]} $msg "" plain
    putlog "antiproxy: $plain"
    if {$logchan ne "" && [validchan $logchan] && [botonchan $logchan]} {
        puthelp "PRIVMSG $logchan :[::web::msg Antiproxy $msg]"
    }
}

# "Score: 3 | Reasons: a, b | UA ISP" for the log channel and !pcheck
proc ::antiproxy::details {score reasons {geo ""} {note ""}} {
    ::web::fields [list [::web::lbl Score $score] \
        [expr {[llength $reasons] ? [::web::lbl Reasons [join $reasons ", "]] : ""}] \
        [expr {$geo ne "" ? [::web::lbl Geo $geo] : ""}] \
        [expr {$note ne "" ? [::web::dim $note] : ""}]]
}

proc ::antiproxy::is_ipv4 {s} {
    if {![regexp {^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$} $s -> a b c d]} {return 0}
    foreach o [list $a $b $c $d] {
        if {[scan $o %d] > 255} {return 0}
    }
    return 1
}

proc ::antiproxy::is_ipv6 {s} {
    expr {[string first : $s] >= 0 && [regexp {^[0-9A-Fa-f:]+$} $s]}
}

proc ::antiproxy::is_ip {s} {
    expr {[is_ipv4 $s] || [is_ipv6 $s]}
}

proc ::antiproxy::is_private {ip} {
    if {![is_ipv4 $ip]} {
        set ip [string tolower $ip]
        return [expr {$ip eq "::1" || [string match fe80:* $ip] || [string match fc* $ip] || [string match fd* $ip]}]
    }
    lassign [split $ip .] a b
    set a [scan $a %d]
    set b [scan $b %d]
    expr {$a == 0 || $a == 10 || $a == 127 || ($a == 169 && $b == 254) ||
          ($a == 172 && $b >= 16 && $b <= 31) || ($a == 192 && $b == 168) ||
          ($a == 100 && $b >= 64 && $b <= 127)}
}

# Reversed IP for DNSBL lookups (IPv4 by octets, IPv6 by nibbles)
proc ::antiproxy::rev_ip {ip} {
    if {[is_ipv4 $ip]} {
        return [join [lreverse [split $ip .]] .]
    }
    set halves [split [string map {:: |} [string tolower $ip]] |]
    set left [lsearch -all -inline -not -exact [split [lindex $halves 0] :] ""]
    set right {}
    if {[llength $halves] > 1} {
        set right [lsearch -all -inline -not -exact [split [lindex $halves 1] :] ""]
    }
    set groups $left
    for {set i [expr {8 - [llength $left] - [llength $right]}]} {$i > 0} {incr i -1} {
        lappend groups 0
    }
    lappend groups {*}$right
    set hex ""
    foreach g $groups {
        append hex [format %04x [scan $g %x]]
    }
    return [join [lreverse [split $hex ""]] .]
}

# string match that treats the [ ] found in nicks as literal characters
proc ::antiproxy::wmatch {pattern str} {
    string match -nocase [string map {\\ \\\\ [ \\[ ] \\]} $pattern] $str
}

proc ::antiproxy::reply {to text} {
    lassign $to type dest
    switch -- $type {
        dcc    {
            regsub -all {\003(\d{1,2}(,\d{1,2})?)?|[\002\017\026\037]} $text "" text
            if {[valididx $dest]} {putdcc $dest $text}
        }
        chan   { puthelp "PRIVMSG $dest :$text" }
        notice { puthelp "NOTICE $dest :$text" }
    }
}

# ----------------------- CACHE AND WHITELIST -----------------------

proc ::antiproxy::cache_get {ip} {
    variable cache
    if {![info exists cache($ip)]} {return ""}
    lassign $cache($ip) expire verdict reasons score
    if {[clock seconds] > $expire} {
        unset cache($ip)
        return ""
    }
    return [list $verdict $reasons $score]
}

proc ::antiproxy::cache_put {ip verdict reasons score} {
    variable cache
    variable cache_clean
    variable cache_bad
    set mins [expr {$verdict eq "bad" ? $cache_bad : $cache_clean}]
    set cache($ip) [list [expr {[clock seconds] + $mins * 60}] $verdict $reasons $score]
}

proc ::antiproxy::white_load {} {
    variable white
    variable datadir
    set white {}
    set f [file join $datadir whitelist.txt]
    if {![file exists $f]} return
    set fd [open $f r]
    foreach line [split [read $fd] \n] {
        set line [string trim $line]
        if {$line ne "" && ![string match #* $line]} {lappend white $line}
    }
    close $fd
}

proc ::antiproxy::white_save {} {
    variable white
    variable datadir
    set fd [open [file join $datadir whitelist.txt] w]
    puts $fd "# antiproxy whitelist: one mask per line (nick!user@host or IP)"
    foreach m $white {puts $fd $m}
    close $fd
}

proc ::antiproxy::white_match {args} {
    variable white
    foreach m $white {
        foreach s $args {
            if {$s ne "" && [wmatch $m $s]} {return 1}
        }
    }
    return 0
}

# ----------------------------- ENGINE -----------------------------
# Each check is a dict in checks($id). "pending" counts the async
# queries in flight; when it reaches 0 the verdict is issued.

proc ::antiproxy::get {id key} {
    variable checks
    dict get $checks($id) $key
}

proc ::antiproxy::check {mode nick uhost chan {to ""}} {
    variable seq
    variable checks
    variable stats
    set id [incr seq]
    set host [lindex [split $uhost @] end]
    set checks($id) [dict create mode $mode nick $nick uhost $uhost chan $chan reply $to \
        host $host ip "" rdns "" geo "" note "" score 0 reasons {} pending 0 \
        decided 0 cached 0 nocache 0 bareip [is_ip $host]]
    incr stats(checked)

    if {[white_match "$nick!$uhost" $host]} {
        dict set checks($id) note "whitelisted"
        dict set checks($id) nocache 1
        finalize $id
    } elseif {[is_ip $host]} {
        begin $id $host
    } elseif {[string match -nocase *.users.quakenet.org $host]} {
        dict set checks($id) note "authed with Q and +x (hidden IP, cannot be checked)"
        dict set checks($id) nocache 1
        finalize $id
    } else {
        dict set checks($id) rdns $host
        dnslookup $host ::antiproxy::resolved $id
    }
    return $id
}

proc ::antiproxy::resolved {ip host status id} {
    variable checks
    if {![info exists checks($id)]} return
    if {!$status || ![is_ip $ip]} {
        dict set checks($id) note "could not resolve $host"
        dict set checks($id) nocache 1
        rdns_check $id
        finalize $id
        return
    }
    begin $id $ip
}

proc ::antiproxy::begin {id ip} {
    variable checks
    variable stats
    variable dnsbls
    variable tor
    variable torlist
    variable tor_weight
    variable proxycheck
    variable ipapi
    variable rdns

    dict set checks($id) ip $ip
    if {[is_private $ip]} {
        dict set checks($id) note "private/local IP"
        dict set checks($id) nocache 1
        finalize $id
        return
    }
    if {[white_match $ip]} {
        dict set checks($id) note "IP whitelisted"
        dict set checks($id) nocache 1
        finalize $id
        return
    }
    set c [cache_get $ip]
    if {$c ne ""} {
        incr stats(cached)
        lassign $c verdict reasons score
        dict set checks($id) cached 1
        dict set checks($id) score $score
        dict set checks($id) note "cached result"
        if {$verdict eq "bad"} {
            dict set checks($id) reasons $reasons
            decide_bad $id
        }
        finalize $id
        return
    }

    # Safety net in case a query never comes back
    utimer 30 [list ::antiproxy::settle $id]
    # "Guard": keeps the check open if a callback fires synchronously
    dict set checks($id) pending 1

    if {$tor && [info exists torlist($ip)]} {
        add $id $tor_weight "Tor exit node"
    }
    if {![get $id decided]} {
        set rev [rev_ip $ip]
        foreach entry $dnsbls {
            lassign $entry zone weight
            dict incr checks($id) pending
            dnslookup "$rev.$zone" ::antiproxy::dnsbl_done $id $zone $weight
        }
        if {$rdns} {
            if {[get $id rdns] ne ""} {
                rdns_check $id
            } else {
                dict incr checks($id) pending
                dnslookup $ip ::antiproxy::rdns_done $id
            }
        }
        if {$proxycheck} {
            dict incr checks($id) pending
            q_proxycheck $id $ip
        }
        if {$ipapi && [ipapi_allow]} {
            dict incr checks($id) pending
            q_ipapi $id $ip
        }
    }
    done $id
}

proc ::antiproxy::add {id weight reason} {
    variable checks
    variable threshold
    if {![info exists checks($id)]} return
    dict lappend checks($id) reasons "$reason +$weight"
    dict incr checks($id) score $weight
    if {![get $id decided] && [get $id score] >= $threshold} {
        decide_bad $id
    }
}

proc ::antiproxy::done {id} {
    variable checks
    if {![info exists checks($id)]} return
    dict incr checks($id) pending -1
    if {[get $id pending] <= 0} {settle $id}
}

# Every answer is in (or the safety net fired): apply the combined rules
# and take the final decision from the total score.
proc ::antiproxy::settle {id} {
    variable checks
    variable threshold
    variable bare_ip_weight
    if {![info exists checks($id)]} return
    if {![get $id decided]} {
        set score [get $id score]
        if {$bare_ip_weight > 0 && [get $id bareip] && $score > 0 && $score < $threshold} {
            add $id $bare_ip_weight "bare IP, no rDNS"
        }
        # add decides as soon as the threshold is reached; this second
        # check makes sure no path ends "clean" above the threshold
        if {![get $id decided] && [get $id score] >= $threshold} {decide_bad $id}
    }
    finalize $id
}

proc ::antiproxy::decide_bad {id} {
    variable checks
    variable stats
    dict set checks($id) decided 1
    incr stats(blocked)
    set c $checks($id)
    if {![dict get $c cached] && [dict get $c ip] ne ""} {
        cache_put [dict get $c ip] bad [dict get $c reasons] [dict get $c score]
    }
    if {[catch {act_bad $c} err]} {putlog "antiproxy: error in act_bad: $err"}
}

proc ::antiproxy::finalize {id} {
    variable checks
    variable stats
    if {![info exists checks($id)]} return
    set c $checks($id)
    unset checks($id)
    if {[dict get $c decided]} return
    incr stats(clean)
    if {![dict get $c cached] && ![dict get $c nocache] && [dict get $c ip] ne ""} {
        cache_put [dict get $c ip] clean [dict get $c reasons] [dict get $c score]
    }
    if {[catch {act_clean $c} err]} {putlog "antiproxy: error in act_clean: $err"}
}

# ----------------------------- METHODS -----------------------------

proc ::antiproxy::dnsbl_done {ip host status id zone weight} {
    variable checks
    if {![info exists checks($id)]} return
    if {$status && [string match 127.* $ip]} {
        add $id $weight "DNSBL $zone ($ip)"
    }
    done $id
}

proc ::antiproxy::rdns_done {ip host status id} {
    variable checks
    if {![info exists checks($id)]} return
    if {$status && $host ne "" && $host ne $ip} {
        dict set checks($id) rdns $host
        rdns_check $id
    }
    done $id
}

proc ::antiproxy::rdns_check {id} {
    variable rdns
    variable rdns_patterns
    variable rdns_weight
    if {!$rdns} return
    set h [get $id rdns]
    if {$h eq ""} return
    foreach p $rdns_patterns {
        if {[string match -nocase $p $h]} {
            add $id $rdns_weight "suspicious rDNS ($h)"
            return
        }
    }
}

proc ::antiproxy::http_get {url callback} {
    variable http_timeout
    if {[catch {::http::geturl $url -timeout $http_timeout \
            -command [list ::antiproxy::http_done $callback]} err]} {
        putlog "antiproxy: HTTP error ($url): $err"
        if {[catch {{*}$callback ""} e]} {putlog "antiproxy: $e"}
    }
}

proc ::antiproxy::http_done {callback tok} {
    set data ""
    if {[catch {
        if {[::http::status $tok] eq "ok" && [::http::ncode $tok] == 200} {
            set data [::http::data $tok]
        } else {
            putlog "antiproxy: HTTP failed: [::http::status $tok] [::http::code $tok] [::http::error $tok]"
        }
    } err]} {
        putlog "antiproxy: HTTP: $err"
    }
    ::http::cleanup $tok
    if {[catch {{*}$callback $data} e]} {putlog "antiproxy: error in callback: $e"}
}

proc ::antiproxy::q_proxycheck {id ip} {
    variable proxycheck_key
    variable proxycheck_vpn
    set url "https://proxycheck.io/v2/$ip?vpn=$proxycheck_vpn&asn=1&risk=1"
    if {$proxycheck_key ne ""} {append url "&key=$proxycheck_key"}
    http_get $url [list ::antiproxy::pc_done $id]
}

proc ::antiproxy::pc_done {id data} {
    variable checks
    variable proxycheck_weight
    variable proxycheck_vpn_weight
    variable proxycheck_risk
    if {![info exists checks($id)]} return
    if {[regexp {"status"\s*:\s*"(denied|error)"} $data]} {
        set msg ""
        regexp {"message"\s*:\s*"([^"]*)"} $data -> msg
        putlog "antiproxy: proxycheck.io: $msg"
    }
    if {[regexp {"proxy"\s*:\s*"yes"} $data]} {
        set type "proxy"
        regexp {"type"\s*:\s*"([^"]+)"} $data -> type
        set risk 0
        regexp {"risk"\s*:\s*"?(\d+)} $data -> risk
        set w $proxycheck_weight
        if {[string match -nocase *vpn* $type] && ($proxycheck_risk <= 0 || $risk < $proxycheck_risk)} {
            set w $proxycheck_vpn_weight
        }
        add $id $w "proxycheck.io: $type[expr {$risk > 0 ? " risk $risk" : ""}]"
    }
    done $id
}

proc ::antiproxy::ipapi_allow {} {
    variable ipapi_win
    variable ipapi_cnt
    variable ipapi_maxpermin
    set now [clock seconds]
    if {$now - $ipapi_win >= 60} {
        set ipapi_win $now
        set ipapi_cnt 0
    }
    if {$ipapi_cnt >= $ipapi_maxpermin} {return 0}
    incr ipapi_cnt
    return 1
}

proc ::antiproxy::q_ipapi {id ip} {
    http_get "http://ip-api.com/json/$ip?fields=status,message,countryCode,isp,proxy,hosting" \
        [list ::antiproxy::ia_done $id]
}

proc ::antiproxy::ia_done {id data} {
    variable checks
    variable threshold
    variable ipapi_proxy_weight
    variable ipapi_hosting_weight
    variable country_block
    if {![info exists checks($id)]} return
    set cc ""
    set isp ""
    regexp {"countryCode"\s*:\s*"([^"]*)"} $data -> cc
    regexp {"isp"\s*:\s*"([^"]*)"} $data -> isp
    dict set checks($id) geo [string trim "$cc $isp"]
    if {[regexp {"proxy"\s*:\s*true} $data]} {
        add $id $ipapi_proxy_weight "ip-api: proxy"
    }
    if {[regexp {"hosting"\s*:\s*true} $data]} {
        add $id $ipapi_hosting_weight "ip-api: hosting ($isp)"
    }
    if {$cc ne "" && [lsearch -exact -nocase $country_block $cc] >= 0} {
        add $id $threshold "blocked country ($cc)"
    }
    done $id
}

# ---------------------------- TOR LIST ----------------------------

proc ::antiproxy::tor_load {} {
    variable torlist
    variable datadir
    set f [file join $datadir tor.txt]
    if {![file exists $f]} return
    array unset torlist
    set fd [open $f r]
    set n 0
    foreach l [split [read $fd] \n] {
        set l [string trim $l]
        if {$l ne ""} {set torlist($l) 1; incr n}
    }
    close $fd
    putlog "antiproxy: $n Tor nodes loaded from disk"
}

proc ::antiproxy::tor_update {} {
    variable tor
    variable tor_url
    variable tor_refresh
    if {$tor} {http_get $tor_url ::antiproxy::tor_done}
    timer $tor_refresh ::antiproxy::tor_update
}

proc ::antiproxy::tor_done {data} {
    variable torlist
    variable datadir
    set ips {}
    foreach l [split $data \n] {
        set l [string trim $l]
        if {[is_ip $l]} {lappend ips $l}
    }
    if {[llength $ips] < 100} {
        putlog "antiproxy: Tor list empty or invalid, keeping the previous one"
        return
    }
    array unset torlist
    foreach ip $ips {set torlist($ip) 1}
    set fd [open [file join $datadir tor.txt] w]
    puts $fd [join $ips \n]
    close $fd
    putlog "antiproxy: Tor list updated ([llength $ips] nodes)"
}

# ----------------------------- ACTIONS -----------------------------

# Before punishing, ask the server whether the user is authed with Q
proc ::antiproxy::act_bad {c} {
    variable allow_authed
    if {$allow_authed && [dict get $c mode] in {join gate}} {
        account_of [dict get $c nick] [list ::antiproxy::authed_check $c]
        return
    }
    act_bad_now $c
}

proc ::antiproxy::authed_check {c account} {
    if {$account ne "" && $account ne "0"} {
        log "[::web::b Allowed] [dict get $c nick]!*@[dict get $c host] on [dict get $c chan], authed as [::web::b $account] ([details [dict get $c score] [dict get $c reasons] [dict get $c geo]])"
        # Gate mode: an authed user gets the invite
        if {[dict get $c mode] eq "gate"} {act_clean $c}
        return
    }
    act_bad_now $c
}

# Q account of a nick via WHOX (account "0" = not authed, "" = unknown)
proc ::antiproxy::account_of {nick callback} {
    variable whox
    set n [string tolower $nick]
    if {[info exists whox($n)]} {
        lappend whox($n) $callback
        return
    }
    set whox($n) [list $callback]
    putserv "WHO $nick n%nat,179"
    utimer 10 [list ::antiproxy::whox_done $n ""]
}

proc ::antiproxy::whox_done {n account} {
    variable whox
    if {![info exists whox($n)]} return
    set cbs $whox($n)
    unset whox($n)
    foreach cb $cbs {
        if {[catch {{*}$cb $account} err]} {putlog "antiproxy: $err"}
    }
}

# :server 354 me 179 nick account
bind raw - 354 ::antiproxy::raw354
proc ::antiproxy::raw354 {from key text} {
    set f [split $text]
    if {[lindex $f 1] eq "179"} {whox_done [string tolower [lindex $f 2]] [lindex $f 3]}
    return 0
}

# End of WHO without a 354 line: the nick is gone
bind raw - 315 ::antiproxy::raw315
proc ::antiproxy::raw315 {from key text} {
    whox_done [string tolower [lindex [split $text] 1]] ""
    return 0
}

proc ::antiproxy::act_bad_now {c} {
    variable action
    variable bantime
    variable kickmsg
    dict with c {}
    set why [join $reasons ", "]
    set who "$nick!$uhost"
    if {$ip ne "" && $ip ne $host} {append who " \[$ip\]"}
    set info [details $score $reasons $geo]
    switch -- $mode {
        join {
            if {![onchan $nick $chan]} {
                log "[::web::b Gone] $who left $chan before the check finished ($info)"
                return
            }
            if {[isop $nick $chan] || [isvoice $nick $chan]} {
                log "[::web::b Skipped] $who on $chan has op/voice ($info)"
                return
            }
            if {$action eq "warn" || ![botisop $chan]} {
                set extra [expr {[botisop $chan] ? ", not acting (action is warn)" : ", I'm not opped"}]
                log "[::web::b Detected] $who on $chan$extra ($info)"
                return
            }
            # Kick messages go to the server: plain text, no colours
            set msg [string map [list %reasons% $why] $kickmsg]
            if {$action eq "kickban"} {
                newchanban $chan "*!*@$host" antiproxy $msg $bantime
            }
            putkick $chan $nick $msg
            log "[::web::b Kicked] $who from $chan ($info)"
        }
        gate {
            puthelp "NOTICE $nick :Access to $chan denied: your connection looks like a proxy/VPN/Tor ($why)."
            log "[::web::b Refused] invite for $who to $chan ($info)"
        }
        manual {
            reply $reply [::web::line Antiproxy "$nick: proxy detected" [list $info]]
            # !pcheck on someone who is on a +antiproxy channel: same
            # action as on join (Q-authed users are still let through)
            if {$chan ne "" && [validchan $chan] && [channel get $chan antiproxy] && [onchan $nick $chan]} {
                dict set c mode join
                act_bad $c
            }
        }
    }
}

proc ::antiproxy::act_clean {c} {
    dict with c {}
    set info [details $score $reasons $geo $note]
    switch -- $mode {
        join {
            if {$score > 0} {log "[::web::b Allowed] $nick!$uhost on $chan, below threshold ($info)"}
        }
        gate {
            if {![botisop $chan]} {
                puthelp "NOTICE $nick :I'm not opped on $chan, I can't invite you right now."
                return
            }
            putserv "INVITE $nick $chan"
            puthelp "NOTICE $nick :Connection verified, you have been invited to $chan."
            log "[::web::b Invited] $nick!$uhost to $chan ($info)"
        }
        manual {
            reply $reply [::web::line Antiproxy "$nick: clean" [list $info]]
        }
    }
}

# ----------------------------- EVENTS -----------------------------

bind join - * ::antiproxy::on_join
proc ::antiproxy::on_join {nick uhost hand chan} {
    variable exempt_flags
    if {[isbotnick $nick] || ![channel get $chan antiproxy]} return
    if {[matchattr $hand $exempt_flags $chan]} return
    check join $nick $uhost $chan
}

bind msg - enter ::antiproxy::msg_gate
proc ::antiproxy::msg_gate {nick uhost hand text} {
    variable gatelast
    variable exempt_flags
    set chan [lindex [split [string trim $text]] 0]
    if {$chan eq "" || ![validchan $chan] || ![channel get $chan antiproxy-gate]} {
        puthelp "NOTICE $nick :Usage: /msg $::botnick enter #channel"
        return 0
    }
    if {[onchan $nick $chan]} {
        puthelp "NOTICE $nick :You are already on $chan."
        return 0
    }
    if {![botisop $chan]} {
        puthelp "NOTICE $nick :I'm not opped on $chan, try again later."
        return 0
    }
    set host [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists gatelast($host)] && $now - $gatelast($host) < 30} {
        puthelp "NOTICE $nick :Please wait a few seconds before asking again."
        return 0
    }
    set gatelast($host) $now
    if {[matchattr $hand $exempt_flags $chan]} {
        putserv "INVITE $nick $chan"
        return 1
    }
    puthelp "NOTICE $nick :Checking your connection, one moment..."
    check gate $nick $uhost $chan
    return 1
}

# chan: the channel where !pcheck was used ("" from the partyline)
proc ::antiproxy::manual {target to {chan ""}} {
    set uh [expr {$chan ne "" ? [getchanhost $target $chan] : ""}]
    if {$uh eq ""} {set uh [getchanhost $target]}
    if {$uh eq ""} {
        set uh "*@$target"
        set chan ""
    }
    check manual $target $uh $chan $to
}

bind dcc o pcheck ::antiproxy::dcc_check
proc ::antiproxy::dcc_check {hand idx text} {
    set t [lindex [split [string trim $text]] 0]
    if {$t eq ""} {
        putdcc $idx "Usage: .pcheck <ip|host|nick>"
        return 0
    }
    putdcc $idx "Checking $t..."
    manual $t [list dcc $idx]
    return 1
}

bind pub o|o !pcheck ::antiproxy::pub_check
proc ::antiproxy::pub_check {nick uhost hand chan text} {
    set t [lindex [split [string trim $text]] 0]
    if {$t eq ""} {
        puthelp "NOTICE $nick :Usage: !pcheck <ip|host|nick>"
        return 0
    }
    manual $t [list chan $chan] $chan
    return 1
}

# .pwhite / .pcache / .pstats and their public twins !pwhite / !pcache /
# !pstats share one proc each. "to" is where the answer goes (see reply);
# "p" is the command prefix shown in usage lines ("." or "!").
# Public answers go by notice to whoever asked, except !pstats.

proc ::antiproxy::entries {n} {expr {$n == 1 ? "1 entry" : "$n entries"}}

proc ::antiproxy::cmd_white {to p text} {
    variable white
    lassign [split [string trim $text]] sub mask
    switch -- [string tolower $sub] {
        add {
            if {$mask eq ""} {
                reply $to [::web::msg Antiproxy "Usage: [::web::b "${p}pwhite add <mask|ip>"]"]
                return 0
            }
            if {[lsearch -exact $white $mask] < 0} {lappend white $mask; white_save}
            reply $to [::web::msg Antiproxy "Added to the whitelist: [::web::b $mask]"]
        }
        del {
            set i [lsearch -exact $white $mask]
            if {$mask eq "" || $i < 0} {
                reply $to [::web::msg Antiproxy "Not in the whitelist: [::web::b $mask]"]
                return 0
            }
            set white [lreplace $white $i $i]
            white_save
            reply $to [::web::msg Antiproxy "Removed from the whitelist: [::web::b $mask]"]
        }
        list {
            if {![llength $white]} {
                reply $to [::web::msg Antiproxy "The whitelist is empty."]
                return 1
            }
            if {[lindex $to 0] eq "dcc"} {
                foreach m $white {reply $to "  $m"}
                return 1
            }
            # On IRC: several masks per line, a few lines at most
            set line {}
            set lines 0
            foreach m $white {
                lappend line $m
                if {[string length [join $line " "]] > 300} {
                    reply $to [::web::msg Whitelist [join $line " "]]
                    set line {}
                    if {[incr lines] == 4} break
                }
            }
            if {[llength $line] && $lines < 4} {
                reply $to [::web::msg Whitelist [join $line " "]]
            }
            reply $to [::web::msg Whitelist [entries [llength $white]]]
        }
        default {
            reply $to [::web::msg Antiproxy "Usage: [::web::b "${p}pwhite add|del|list \[mask\]"]"]
            return 0
        }
    }
    return 1
}

proc ::antiproxy::cmd_cache {to p text} {
    variable cache
    if {[string tolower [string trim $text]] eq "clear"} {
        array unset cache
        reply $to [::web::msg Antiproxy "Cache cleared."]
        return 1
    }
    set ips [lsort [array names cache]]
    if {[lindex $to 0] eq "dcc"} {
        foreach ip $ips {
            lassign $cache($ip) expire verdict reasons
            reply $to [format "  %-39s %-5s %s" $ip $verdict [join $reasons ", "]]
        }
    } else {
        # On IRC: only blocked IPs, 5 at most
        set shown 0
        foreach ip $ips {
            lassign $cache($ip) expire verdict reasons
            if {$verdict ne "bad"} continue
            reply $to [::web::line Cache $ip [list [::web::lbl Reasons [join $reasons ", "]]]]
            if {[incr shown] == 5} break
        }
    }
    set bad 0
    foreach ip $ips {if {[lindex $cache($ip) 1] eq "bad"} {incr bad}}
    reply $to [::web::line Cache [entries [llength $ips]] [list \
        [::web::lbl Blocked $bad] [::web::lbl Empty "[::web::b "${p}pcache clear"]"]]]
    return 1
}

proc ::antiproxy::cmd_stats {to} {
    variable stats
    variable torlist
    variable white
    variable checks
    reply $to [::web::line Antiproxy Stats [list \
        [::web::lbl Checked $stats(checked)] [::web::lbl Blocked $stats(blocked)] \
        [::web::lbl Clean $stats(clean)] [::web::lbl "From cache" $stats(cached)] \
        [::web::lbl "Tor nodes" [array size torlist]] [::web::lbl Whitelist [llength $white]] \
        [::web::lbl "In progress" [array size checks]]]]
    return 1
}

bind dcc o pwhite ::antiproxy::dcc_white
proc ::antiproxy::dcc_white {hand idx text} {cmd_white [list dcc $idx] . $text}
bind dcc o pcache ::antiproxy::dcc_cache
proc ::antiproxy::dcc_cache {hand idx text} {cmd_cache [list dcc $idx] . $text}
bind dcc o pstats ::antiproxy::dcc_stats
proc ::antiproxy::dcc_stats {hand idx text} {cmd_stats [list dcc $idx]}

# Same flags as the partyline: the whitelist and the cache are global
bind pub o !pwhite ::antiproxy::pub_white
proc ::antiproxy::pub_white {nick uhost hand chan text} {cmd_white [list notice $nick] ! $text}
bind pub o !pcache ::antiproxy::pub_cache
proc ::antiproxy::pub_cache {nick uhost hand chan text} {cmd_cache [list notice $nick] ! $text}
bind pub o|o !pstats ::antiproxy::pub_stats
proc ::antiproxy::pub_stats {nick uhost hand chan text} {cmd_stats [list chan $chan]}

# --------------------------- MAINTENANCE ---------------------------

proc ::antiproxy::housekeeping {} {
    variable cache
    variable gatelast
    set now [clock seconds]
    foreach ip [array names cache] {
        if {[lindex $cache($ip) 0] < $now} {unset cache($ip)}
    }
    foreach h [array names gatelast] {
        if {$now - $gatelast($h) > 300} {unset gatelast($h)}
    }
    timer 30 ::antiproxy::housekeeping
}

proc ::antiproxy::init {} {
    variable datadir
    variable tor
    file mkdir $datadir
    # Avoid duplicated timers after a .rehash
    foreach t [timers] {
        if {[string match ::antiproxy::* [lindex $t 1]]} {killtimer [lindex $t 2]}
    }
    foreach t [utimers] {
        if {[string match ::antiproxy::* [lindex $t 1]]} {killutimer [lindex $t 2]}
    }
    white_load
    tor_load
    if {$tor} {utimer 20 ::antiproxy::tor_update}
    timer 30 ::antiproxy::housekeeping
}

::antiproxy::init
putlog "antiproxy.tcl loaded (DNSBL + proxycheck.io + ip-api + Tor + rDNS)"
