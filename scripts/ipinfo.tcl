# =====================================================================
#  ipinfo.tcl  v1.2.0  -  Full IP lookup
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Everything about an IP in 3 lines, all sources queried in parallel:
#      IP / reverse DNS / location / timezone + local time
#      ASN / ISP / organisation / RDAP network, range and abuse contact
#      proxycheck.io (type, risk, operator) / ip-api flags / Tor / DNSBLs
#    Sources: ip-api.com, proxycheck.io v2, RDAP (rdap.org), DroneBL,
#    EFnetRBL, dan.me.uk and antiproxy's Tor list. IPv4 and IPv6.
#    Looking up a NICK reveals their IP: by default only bot ops can do
#    it and the answer goes by notice. +x users show "IP hidden".
#
#  REQUIREMENTS
#    web.tcl (load it first), tcl-tls
#
#  SETUP
#    .chanset #chan +ipinfo
#
#  COMMANDS
#    !ip <ip|hostname>                 everyone
#    !ip <nick>                        ops, answered by notice
#    /msg <bot> ip <ip|host|nick>      private
#  PARTYLINE
#    .ip <ip|host|nick>
# =====================================================================

namespace eval ::ipinfo {
    # ------------------------- CONFIGURATION -------------------------
    variable pub_flags "-|-"         ;# who can use !ip on IPs/hostnames
    variable nick_flags "o|o"        ;# who can look up nicks
    variable throttle 8              ;# seconds between lookups per user
    variable timeout 15              ;# seconds before printing what we have
    variable proxycheck_key ""       ;# empty = reuse antiproxy's key if loaded
    variable dnsbls {
        dnsbl.dronebl.org
        rbl.efnetrbl.org
        torexit.dan.me.uk
    }

    # --------------------- STATE (do not touch) ---------------------
    variable seq
    variable req
    variable userhost
    if {![info exists seq]} {set seq 0}
}

setudef flag ipinfo

# ----------------------------- HELPERS -----------------------------

proc ::ipinfo::is_ipv4 {s} {
    if {![regexp {^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$} $s -> a b c d]} {return 0}
    foreach o [list $a $b $c $d] {
        if {[scan $o %d] > 255} {return 0}
    }
    return 1
}

proc ::ipinfo::is_ip {s} {
    expr {[is_ipv4 $s] || ([string first : $s] >= 0 && [regexp {^[0-9A-Fa-f:]+$} $s])}
}

proc ::ipinfo::is_private {ip} {
    if {![is_ipv4 $ip]} {
        set ip [string tolower $ip]
        return [expr {$ip eq "::1" || [string match fe80:* $ip] || [string match fc* $ip] || [string match fd* $ip]}]
    }
    lassign [split $ip .] a b
    set a [scan $a %d]
    set b [scan $b %d]
    expr {$a == 0 || $a == 10 || $a == 127 || $a >= 224 || ($a == 169 && $b == 254) ||
          ($a == 172 && $b >= 16 && $b <= 31) || ($a == 192 && $b == 168) ||
          ($a == 100 && $b >= 64 && $b <= 127)}
}

# Reversed IP for DNSBL lookups (IPv4 octets, IPv6 nibbles)
proc ::ipinfo::rev_ip {ip} {
    if {[is_ipv4 $ip]} {return [join [lreverse [split $ip .]] .]}
    set halves [split [string map {:: |} [string tolower $ip]] |]
    set left [lsearch -all -inline -not -exact [split [lindex $halves 0] :] ""]
    set right [lsearch -all -inline -not -exact [split [lindex $halves end] :] ""]
    if {[llength $halves] == 1} {set right {}}
    set groups $left
    for {set i [expr {8 - [llength $left] - [llength $right]}]} {$i > 0} {incr i -1} {lappend groups 0}
    lappend groups {*}$right
    set hex ""
    foreach g $groups {append hex [format %04x [scan $g %x]]}
    join [lreverse [split $hex ""]] .
}

