# Third batch: web.tcl JSON parser, ipinfo.tcl and utils.tcl with canned API answers
source "$::scripts/web.tcl"
source "$::scripts/ipinfo.tcl"
source "$::scripts/utils.tcl"

puts "== web.tcl JSON"
set d [::web::json {{"a":1,"b":[true,false,null],"c":{"d":"x\"y\\zé\n"},"e":-1.5e3,"f":[],"g":{}}}]
check {[dict get $d a] == 1 && [dict get $d b] eq {1 0 {}} && [dict get $d c d] eq "x\"y\\zé\n"} "objects, arrays, escapes"
check {[dict get $d e] == -1500 && [dict get $d f] eq "" && [dict get $d g] eq ""} "numbers and empties"
check {[catch {::web::json {{"a":}}}]} "invalid JSON raises an error"
check {[::web::dget $d c d] ne "" && [::web::dget $d c nope] eq "" && [::web::dget $d a b] eq ""} "dget"

# Canned HTTP answers, matched by URL pattern; called synchronously (worst case)
set ::canned {
    *ip-api.com/json/1.2.3.4*
    {{"status":"success","continent":"Europe","country":"Spain","countryCode":"ES","regionName":"Madrid","city":"Madrid","zip":"28001","lat":40.4165,"lon":-3.7026,"timezone":"Europe/Madrid","isp":"Telefonica de Espana","org":"RIMA","as":"AS3352 TELEFONICA DE ESPANA S.A.U.","reverse":"x.dynamic.es","mobile":false,"proxy":false,"hosting":true}}
    *proxycheck.io/v2/1.2.3.4*
    {{"status":"ok","1.2.3.4":{"asn":"AS3352","provider":"NordVPN SA","proxy":"yes","type":"VPN","risk":66,"operator":{"name":"NordVPN"}}}}
    *rdap.org/ip/1.2.3.4
    {{"name":"RIMA","startAddress":"1.2.0.0","endAddress":"1.2.255.255","country":"ES","cidr0_cidrs":[{"v4prefix":"1.2.0.0","length":16}],"entities":[{"roles":["registrant"],"entities":[{"roles":["abuse"],"vcardArray":["vcard",[["version",{},"text","4.0"],["email",{},"text","abuse@telefonica.es"]]]}]}]}}
    *geocoding-api.open-meteo.com*Madrid*
    {{"results":[{"name":"Madrid","latitude":40.4165,"longitude":-3.70256,"country_code":"ES","admin1":"Madrid","timezone":"Europe/Madrid","country":"Spain"}]}}
    *geocoding-api.open-meteo.com*Nowhere*
    {{"generationtime_ms":0.5}}
    *api.open-meteo.com/v1/forecast*
    {{"current":{"temperature_2m":21.34,"relative_humidity_2m":40,"apparent_temperature":20.1,"precipitation":0.0,"weather_code":2,"wind_speed_10m":12.4,"wind_direction_10m":50,"wind_gusts_10m":25.1},"daily":{"time":["2026-10-26","2026-10-27","2026-10-28","2026-10-29"],"weather_code":[2,61,0,3],"temperature_2m_max":[24.1,19,22,20],"temperature_2m_min":[12.2,11,10,9],"precipitation_probability_max":[5,80,0,10],"sunrise":["2026-10-26T07:58","x","x","x"],"sunset":["2026-10-26T18:47","x","x","x"]}}}
    *frankfurter*base=EUR*symbols=USD*
    {{"amount":1.0,"base":"EUR","date":"2026-10-23","rates":{"USD":1.0842}}}
    *coingecko*bitcoin*
    {{"bitcoin":{"eur":61234.5,"eur_24h_change":-2.345}}}
    *restcountries.com/v3.1/name/spain*
    {[{"name":{"common":"Spain","official":"Kingdom of Spain"},"cca2":"ES","capital":["Madrid"],"region":"Europe","subregion":"Southern Europe","population":47351567,"area":505992.0,"currencies":{"EUR":{"name":"Euro","symbol":"€"}},"languages":{"spa":"Spanish"},"timezones":["UTC","UTC+01:00"],"idd":{"root":"+3","suffixes":["4"]},"tld":[".es"],"flag":"🇪🇸","car":{"side":"right"}}]}
    *cloudflare-dns.com*name=example.com*type=MX*
    {{"Status":0,"Answer":[{"name":"example.com","type":15,"TTL":300,"data":"10 mx1.example.com."},{"name":"example.com","type":15,"TTL":300,"data":"20 mx2.example.com."}]}}
}
proc ::web::get {url callback {headers {}} {redirs 0}} {
    foreach {pat body} $::canned {
        if {[string match $pat $url]} {{*}$callback 1 200 $body; return}
    }
    {*}$callback 0 404 ""
}
proc ::web::throttle {key secs} {return 0}
proc valididx {i} {return 1}
proc matchattr {h f {c ""}} {return 0}
proc dnslookup {name cb args} {
    if {$name eq "4.3.2.1.dnsbl.dronebl.org"} {{*}$cb 127.0.0.3 $name 1 {*}$args; return}
    if {$name eq "1.2.3.4"} {{*}$cb 1.2.3.4 host.dynamic.es 1 {*}$args; return}
    if {$name eq "vpn.example.net"} {{*}$cb 1.2.3.4 $name 1 {*}$args; return}
    {*}$cb 0.0.0.0 $name 0 {*}$args
}

