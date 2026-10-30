# =====================================================================
#  utils.tcl  v1.2.0  -  Weather, time, currency, crypto, countries,
#                        DNS, calculator and quotes
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Everyday tools with free APIs that need no key: Open-Meteo,
#    Frankfurter (ECB rates), CoinGecko, REST Countries and Cloudflare
#    DNS over HTTPS. The calculator runs in a safe interpreter.
#
#  REQUIREMENTS
#    web.tcl (load it first), tcl-tls, tzdata
#
#  SETUP
#    .chanset #chan +utils
#
#  COMMANDS (channel)
#    !weather | !w <city[, CC]>        current weather
#    !forecast <city[, CC]>            4-day forecast
#    !time <city[, CC]>                local time
#    !convert | !cur <amount> <FROM> <TO>
#    !crypto <coin> [currency]
#    !country <name|code>
#    !dns <host> [A|AAAA|MX|TXT|NS|CNAME|SOA|CAA|SRV]
#    !calc <expression>
#    !quote [n|add <text>|del <n>|search <word>]   (del: ops)
# =====================================================================

namespace eval ::utils {
    # ------------------------- CONFIGURATION -------------------------
    variable throttle_user 5         ;# seconds between commands per user
    variable throttle_chan 2         ;# seconds between commands per channel
    variable quote_flags "-|-"       ;# who can add quotes
    variable quote_del_flags "o|o"   ;# who can delete quotes
    variable datadir "utils"
    variable units metric            ;# metric | imperial
    variable fx_url "https://api.frankfurter.dev/v1/latest"

    # --------------------- STATE (do not touch) ---------------------
    variable quotes                  ;# quotes(chan) -> list of {time nick text}
}

setudef flag utils

# WMO weather codes used by Open-Meteo
namespace eval ::utils {
    variable wmo {
        0 {Clear sky} 1 {Mainly clear} 2 {Partly cloudy} 3 {Overcast}
        45 {Fog} 48 {Rime fog} 51 {Light drizzle} 53 {Drizzle}
        55 {Dense drizzle} 56 {Freezing drizzle} 57 {Freezing drizzle}
        61 {Light rain} 63 {Rain} 65 {Heavy rain} 66 {Freezing rain}
        67 {Freezing rain} 71 {Light snow} 73 {Snow} 75 {Heavy snow}
        77 {Snow grains} 80 {Rain showers} 81 {Rain showers}
        82 {Violent showers} 85 {Snow showers} 86 {Heavy snow showers}
        95 {Thunderstorm} 96 {Thunderstorm, hail} 99 {Thunderstorm, heavy hail}
    }
}

# ----------------------------- HELPERS -----------------------------

proc ::utils::ok {nick uhost chan} {
    variable throttle_user
    variable throttle_chan
    if {![channel get $chan utils]} {return 0}
    if {[::web::throttle "u,[lindex [split $uhost @] end]" $throttle_user]} {return 0}
    if {[::web::throttle "c,[string tolower $chan]" $throttle_chan]} {return 0}
    return 1
}

# Replies in the shared style: "Tag :: text"
proc ::utils::say {chan tag text} {
    ::web::say $chan [::web::msg $tag $text]
}

proc ::utils::compass {deg} {
    if {$deg eq ""} {return ""}
    lindex {N NE E SE S SW W NW} [expr {int(fmod($deg + 22.5, 360) / 45)}]
}

proc ::utils::wmo {code} {
    variable wmo
    if {[dict exists $wmo $code]} {return [dict get $wmo $code]}
    return "code $code"
}

# Rounds to n decimals and drops a trailing ".0"
proc ::utils::num {v {n 1}} {
    if {![string is double -strict $v]} {return $v}
    set s [format %.${n}f $v]
    if {[string first . $s] >= 0} {set s [string trimright [string trimright $s 0] .]}
    return $s
}

# Thousands separators
proc ::utils::big {n} {
    regsub -all {\d(?=(\d{3})+$)} [format %.0f $n] {&,}
}

