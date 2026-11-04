# Seventh batch: antiproxy BNC-friendly scoring, stricter rules and the Q account check
puts "== antiproxy BNCs"
set ::antiproxy::allow_authed 1
set ::antiproxy::proxycheck 1
set ::antiproxy::ipapi 1
set ::antiproxy::rdns 0
array unset ::antiproxy::cache
set ::antiproxy::ipapi_cnt 0
set ::chanusers {pepe shanon reborn evil JAEGARN vps risky Zilya11}
proc isop {n c} {return 0}
proc isvoice {n c} {return 0}
proc botisop {c} {return 1}
proc matchattr {h f {c ""}} {return 0}
proc newchanban {chan mask by msg t} {emit "BAN $chan $mask ($t min) $msg"}
channel set #test +antiproxy
set ::pc_risk 33
set ::ia_answer {{"status":"success","countryCode":"RO","isp":"Host Sailor Ltd","proxy":false,"hosting":true}}
proc ::antiproxy::q_proxycheck {id ip} {
    ::antiproxy::pc_done $id "{\"status\":\"ok\",\"$ip\":{\"proxy\":\"yes\",\"type\":\"$::pc_type\",\"risk\":$::pc_risk}}"
}
proc ::antiproxy::q_ipapi {id ip} {
    ::antiproxy::ia_done $id $::ia_answer
}
# BNC hostnames resolve; anything else goes to the stub in run.tcl
rename dnslookup dnslookup_base
proc dnslookup {name cb args} {
    set bnc {away.ink 11.11.11.11 us1a.irc.xshellz.com 15.15.15.15}
    if {[dict exists $bnc $name]} {
        {*}$cb [dict get $bnc $name] $name 1 {*}$args
        return
    }
    dnslookup_base $name $cb {*}$args
}
proc kicked {} {llength [lsearch -all -glob $::out "KICK*"]}

# BNC with a hostname: proxycheck "VPN" (+1) + ip-api hosting (+1) = 2
set ::pc_type VPN
set ::out {}
::antiproxy::on_join shanon shanon@away.ink * #test
check {![kicked] && ![llength [lsearch -all -glob $::out "WHO *"]]} "VPN + hosting with a hostname (BNC) is let in"

set ::out {}
::antiproxy::on_join JAEGARN ~JAEGARN@us1a.irc.xshellz.com * #test
check {![kicked]} "shell provider (xshellz) is let in"

# The same hints on a bare IP: +1 for no reverse DNS = 3
set ::out {}
::antiproxy::on_join vps vps@14.14.14.14 * #test
expect "WHO vps n%nat,179" "bare IP + VPN + hosting reaches the threshold"
::antiproxy::raw315 srv 315 "MiBot vps :End of /WHO list."
expect "KICK #test vps :*bare IP, no rDNS +1*" "bare VPS IP kicked"

# A "VPN" with a high proxycheck.io risk counts as a proxy
set ::pc_risk 80
set ::out {}
array unset ::antiproxy::cache
::antiproxy::on_join risky risky@away.ink * #test
::antiproxy::raw315 srv 315 "MiBot risky :End of /WHO list."
expect "KICK #test risky :*proxycheck.io: VPN risk 80 +3*" "high-risk VPN counts as a proxy"
set ::pc_risk 33

# ip-api proxy flag alone (+3) is enough (the Zilya11 case)
set ::pc_type none
proc ::antiproxy::q_proxycheck {id ip} {::antiproxy::pc_done $id {{"status":"ok"}}}
set ::ia_answer {{"status":"success","countryCode":"UA","isp":"X","proxy":true,"hosting":false}}
set ::out {}
::antiproxy::on_join Zilya11 ~QwwsOoUk@46.148.78.82 * #test
::antiproxy::raw315 srv 315 "MiBot Zilya11 :End of /WHO list."
expect "BAN #test *!*@46.148.78.82 *ip-api: proxy +3*" "ip-api proxy flag: kickban"

# Open SOCKS proxy (+3): the bot asks for the Q account first
proc ::antiproxy::q_proxycheck {id ip} {
    ::antiproxy::pc_done $id "{\"status\":\"ok\",\"$ip\":{\"proxy\":\"yes\",\"type\":\"$::pc_type\",\"risk\":$::pc_risk}}"
}
set ::ia_answer {{"status":"success","countryCode":"RO","isp":"Host Sailor Ltd","proxy":false,"hosting":true}}
set ::pc_type SOCKS5
set ::out {}
::antiproxy::on_join reborn reborn@12.12.12.12 * #test
expect "WHO reborn n%nat,179" "WHOX query before acting"
::antiproxy::raw354 srv 354 "MiBot 179 reborn RebornAcc"
::antiproxy::raw315 srv 315 "MiBot reborn :End of /WHO list."
check {![kicked]} "authed with Q: let in"

set ::out {}
::antiproxy::on_join evil evil@13.13.13.13 * #test
::antiproxy::raw354 srv 354 "MiBot 179 evil 0"
::antiproxy::raw315 srv 315 "MiBot evil :End of /WHO list."
expect "KICK #test evil :Proxy/VPN/Tor not allowed (proxycheck.io: SOCKS5 risk 33 +3*" "not authed: kicked"

# !pcheck on a nick that is on a +antiproxy channel also acts
proc getchanhost {n {c ""}} {expr {$n eq "ircfiber" ? "~ircfiber@187.14.52.149" : "$n@host.$n.example"}}
lappend ::chanusers ircfiber
set ::pc_type VPN
set ::pc_risk 73
set ::ia_answer {{"status":"success","countryCode":"US","isp":"Datacamp Limited","proxy":true,"hosting":false}}
array unset ::antiproxy::cache
set ::out {}
::antiproxy::pub_check opnick o@h op #test "ircfiber"
expect "PRIVMSG #test :Antiproxy :: ircfiber: proxy detected (Score: 4*" "!pcheck reports"
::antiproxy::raw315 srv 315 "MiBot ircfiber :End of /WHO list."
expect "KICK #test ircfiber :*" "!pcheck on a nick on the channel kickbans it"
set ::out {}
::antiproxy::pub_check opnick o@h op #test "ircfiber"
::antiproxy::raw354 srv 354 "MiBot 179 ircfiber SomeAccount"
::antiproxy::raw315 srv 315 "MiBot ircfiber :End of /WHO list."
check {![llength [lsearch -all -glob $::out "KICK*"]]} "!pcheck: authed with Q, only reported"

rename dnslookup {}
rename dnslookup_base dnslookup
set ::antiproxy::allow_authed 0