proc ::ipinfo::set_field {id key val} {
    variable req
    if {[info exists req($id)]} {dict set req($id) $key $val}
}

proc ::ipinfo::field {id key} {
    variable req
    if {![info exists req($id)] || ![dict exists $req($id) $key]} {return ""}
    dict get $req($id) $key
}

# ------------------------------ ENTRY ------------------------------

proc ::ipinfo::lookup {target reply requester} {
    variable seq
    variable req
    set id [incr seq]
    set req($id) [dict create target $target reply $reply pending 0 dnsbl {}]

    if {[is_ip $target]} {
        start $id $target ""
        return
    }
    # A nick on one of our channels?
    set uh [getchanhost $target]
    if {$uh ne ""} {
        from_uhost $id $target $uh
        return
    }
    if {[string first . $target] >= 0} {
        set_field $id host $target
        dnslookup $target ::ipinfo::resolved $id
        return
    }
    # Unknown nick: ask the server
    userhost_query $id $target
}

proc ::ipinfo::from_uhost {id nick uhost} {
    set host [lindex [split $uhost @] end]
    if {[regexp -nocase {^([^.]+)\.users\.quakenet\.org$} $host -> account]} {
        reply $id [::web::msg IP "[::web::b $nick] is authed with Q as [::web::b $account] and uses +x: the real IP is hidden."]
        finish $id 1
        return
    }
    set_field $id nick $nick
    if {[is_ip $host]} {
        start $id $host ""
    } else {
        set_field $id host $host
        dnslookup $host ::ipinfo::resolved $id
    }
}

proc ::ipinfo::resolved {ip host status id} {
    variable req
    if {![info exists req($id)]} return
    if {!$status || ![is_ip $ip]} {
        reply $id [::web::msg IP "Could not resolve [::web::b $host]."]
        finish $id 1
        return
    }
    start $id $ip $host
}

# USERHOST for nicks we don't share a channel with
bind raw - 302 ::ipinfo::raw302
proc ::ipinfo::userhost_query {id nick} {
    variable userhost
    set userhost([string tolower $nick]) $id
    putserv "USERHOST $nick"
    utimer 10 [list ::ipinfo::userhost_timeout $nick]
}

proc ::ipinfo::raw302 {from key text} {
    variable userhost
    foreach entry [split [string trimleft [lindex [split $text :] end]] " "] {
        if {![regexp {^([^=*]+)\*?=[+-](.+)$} $entry -> nick uhost]} continue
        set n [string tolower $nick]
        if {[info exists userhost($n)]} {
            set id $userhost($n)
            unset userhost($n)
            from_uhost $id $nick $uhost
        }
    }
    # Nicks that are offline are simply missing from the reply
    return 0
}

proc ::ipinfo::userhost_timeout {nick} {
    variable userhost
    set n [string tolower $nick]
    if {![info exists userhost($n)]} return
    set id $userhost($n)
    unset userhost($n)
    reply $id [::web::msg IP "[::web::b $nick] is not online."]
    finish $id 1
}

# ----------------------------- QUERIES -----------------------------