# Geocoding: "city" or "city, CC" -> callback with a result dict or ""
proc ::utils::geocode {text callback} {
    set name [string trim $text]
    set q [list name $name count 1 language en format json]
    if {[regexp {^(.+?),\s*([A-Za-z]{2})$} $name -> city cc]} {
        set q [list name [string trim $city] count 1 language en format json countryCode [string toupper $cc]]
    }
    ::web::get "https://geocoding-api.open-meteo.com/v1/search?[::web::query {*}$q]" \
        [list ::utils::geocoded $callback]
}

proc ::utils::geocoded {callback ok code body} {
    set place ""
    if {$ok && ![catch {::web::json $body} d]} {
        set place [lindex [::web::dget $d results] 0]
    }
    {*}$callback $place
}

proc ::utils::placename {p} {
    set parts [list [::web::dget $p name]]
    set a [::web::dget $p admin1]
    if {$a ne "" && $a ne [lindex $parts 0]} {lappend parts $a}
    lappend parts [::web::dget $p country_code]
    join $parts ", "
}

# ----------------------------- WEATHER -----------------------------

bind pub - !weather ::utils::cmd_weather
bind pub - !w ::utils::cmd_weather
proc ::utils::cmd_weather {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    if {[string trim $text] eq ""} {say $chan Weather "Usage: [::web::b !weather] <city>  (e.g. !weather Madrid, ES)"; return 0}
    geocode $text [list ::utils::weather_geo $chan current $text]
    return 1
}

bind pub - !forecast ::utils::cmd_forecast
proc ::utils::cmd_forecast {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    if {[string trim $text] eq ""} {say $chan Forecast "Usage: [::web::b !forecast] <city>"; return 0}
    geocode $text [list ::utils::weather_geo $chan forecast $text]
    return 1
}

proc ::utils::weather_geo {chan mode text place} {
    variable units
    if {$place eq ""} {say $chan [expr {$mode eq "current" ? "Weather" : "Forecast"}] "City not found: $text"; return}
    set q [list latitude [::web::dget $place latitude] longitude [::web::dget $place longitude] \
        timezone auto forecast_days 4 \
        current temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m \
        daily weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset]
    if {$units eq "imperial"} {lappend q temperature_unit fahrenheit wind_speed_unit mph precipitation_unit inch}
    ::web::get "https://api.open-meteo.com/v1/forecast?[::web::query {*}$q]" \
        [list ::utils::weather_done $chan $mode $place]
}

proc ::utils::weather_done {chan mode place ok code body} {
    variable units
    set tag [expr {$mode eq "current" ? "Weather" : "Forecast"}]
    if {!$ok || [catch {::web::json $body} d]} {say $chan $tag "Weather service unavailable, try again later."; return}
    # Plain ASCII units: old clients show the degree sign as mojibake
    set t [expr {$units eq "imperial" ? "F" : "C"}]
    set w [expr {$units eq "imperial" ? "mph" : "km/h"}]
    set c [::web::dget $d current]
    set day [::web::dget $d daily]
    set name [placename $place]
    set f {}
    if {$mode eq "current"} {
        #   Weather :: Madrid, ES (Now: Partly cloudy, 21.3C | Feels: 20.1C | ...)
        lappend f [::web::lbl Now "[wmo [::web::dget $c weather_code]], [num [::web::dget $c temperature_2m]]$t"]
        lappend f [::web::lbl Feels "[num [::web::dget $c apparent_temperature]]$t"]
        lappend f [::web::lbl Humidity "[::web::dget $c relative_humidity_2m]%"]
        lappend f [::web::lbl Wind "[num [::web::dget $c wind_speed_10m] 0] $w [compass [::web::dget $c wind_direction_10m]] (gusts [num [::web::dget $c wind_gusts_10m] 0])"]
        lappend f [::web::lbl Precip "[num [::web::dget $c precipitation]] [expr {$units eq "imperial" ? "in" : "mm"}]"]
        lappend f [::web::lbl Today "[num [lindex [::web::dget $day temperature_2m_min] 0] 0]-[num [lindex [::web::dget $day temperature_2m_max] 0] 0]$t, rain [lindex [::web::dget $day precipitation_probability_max] 0]%"]
        lappend f [::web::lbl Sun "[string range [lindex [::web::dget $day sunrise] 0] end-4 end] - [string range [lindex [::web::dget $day sunset] 0] end-4 end]"]
    } else {
        #   Forecast :: Madrid, ES (Mon: Partly cloudy 12-24C, rain 5% | Tue: ...)
        foreach date [::web::dget $day time] code [::web::dget $day weather_code] \
                lo [::web::dget $day temperature_2m_min] hi [::web::dget $day temperature_2m_max] \
                pp [::web::dget $day precipitation_probability_max] {
            set dn [clock format [clock scan $date -format %Y-%m-%d] -format %a]
            lappend f [::web::lbl $dn "[wmo $code] [num $lo 0]-[num $hi 0]$t, rain ${pp}%"]
        }
    }
    ::web::say $chan [::web::line $tag $name $f]
}