puts "== ipinfo"
channel set #test +ipinfo +utils
set ::out {}
::ipinfo::pub_ip pepe p@h * #test 1.2.3.4
set all [plain [join $::out \n]]
check {[string match "*IP :: 1.2.3.4 (Host: host.dynamic.es | Location: Madrid, Madrid, Spain (ES, Europe)*Time: Europe/Madrid*" $all]} "line 1: ip, rDNS, location, timezone"
check {[string match "*Network :: ASN: AS3352*ISP: Telefonica*Provider: NordVPN SA*RDAP: RIMA 1.2.0.0/16 (ES)*Abuse: abuse@telefonica.es*" $all]} "line 2: ASN, ISP, RDAP range and abuse contact"
check {[string match "*Security :: PROXY/VPN/TOR (proxycheck: VPN*risk 66%*operator NordVPN*hosting yes*DNSBL: dnsbl.dronebl.org (127.0.0.3)*" $all]} "line 3: proxycheck, ip-api, DNSBL, verdict"
check {[array size ::ipinfo::req] == 0} "no pending lookups"
check {[llength $::out] == 3 && [llength [lsearch -all -inline -glob $::out "PRIVMSG #test :*"]] == 3} "answers go to the channel, 3 lines"

set ::out {}
::ipinfo::pub_ip pepe p@h * #test vpn.example.net
check {[string match "*IP :: 1.2.3.4 (Host: vpn.example.net*" [plain [join $::out]]]} "hostname resolved first"

set ::out {}
proc matchattr {h f {c ""}} {return [expr {$f eq "-|-"}]}
::ipinfo::pub_ip pepe p@h * #test juan
expect "NOTICE pepe :Looking up nicks is restricted*" "nick lookups need op"
proc matchattr {h f {c ""}} {return 1}
set ::hosts {juan j@juanacc.users.quakenet.org}
proc getchanhost {n {c ""}} {if {[dict exists $::hosts $n]} {dict get $::hosts $n}}
::ipinfo::pub_ip pepe p@h * #test juan
expect "NOTICE pepe :*juan* is authed with Q as *juanacc*" "+x user: hidden IP, answered by notice"

set ::out {}
::ipinfo::pub_ip pepe p@h * #test 192.168.1.1
expect "*private/reserved*" "private IP"

puts "== utils"
set ::out {}
::utils::cmd_weather a a@b * #test "Madrid, ES"
expect "PRIVMSG #test :Weather :: Madrid, ES (Now: Partly cloudy, 21.3C | Feels: 20.1C | Humidity: 40% | Wind: 12 km/h NE*Today: 12-24C, rain 5% | Sun: 07:58 - 18:47)" "!weather"
::utils::cmd_forecast a a@b * #test Madrid
expect "*Forecast :: Madrid, ES (Mon: Partly cloudy 12-24C, rain 5% | Tue: Light rain 11-19C, rain 80%*" "!forecast"
::utils::cmd_weather a a@b * #test Nowhere
expect "*Weather :: City not found: Nowhere*" "unknown city"
::utils::cmd_time a a@b * #test Madrid
expect "PRIVMSG #test :Time :: Madrid, ES (*CE*T*" "!time"
::utils::cmd_convert a a@b * #test "100 eur to usd"
expect "*Convert :: 100 EUR = 108.42 USD (Rate: 1 EUR = 1.0842 USD | Source: ECB 2026-10-23)" "!convert"
::utils::cmd_crypto a a@b * #test "btc eur"
expect "*Crypto :: bitcoin (Price: 61234.5 EUR | 24h: -2.35%)" "!crypto with alias"
::utils::cmd_country a a@b * #test spain
expect "*Country :: Spain (Official: Kingdom of Spain | Code: ES | Capital: Madrid*Population: 47,351,567*Euro (EUR €)*Phone: +34*Drives: right*" "!country"
::utils::cmd_dns a a@b * #test "example.com mx"
expect "*DNS :: example.com MX (10 mx1.example.com. (ttl 300) | 20 mx2.example.com. (ttl 300))" "!dns MX via DoH"

set ok 1
foreach {e want} {"2+2" 4 "7/2" 3.5 "3.14*2" 6.28 "2^10" 1024 "sqrt(16)" 4 "pi*1" 3.1415926536 "1e3+1" 1001 "10 % 3" 1} {
    if {[catch {::utils::calc $e} r] || [::utils::num $r 10] ne $want} {puts "  calc $e -> $r"; set ok 0}
}
check $ok "calc arithmetic"
check {[catch {::utils::calc {exec rm -rf /}}] && [catch {::utils::calc {[exit]}}] && [catch {::utils::calc {9**9**9**9}}] == 0} "calc rejects commands, survives huge powers"

set ::utils::datadir utdata
array unset ::utils::quotes
set ::out {}
::utils::cmd_quote a a@b * #test "add hola mundo"
::utils::cmd_quote a a@b * #test "add otra frase"
::utils::cmd_quote a a@b * #test "2"
expect "*Quote :: #2/2 otra frase (By: a | Added: *)" "!quote add + show"
::utils::cmd_quote a a@b * #test "search HOLA"
expect "*Matches: #1" "!quote search"
::utils::cmd_quote a a@b * #test "del 1"
array unset ::utils::quotes
::utils::quotes_load
check {[llength $::utils::quotes(#test)] == 1} "quotes persisted"