proc ::ipinfo::start {id ip host} {
    variable req
    variable dnsbls
    variable timeout
    set_field $id ip $ip
    if {$host ne ""} {set_field $id host $host}
    if {[is_private $ip]} {
        reply $id [::web::msg IP "[::web::b $ip] is a private/reserved address."]
        finish $id 1
        return
    }
    utimer $timeout [list ::ipinfo::finish $id]
    dict set req($id) pending 1

    # ip-api.com: location, ASN, ISP, flags (free, HTTP only, 45/min)
    pending $id
    ::web::get "http://ip-api.com/json/$ip?fields=status,message,continent,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as,asname,reverse,mobile,proxy,hosting" \
        [list ::ipinfo::got_ipapi $id]

    # proxycheck.io v2: proxy/VPN type, risk score, provider
    set key [proxycheck_key]
    set url "https://proxycheck.io/v2/$ip?vpn=1&asn=1&risk=1"
    if {$key ne ""} {append url "&key=$key"}
    pending $id
    ::web::get $url [list ::ipinfo::got_proxycheck $id]

    # RDAP: registered network, range, country and abuse contact
    pending $id
    ::web::get "https://rdap.org/ip/$ip" [list ::ipinfo::got_rdap $id] {Accept application/rdap+json}

    # DNSBLs
    set rev [rev_ip $ip]
    foreach zone $dnsbls {
        pending $id
        dnslookup "$rev.$zone" ::ipinfo::got_dnsbl $id $zone
    }
    # Reverse DNS (ip-api also gives one, ours is authoritative)
    if {$host eq ""} {
        pending $id
        dnslookup $ip ::ipinfo::got_rdns $id
    }
    done $id
}

proc ::ipinfo::proxycheck_key {} {
    variable proxycheck_key
    if {$proxycheck_key eq "" && [info exists ::antiproxy::proxycheck_key]} {
        return $::antiproxy::proxycheck_key
    }
    return $proxycheck_key
}

proc ::ipinfo::pending {id} {
    variable req
    dict incr req($id) pending
}

proc ::ipinfo::done {id} {
    variable req
    if {![info exists req($id)]} return
    dict incr req($id) pending -1
    if {[dict get $req($id) pending] <= 0} {finish $id}
}

proc ::ipinfo::got_ipapi {id ok code body} {
    if {$ok && ![catch {::web::json $body} d] && [::web::dget $d status] eq "success"} {
        set_field $id ipapi $d
    }
    done $id
}

proc ::ipinfo::got_proxycheck {id ok code body} {
    if {$ok && ![catch {::web::json $body} d]} {
        set ip [field $id ip]
        if {[dict exists $d $ip]} {set_field $id pc [dict get $d $ip]}
    }
    done $id
}

proc ::ipinfo::got_rdap {id ok code body} {
    if {$ok && ![catch {::web::json $body} d]} {
        set net [::web::dget $d name]
        set range ""
        foreach c [::web::dget $d cidr0_cidrs] {
            set p [::web::dget $c v4prefix]
            if {$p eq ""} {set p [::web::dget $c v6prefix]}
            if {$p ne ""} {lappend range "$p/[::web::dget $c length]"}
        }
        if {![llength $range] && [::web::dget $d startAddress] ne ""} {
            set range [list "[::web::dget $d startAddress] - [::web::dget $d endAddress]"]
        }
        set_field $id rdap [dict create name $net range [join $range ", "] \
            country [::web::dget $d country] abuse [abuse_email [::web::dget $d entities]]]
    }
    done $id
}

# Looks for an entity with role "abuse" (recursively) and returns its email
proc ::ipinfo::abuse_email {entities} {
    foreach e $entities {
        if {"abuse" in [::web::dget $e roles]} {
            foreach item [lindex [::web::dget $e vcardArray] 1] {
                if {[lindex $item 0] eq "email"} {return [lindex $item 3]}
            }
        }
        set sub [abuse_email [::web::dget $e entities]]
        if {$sub ne ""} {return $sub}
    }
    return ""
}

proc ::ipinfo::got_dnsbl {ip host status id zone} {
    variable req
    if {![info exists req($id)]} return
    if {$status && [string match 127.* $ip]} {
        dict lappend req($id) dnsbl "$zone ($ip)"
    }
    done $id
}

proc ::ipinfo::got_rdns {ip host status id} {
    if {$status && $host ne "" && $host ne $ip} {set_field $id host $host}
    done $id
}

# ------------------------------ OUTPUT ------------------------------

proc ::ipinfo::reply {id text} {
    set to [field $id reply]
    if {[string match dcc:* $to]} {
        set idx [string range $to 4 end]
        if {[valididx $idx]} {putdcc $idx [stripcodes bcruag $text]}
    } else {
        ::web::say $to $text
    }
}