# ------------------------------ TIME ------------------------------

bind pub - !time ::utils::cmd_time
proc ::utils::cmd_time {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    if {[string trim $text] eq ""} {say $chan Time "Usage: [::web::b !time] <city>"; return 0}
    geocode $text [list ::utils::time_done $chan $text]
    return 1
}

proc ::utils::time_done {chan text place} {
    if {$place eq ""} {say $chan Time "City not found: $text"; return}
    set tz [::web::dget $place timezone]
    if {[catch {clock format [clock seconds] -timezone :$tz -format "%A %d %B %Y, %H:%M:%S %Z (UTC%z)"} now]} {
        say $chan Time "Unknown timezone $tz (install tzdata)."
        return
    }
    ::web::say $chan [::web::line Time [placename $place] [list $now]]
}

# ---------------------------- CURRENCY ----------------------------

bind pub - !convert ::utils::cmd_convert
bind pub - !cur ::utils::cmd_convert
proc ::utils::cmd_convert {nick uhost hand chan text} {
    variable fx_url
    if {![ok $nick $uhost $chan]} {return 0}
    # Accept "100 EUR USD", "100 EUR to USD", "EUR USD"
    set args [lsearch -all -inline -not -exact [split [string toupper [string trim $text]]] TO]
    set args [lsearch -all -inline -not -exact $args IN]
    if {[llength $args] == 2} {set args [linsert $args 0 1]}
    lassign $args amount from to
    set amount [string map {, .} $amount]
    if {![string is double -strict $amount] || ![regexp {^[A-Z]{3}$} $from] || ![regexp {^[A-Z]{3}$} $to]} {
        say $chan Convert "Usage: [::web::b !convert] <amount> <FROM> <TO>  (e.g. !convert 100 EUR USD)"
        return 0
    }
    if {$from eq $to} {say $chan Convert [::web::b "$amount $from = $amount $to"]; return 1}
    ::web::get "$fx_url?[::web::query base $from symbols $to]" \
        [list ::utils::convert_done $chan $amount $from $to]
    return 1
}

proc ::utils::convert_done {chan amount from to ok code body} {
    if {!$ok || [catch {::web::json $body} d] || [::web::dget $d rates $to] eq ""} {
        say $chan Convert "Can't convert $from to $to (ECB rates cover ~30 major currencies; use !crypto for coins)."
        return
    }
    set rate [::web::dget $d rates $to]
    set res [expr {$amount * $rate}]
    #   Convert :: 100 EUR = 108.42 USD (Rate: 1 EUR = 1.0842 USD | Source: ECB 2026-10-23)
    set title "[num $amount 2] $from = [num $res [expr {$res < 1 ? 6 : 2}]] $to"
    ::web::say $chan [::web::line Convert $title [list [::web::lbl Rate "1 $from = [num $rate 6] $to"] [::web::lbl Source "ECB [::web::dget $d date]"]]]
}

bind pub - !crypto ::utils::cmd_crypto
proc ::utils::cmd_crypto {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    lassign [split [string tolower [string trim $text]]] coin vs
    if {$coin eq ""} {say $chan Crypto "Usage: [::web::b !crypto] <coin> \[currency\]  (e.g. !crypto bitcoin eur)"; return 0}
    if {$vs eq ""} {set vs usd}
    set map {btc bitcoin eth ethereum sol solana xrp ripple ada cardano doge dogecoin ltc litecoin dot polkadot bnb binancecoin usdt tether xmr monero trx tron}
    if {[dict exists $map $coin]} {set coin [dict get $map $coin]}
    ::web::get "https://api.coingecko.com/api/v3/simple/price?[::web::query ids $coin vs_currencies $vs include_24hr_change true]" \
        [list ::utils::crypto_done $chan $coin $vs]
    return 1
}

proc ::utils::crypto_done {chan coin vs ok code body} {
    if {!$ok || [catch {::web::json $body} d] || [::web::dget $d $coin $vs] eq ""} {
        say $chan Crypto "Unknown coin or currency ($coin / $vs). Use the CoinGecko id, e.g. bitcoin, ethereum."
        return
    }
    set p [::web::dget $d $coin $vs]
    set ch [::web::dget $d $coin ${vs}_24h_change]
    #   Crypto :: bitcoin (Price: 61234.5 EUR | 24h: -2.35%)
    set f [list [::web::lbl Price "[num $p [expr {$p < 1 ? 6 : 2}]] [string toupper $vs]"]]
    if {$ch ne ""} {
        if {$ch >= 0} {
            lappend f [::web::lbl 24h "\00303+[num $ch 2]%\003"]
        } else {
            lappend f [::web::lbl 24h "\00304[num $ch 2]%\003"]
        }
    }
    ::web::say $chan [::web::line Crypto $coin $f]
}

# ----------------------------- COUNTRY -----------------------------

bind pub - !country ::utils::cmd_country
proc ::utils::cmd_country {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    set q [string trim $text]
    if {$q eq ""} {say $chan Country "Usage: [::web::b !country] <name|code>"; return 0}
    set fields name,cca2,capital,region,subregion,population,area,currencies,languages,timezones,idd,tld,flag,car,continents
    if {[regexp {^[A-Za-z]{2,3}$} $q]} {
        set url "https://restcountries.com/v3.1/alpha/[string tolower $q]?fields=$fields"
    } else {
        set url "https://restcountries.com/v3.1/name/[string map {+ %20} [::http::mapReply $q]]?fields=$fields"
    }
    ::web::get $url [list ::utils::country_done $chan $q]
    return 1
}

proc ::utils::country_done {chan q ok code body} {
    if {!$ok || [catch {::web::json $body} d]} {say $chan Country "Country not found: $q"; return}
    # /name returns a list, /alpha may return a single object
    if {[catch {dict exists $d name} single] || !$single} {set d [lindex $d 0]}
    set cur {}
    dict for {k v} [::web::dget $d currencies] {lappend cur "[::web::dget $v name] ($k[expr {[::web::dget $v symbol] ne "" ? " [::web::dget $v symbol]" : ""}])"}
    set lang {}
    dict for {k v} [::web::dget $d languages] {lappend lang $v}
    set idd "[::web::dget $d idd root][expr {[llength [::web::dget $d idd suffixes]] == 1 ? [lindex [::web::dget $d idd suffixes] 0] : ""}]"
    #   Country :: Spain (Official: Kingdom of Spain | Code: ES | Capital: Madrid | ...)
    set tz [join [lrange [::web::dget $d timezones] 0 2] {, }]
    if {[llength [::web::dget $d timezones]] > 3} {append tz "..."}
    set f [list \
        [::web::lbl Official [::web::dget $d name official]] \
        [::web::lbl Code [::web::dget $d cca2]] \
        [::web::lbl Capital [join [::web::dget $d capital] {, }]] \
        [::web::lbl Region "[::web::dget $d subregion], [::web::dget $d region]"] \
        [::web::lbl Population [big [::web::dget $d population]]] \
        [::web::lbl Area "[big [::web::dget $d area]] km2"] \
        [::web::lbl Currency [join $cur {, }]] \
        [::web::lbl Languages [join $lang {, }]] \
        [::web::lbl Phone $idd] \
        [::web::lbl TLD [join [::web::dget $d tld] {, }]] \
        [::web::lbl Drives [::web::dget $d car side]] \
        [::web::lbl TZ $tz]]
    ::web::say $chan [::web::line Country [::web::dget $d name common] $f]
}