proc ::ipinfo::yn {v} {expr {$v eq "1" ? "yes" : "no"}}

proc ::ipinfo::finish {id {quiet 0}} {
    variable req
    if {![info exists req($id)]} return
    if {$quiet} {
        unset req($id)
        return
    }
    set r $req($id)

    set ip [dict get $r ip]
    set ia [expr {[dict exists $r ipapi] ? [dict get $r ipapi] : {}}]
    set pc [expr {[dict exists $r pc] ? [dict get $r pc] : {}}]
    set rd [expr {[dict exists $r rdap] ? [dict get $r rdap] : {}}]
    set host [expr {[dict exists $r host] ? [dict get $r host] : [::web::dget $ia reverse]}]

    # Line 1: identity and location
    #   IP :: 1.2.3.4 (Nick: x | Host: y | Location: ... | Time: ...)
    set f {}
    if {[dict exists $r nick]} {lappend f [::web::lbl Nick [dict get $r nick]]}
    if {$host ne ""} {lappend f [::web::lbl Host $host]}
    if {[dict size $ia]} {
        set place [join [lsearch -all -inline -not -exact [list [::web::dget $ia city] [::web::dget $ia regionName] [::web::dget $ia country]] ""] ", "]
        lappend f [::web::lbl Location "$place ([::web::dget $ia countryCode], [::web::dget $ia continent])"]
        if {[::web::dget $ia zip] ne ""} {lappend f [::web::lbl ZIP [::web::dget $ia zip]]}
        lappend f [::web::lbl Coords "[::web::dget $ia lat],[::web::dget $ia lon]"]
        set tz [::web::dget $ia timezone]
        if {$tz ne "" && ![catch {clock format [clock seconds] -timezone :$tz -format "%H:%M %Z"} now]} {
            lappend f [::web::lbl Time "$tz ($now)"]
        }
    }
    reply $id [::web::line IP $ip $f]

    # Line 2: network
    #   Network :: ASN: x | ISP: y | RDAP: name range (cc) | Abuse: mail
    set parts {}
    if {[::web::dget $ia as] ne ""} {lappend parts [::web::lbl ASN [::web::dget $ia as]]}
    if {[::web::dget $ia isp] ne ""} {lappend parts [::web::lbl ISP [::web::dget $ia isp]]}
    if {[::web::dget $ia org] ne "" && [::web::dget $ia org] ne [::web::dget $ia isp]} {lappend parts [::web::lbl Org [::web::dget $ia org]]}
    if {[::web::dget $pc provider] ne "" && [::web::dget $pc provider] ne [::web::dget $ia isp]} {lappend parts [::web::lbl Provider [::web::dget $pc provider]]}
    if {[dict size $rd]} {
        set net [dict get $rd name]
        if {[dict get $rd range] ne ""} {append net " [dict get $rd range]"}
        if {[dict get $rd country] ne ""} {append net " ([dict get $rd country])"}
        lappend parts [::web::lbl RDAP $net]
        if {[dict get $rd abuse] ne ""} {lappend parts [::web::lbl Abuse [dict get $rd abuse]]}
    }
    if {[llength $parts]} {reply $id [::web::msg Network [::web::fields $parts]]}

    # Line 3: security
    #   Security :: CLEAN (proxycheck: ... | ip-api: ... | Tor exit: no | DNSBL: ...)
    set flags {}
    set bad 0
    if {[dict size $pc]} {
        if {[::web::dget $pc proxy] eq "yes"} {
            set t "\00304[::web::dget $pc type]\003"
            incr bad 2
        } else {
            set t "clean"
            if {[::web::dget $pc type] ne ""} {append t " ([::web::dget $pc type])"}
        }
        if {[::web::dget $pc risk] ne ""} {append t ", risk [::web::dget $pc risk]%"}
        if {[::web::dget $pc operator name] ne ""} {append t ", operator [::web::dget $pc operator name]"}
        lappend flags [::web::lbl proxycheck $t]
    }
    if {[dict size $ia]} {
        lappend flags [::web::lbl ip-api "proxy [yn [::web::dget $ia proxy]] / hosting [yn [::web::dget $ia hosting]] / mobile [yn [::web::dget $ia mobile]]"]
        if {[::web::dget $ia proxy] eq "1"} {incr bad 2}
        if {[::web::dget $ia hosting] eq "1"} {incr bad 1}
    }
    set tor [expr {[info exists ::antiproxy::torlist($ip)]}]
    if {[array exists ::antiproxy::torlist]} {
        lappend flags [::web::lbl "Tor exit" [expr {$tor ? "\00304yes\003" : "no"}]]
        if {$tor} {incr bad 3}
    }
    set bl [dict get $r dnsbl]
    if {[llength $bl]} {
        lappend flags [::web::lbl DNSBL "\00304[join $bl {, }]\003"]
        incr bad 3
    } else {
        lappend flags [::web::lbl DNSBL "not listed"]
    }
    set verdict [expr {$bad >= 3 ? "\00304PROXY/VPN/TOR\003" : $bad > 0 ? "\00307SUSPICIOUS (datacenter)\003" : "\00303CLEAN\003"}]
    reply $id [::web::line Security $verdict $flags]
    unset req($id)
}

# ----------------------------- COMMANDS -----------------------------

# "-|-" means everyone (matchattr returns 0 for users the bot doesn't know)
proc ::ipinfo::everyone {flags} {
    expr {$flags in {"" "-" "-|-"}}
}

proc ::ipinfo::allowed {target hand chan} {
    variable nick_flags
    variable pub_flags
    if {![everyone $pub_flags] && ![matchattr $hand $pub_flags $chan]} {return 0}
    # IPs and hostnames are fine; nicks need nick_flags
    if {[is_ip $target] || ([string first . $target] >= 0 && [getchanhost $target] eq "")} {return 1}
    matchattr $hand $nick_flags $chan
}

bind pub - !ip ::ipinfo::pub_ip
proc ::ipinfo::pub_ip {nick uhost hand chan text} {
    variable throttle
    if {![channel get $chan ipinfo]} {return 0}
    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !ip] <ip|hostname|nick>"
        return 0
    }
    if {![allowed $target $hand $chan]} {
        puthelp "NOTICE $nick :Looking up nicks is restricted to ops (it reveals their IP)."
        return 0
    }
    if {[::web::throttle "ip,[lindex [split $uhost @] end]" $throttle]} {return 0}
    # Nick lookups are answered privately
    set to [expr {[is_ip $target] || [string first . $target] >= 0 ? $chan : "notice:$nick"}]
    lookup $target $to $nick
    return 1
}

bind msg - ip ::ipinfo::msg_ip
proc ::ipinfo::msg_ip {nick uhost hand text} {
    variable throttle
    variable nick_flags
    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b "/msg $::botnick ip"] <ip|hostname|nick>"
        return 0
    }
    if {!([is_ip $target] || [string first . $target] >= 0) && ![matchattr $hand [lindex [split $nick_flags |] 0]]} {
        puthelp "NOTICE $nick :Looking up nicks is restricted to bot ops."
        return 0
    }
    if {[::web::throttle "ip,[lindex [split $uhost @] end]" $throttle]} {return 0}
    lookup $target "notice:$nick" $nick
    return 1
}

bind dcc o ip ::ipinfo::dcc_ip
proc ::ipinfo::dcc_ip {hand idx text} {
    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        putdcc $idx "Usage: .ip <ip|hostname|nick>"
        return 0
    }
    putdcc $idx "Looking up $target..."
    lookup $target "dcc:$idx" $hand
    return 1
}

putlog "ipinfo.tcl loaded (!ip: ip-api + proxycheck.io + RDAP + DNSBL + Tor)"