# ------------------------------- DNS -------------------------------

bind pub - !dns ::utils::cmd_dns
proc ::utils::cmd_dns {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    lassign [split [string trim $text]] host type
    set type [string toupper $type]
    if {$type eq ""} {set type A}
    if {![regexp {^[A-Za-z0-9.-]+$} $host] || $type ni {A AAAA MX TXT NS CNAME SOA CAA PTR SRV}} {
        say $chan DNS "Usage: [::web::b !dns] <host> \[A|AAAA|MX|TXT|NS|CNAME|SOA|CAA|SRV\]"
        return 0
    }
    ::web::get "https://cloudflare-dns.com/dns-query?[::web::query name $host type $type]" \
        [list ::utils::dns_done $chan $host $type] {Accept application/dns-json}
    return 1
}

proc ::utils::dns_done {chan host type ok code body} {
    if {!$ok || [catch {::web::json $body} d]} {say $chan DNS "Lookup failed."; return}
    set status [::web::dget $d Status]
    if {$status == 3} {say $chan DNS "[::web::b $host]: NXDOMAIN (does not exist)"; return}
    set out {}
    foreach a [::web::dget $d Answer] {
        lappend out "[::web::dget $a data] (ttl [::web::dget $a TTL])"
    }
    if {![llength $out]} {say $chan DNS "[::web::b "$host $type"]: no records"; return}
    #   DNS :: example.com MX (10 mx1.example.com. (ttl 300) | 20 mx2...)
    set f [lrange $out 0 9]
    if {[llength $out] > 10} {lappend f "+[expr {[llength $out] - 10}] more"}
    ::web::say $chan [::web::line DNS "$host $type" $f]
}

# ------------------------------ CALC ------------------------------

proc ::utils::calc {e} {
    set e [string map {× * ÷ / , . ^ **} [string tolower [string trim $e]]]
    if {$e eq "" || [string length $e] > 120} {error "empty or too long"}
    if {![regexp {^[0-9a-z.+\-*/%() ]+$} $e]} {error "invalid characters"}
    # Numbers become doubles (7/2 = 3.5, no giant integers from **).
    # % needs integers, so expressions using it keep them (without **).
    set todouble [expr {[string first % $e] < 0}]
    if {!$todouble && [string first ** $e] >= 0} {error "can't mix % and ^"}
    set out ""
    set pos 0
    foreach span [regexp -all -inline -indices {\d+(?:\.\d*)?(?:e[-+]?\d+)?|\.\d+} $e] {
        lassign $span a b
        append out [string range $e $pos [expr {$a - 1}]]
        set tok [string range $e $a $b]
        if {$todouble && [string first . $tok] < 0 && [string first e $tok] < 0} {append tok .0}
        append out $tok
        set pos [expr {$b + 1}]
    }
    append out [string range $e $pos end]
    set funcs {abs acos asin atan atan2 ceil cos cosh exp floor fmod hypot log log10 max min pow round sin sinh sqrt tan tanh pi e}
    regsub -all {\d+(?:\.\d*)?(?:e[-+]?\d+)?|\.\d+} $out " " words
    foreach w [regexp -all -inline {[a-z]+} $words] {
        if {$w ni $funcs} {error "unknown function: $w"}
    }
    regsub -all {\mpi\M} $out {3.141592653589793} out
    regsub -all {\me\M(?!\()} $out {2.718281828459045} out
    set i [interp create -safe]
    try {
        set r [$i eval [list expr $out]]
    } finally {
        interp delete $i
    }
    return $r
}

bind pub - !calc ::utils::cmd_calc
proc ::utils::cmd_calc {nick uhost hand chan text} {
    if {![ok $nick $uhost $chan]} {return 0}
    if {[catch {calc $text} r]} {
        say $chan Calc "Error: $r"
    } else {
        say $chan Calc "[string trim $text] = [::web::b [num $r 10]]"
    }
    return 1
}

# ------------------------------ QUOTES ------------------------------

proc ::utils::quotes_file {} {
    variable datadir
    file mkdir $datadir
    file join $datadir quotes.db
}

proc ::utils::quotes_save {} {
    variable quotes
    set fd [open [quotes_file].tmp w]
    fconfigure $fd -encoding utf-8
    foreach c [array names quotes] {puts $fd [list $c $quotes($c)]}
    close $fd
    file rename -force [quotes_file].tmp [quotes_file]
}

proc ::utils::quotes_load {} {
    variable quotes
    set f [quotes_file]
    if {![file exists $f]} return
    set fd [open $f r]
    fconfigure $fd -encoding utf-8
    while {[gets $fd line] >= 0} {
        if {[llength $line] == 2} {set quotes([lindex $line 0]) [lindex $line 1]}
    }
    close $fd
}

proc ::utils::quote_show {chan n} {
    variable quotes
    set c [string tolower $chan]
    set q [lindex $quotes($c) [expr {$n - 1}]]
    lassign $q t who text
    #   Quote :: #2/5 text (By: nick | Added: 2026-10-30)
    set f [list [::web::lbl By $who] [::web::lbl Added [clock format $t -format %Y-%m-%d]]]
    say $chan Quote "[::web::b "#$n/[llength $quotes($c)]"] $text ([::web::fields $f])"
}

bind pub - !quote ::utils::cmd_quote
proc ::utils::cmd_quote {nick uhost hand chan text} {
    variable quotes
    variable quote_flags
    variable quote_del_flags
    if {![ok $nick $uhost $chan]} {return 0}
    set c [string tolower $chan]
    if {![info exists quotes($c)]} {set quotes($c) {}}
    set sub [string tolower [lindex [split [string trim $text]] 0]]
    set rest [string trim [string range [string trim $text] [string length $sub] end]]
    set n [llength $quotes($c)]
    switch -glob -- $sub {
        add {
            # "-|-" = everyone (matchattr returns 0 for users the bot doesn't know)
            if {($quote_flags ni {"" "-" "-|-"} && ![matchattr $hand $quote_flags $chan]) || $rest eq ""} {return 0}
            lappend quotes($c) [list [clock seconds] $nick $rest]
            quotes_save
            say $chan Quote "#[llength $quotes($c)] added."
        }
        del {
            if {![matchattr $hand $quote_del_flags $chan]} {return 0}
            if {![string is integer -strict $rest] || $rest < 1 || $rest > $n} {say $chan Quote "Usage: [::web::b "!quote del"] <1-$n>"; return 0}
            set quotes($c) [lreplace $quotes($c) [expr {$rest - 1}] [expr {$rest - 1}]]
            quotes_save
            say $chan Quote "#$rest deleted."
        }
        search {
            set hits {}
            set i 0
            foreach q $quotes($c) {
                incr i
                if {[string match -nocase "*$rest*" [lindex $q 2]]} {lappend hits "#$i"}
            }
            say $chan Quote [expr {[llength $hits] ? [::web::lbl Matches [join [lrange $hits 0 19] { }]] : "No quotes match \"$rest\"."}]
        }
        "" {
            if {!$n} {say $chan Quote "No quotes yet. Add one with [::web::b "!quote add"] <text>"; return 1}
            quote_show $chan [expr {int(rand() * $n) + 1}]
        }
        default {
            if {![string is integer -strict $sub] || $sub < 1 || $sub > $n} {
                say $chan Quote "Usage: [::web::b !quote] \[n|add <text>|del <n>|search <word>\]"
                return 0
            }
            quote_show $chan $sub
        }
    }
    return 1
}

if {![array exists ::utils::quotes]} {::utils::quotes_load}

putlog "utils.tcl loaded (weather, forecast, time, convert, crypto, country, dns, calc, quotes)"
