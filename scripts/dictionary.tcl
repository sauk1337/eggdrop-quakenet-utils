# =====================================================================
#  dictionary.tcl  v1.2.0  -  Definitions, synonyms, rhymes, Urban
#                             Dictionary and word of the day
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    English definitions with phonetics and examples (dictionaryapi.dev),
#    definitions of words in other languages from Wiktionary, synonyms /
#    antonyms / rhymes (Datamuse), Urban Dictionary (opt-in per channel,
#    it is often NSFW) and Merriam-Webster's word of the day with an
#    optional daily post. No API keys.
#
#  REQUIREMENTS
#    web.tcl (load it first), tcl-tls
#
#  SETUP
#    .chanset #chan +dict
#    .chanset #chan dict-lang es        default language of !define (en)
#    .chanset #chan +ud                 enable Urban Dictionary
#    .chanset #chan +wotd               daily word of the day
#
#  COMMANDS (channel)
#    !define <word>            definitions             (!def, !dict)
#    !define <lang>:<word>     word in another language (!define es:casa)
#    !synonyms <word>          synonyms                (!syn)
#    !antonyms <word>          antonyms                (!ant)
#    !rhymes <word>            words that rhyme
#    !ud <term> [n]            Urban Dictionary, n-th definition
#    !udrandom                 a random Urban Dictionary entry
#    !wotd                     word of the day
# =====================================================================

namespace eval ::dictionary {
    # ------------------------- CONFIGURATION -------------------------
    variable default_lang "en"
    variable maxlen 380              ;# characters per answer
    variable max_senses 3
    variable throttle 5
    variable wotd_feed "https://www.merriam-webster.com/wotd/feed/rss2"
    variable wotd_hour 10            ;# hour of the daily post (bot time)

    # --------------------- STATE (do not touch) ---------------------
    variable last
    variable wotd_cache              ;# {date line}
}

setudef flag dict
setudef flag ud
setudef flag wotd
setudef str dict-lang

proc ::dictionary::flood {uhost} {
    variable last
    variable throttle
    set h [lindex [split $uhost @] end]
    set now [clock seconds]
    if {[info exists last($h)] && $now - $last($h) < $throttle} {return 1}
    set last($h) $now
    return 0
}

proc ::dictionary::lang {chan} {
    variable default_lang
    set l [channel get $chan dict-lang]
    if {[regexp {^[a-z]{2,3}$} $l]} {return $l}
    return $default_lang
}

proc ::dictionary::clean_word {w} {
    string trim [string tolower $w] " .,;:!?\"'()"
}

# ---------------------------- !define ----------------------------

proc ::dictionary::define {target l word} {
    if {$l eq "en"} {
        ::web::get "https://api.dictionaryapi.dev/api/v2/entries/en/[::http::mapReply $word]" \
            [list ::dictionary::dictapi_done $target $word]
    } else {
        wiktionary $target $l $word
    }
}

proc ::dictionary::dictapi_done {target word ok code body} {
    variable maxlen
    variable max_senses
    if {!$ok || [catch {::web::json $body} d] || ![llength $d]} {
        # Not in dictionaryapi.dev: try Wiktionary before giving up
        wiktionary $target en $word
        return
    }
    set e [lindex $d 0]
    set phon [::web::dget $e phonetic]
    if {$phon eq ""} {
        foreach p [::web::dget $e phonetics] {
            if {[::web::dget $p text] ne ""} {set phon [::web::dget $p text]; break}
        }
    }
    set parts {}
    set n 0
    set example ""
    set syns {}
    foreach m [::web::dget $e meanings] {
        set pos [::web::dget $m partOfSpeech]
        set defs {}
        foreach df [::web::dget $m definitions] {
            if {$n >= $max_senses} break
            lappend defs "[incr n]. [::web::dget $df definition]"
            if {$example eq "" && [::web::dget $df example] ne ""} {set example [::web::dget $df example]}
        }
        lappend syns {*}[lrange [::web::dget $m synonyms] 0 3]
        if {[llength $defs]} {lappend parts "[::web::dim ($pos)] [join $defs { }]"}
        if {$n >= $max_senses} break
    }
    set line "[::web::tag Define] :: [::web::b [::web::dget $e word]]"
    if {$phon ne ""} {append line " [::web::dim $phon]"}
    append line " [join $parts { }]"
    set extra {}
    if {$example ne ""} {lappend extra [::web::lbl Example "\"$example\""]}
    if {[llength $syns]} {lappend extra [::web::lbl Synonyms [join [lrange [lsort -unique $syns] 0 4] {, }]]}
    if {[llength $extra]} {append line " ([::web::fields $extra])"}
    ::web::say $target [::web::trim $line [expr {$maxlen + 40}]]
}

# Wiktionary REST: definitions grouped by language code
proc ::dictionary::wiktionary {target l word} {
    ::web::get "https://en.wiktionary.org/api/rest_v1/page/definition/[::http::mapReply $word]" \
        [list ::dictionary::wikt_done $target $l $word]
}

proc ::dictionary::wikt_done {target l word ok code body} {
    variable maxlen
    variable max_senses
    if {!$ok || [catch {::web::json $body} d] || ![dict exists $d $l]} {
        # Lower-case retry (Wiktionary is case sensitive)
        if {$ok && $word ne [string tolower $word]} {
            wiktionary $target $l [string tolower $word]
            return
        }
        ::web::say $target [::web::msg Define "No definition found for \"$word\"[expr {$l ne "en" ? " ($l)" : ""}]."]
        return
    }
    set parts {}
    set n 0
    set lname ""
    foreach entry [dict get $d $l] {
        set lname [::web::dget $entry language]
        set defs {}
        foreach df [::web::dget $entry definitions] {
            set txt [::web::unhtml [::web::dget $df definition]]
            if {$txt eq "" || $n >= $max_senses} continue
            lappend defs "[incr n]. $txt"
        }
        if {[llength $defs]} {lappend parts "[::web::dim ([string tolower [::web::dget $entry partOfSpeech]])] [join $defs { }]"}
        if {$n >= $max_senses} break
    }
    if {![llength $parts]} {
        ::web::say $target [::web::msg Define "No definition found for \"$word\"."]
        return
    }
    set line "[::web::tag Define] :: [::web::b $word][expr {$lname ne "" && $l ne "en" ? " [::web::dim \[$lname\]]" : ""}] [join $parts { }]"
    ::web::say $target [::web::trim $line [expr {$maxlen + 40}]]
}

bind pub - !define ::dictionary::pub_define
bind pub - !def ::dictionary::pub_define
bind pub - !dict ::dictionary::pub_define
bind pub - !definir ::dictionary::pub_define
proc ::dictionary::pub_define {nick uhost hand chan text} {
    if {![channel get $chan dict] || [flood $uhost]} {return 0}
    set q [string trim $text]
    set l [lang $chan]
    regexp {^([a-z]{2,3}):\s*(.+)$} $q -> l q
    set q [clean_word $q]
    if {$q eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !define] <word> | [::web::b !define] <lang>:<word>"
        return 0
    }
    define $chan $l $q
    return 1
}

# ------------------------ Datamuse: syn/ant/rhymes ------------------------

proc ::dictionary::datamuse {target rel label word} {
    ::web::get "https://api.datamuse.com/words?[::web::query $rel $word max 15]" \
        [list ::dictionary::datamuse_done $target $label $word]
}

proc ::dictionary::datamuse_done {target label word ok code body} {
    set words {}
    if {$ok && ![catch {::web::json $body} d]} {
        foreach w $d {lappend words [::web::dget $w word]}
    }
    if {![llength $words]} {
        ::web::say $target [::web::msg [string totitle $label] "No $label found for \"$word\"."]
        return
    }
    ::web::say $target "[::web::tag [string totitle $label]] :: [::web::b $word] [join $words {, }]"
}

apply {{} {
    foreach {cmd rel label} {
        !synonyms rel_syn synonyms  !syn rel_syn synonyms  !sinonimos rel_syn synonyms
        !antonyms rel_ant antonyms  !ant rel_ant antonyms
        !rhymes rel_rhy rhymes      !rhyme rel_rhy rhymes
    } {
        bind pub - $cmd [list ::dictionary::pub_datamuse $rel $label]
    }
}}
proc ::dictionary::pub_datamuse {rel label nick uhost hand chan text} {
    if {![channel get $chan dict] || [flood $uhost]} {return 0}
    set w [clean_word $text]
    if {$w eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !synonyms]|[::web::b !antonyms]|[::web::b !rhymes] <english word>"
        return 0
    }
    datamuse $chan $rel $label $w
    return 1
}

# --------------------------- Urban Dictionary ---------------------------

proc ::dictionary::ud_clean {s} {
    # [word] marks links on UD
    regsub -all {\[([^\]]*)\]} $s {\1} s
    ::web::unhtml $s
}

proc ::dictionary::ud_done {target term n ok code body} {
    variable maxlen
    if {!$ok || [catch {::web::json $body} d] || ![llength [::web::dget $d list]]} {
        ::web::say $target [::web::msg Urban "Nothing found for \"$term\"."]
        return
    }
    set list [lsort -integer -decreasing -index 1 [lmap e [::web::dget $d list] {list $e [::web::dget $e thumbs_up]}]]
    set total [llength $list]
    if {$n < 1 || $n > $total} {set n 1}
    set e [lindex $list [expr {$n - 1}] 0]
    set line "[::web::tag Urban] :: [::web::b [::web::dget $e word]] [::web::dim \[$n/$total\]] [::web::trim [ud_clean [::web::dget $e definition]] $maxlen]"
    set ex [ud_clean [::web::dget $e example]]
    set extra {}
    if {$ex ne ""} {lappend extra [::web::lbl Example [::web::trim $ex 120]]}
    lappend extra [::web::lbl Up [::web::dget $e thumbs_up]] [::web::lbl Down [::web::dget $e thumbs_down]]
    append line " ([::web::fields $extra])"
    ::web::say $target $line
}

bind pub - !ud ::dictionary::pub_ud
bind pub - !urban ::dictionary::pub_ud
proc ::dictionary::pub_ud {nick uhost hand chan text} {
    if {![channel get $chan ud] || [flood $uhost]} {return 0}
    set w [regexp -all -inline {\S+} $text]
    set n 1
    if {[llength $w] > 1 && [string is integer -strict [lindex $w end]]} {
        set n [lindex $w end]
        set w [lrange $w 0 end-1]
    }
    set term [join $w]
    if {$term eq ""} {
        puthelp "NOTICE $nick :Usage: [::web::b !ud] <term> \[n\]"
        return 0
    }
    ::web::get "https://api.urbandictionary.com/v0/define?[::web::query term $term]" \
        [list ::dictionary::ud_done $chan $term $n]
    return 1
}

bind pub - !udrandom ::dictionary::pub_udrandom
proc ::dictionary::pub_udrandom {nick uhost hand chan text} {
    if {![channel get $chan ud] || [flood $uhost]} {return 0}
    ::web::get "https://api.urbandictionary.com/v0/random" [list ::dictionary::ud_done $chan random 1]
    return 1
}

# ---------------------------- Word of the day ----------------------------

proc ::dictionary::wotd {target} {
    variable wotd_feed
    variable wotd_cache
    set today [clock format [clock seconds] -format %Y-%m-%d]
    if {[info exists wotd_cache] && [lindex $wotd_cache 0] eq $today} {
        ::web::say $target [lindex $wotd_cache 1]
        return
    }
    ::web::get $wotd_feed [list ::dictionary::wotd_done $target $today]
}

proc ::dictionary::wotd_done {target today ok code body} {
    variable wotd_cache
    variable maxlen
    set item ""
    if {$ok} {regexp -nocase {<item[\s>].*?</item>} $body item}
    if {$item eq ""} {
        ::web::say $target [::web::msg "Word of the day" "Not available right now."]
        return
    }
    set word ""
    set def ""
    set link ""
    regexp -nocase {<title[^>]*>(.*?)</title>} $item -> word
    regexp -nocase {<link[^>]*>(.*?)</link>} $item -> link
    if {![regexp -nocase {<merriam:shortdef[^>]*>(.*?)</merriam:shortdef>} $item -> def]} {
        regexp -nocase {<description[^>]*>(.*?)</description>} $item -> def
    }
    set word [::web::unhtml $word]
    set def [::web::trim [::web::unhtml $def] $maxlen]
    set line "[::web::tag {Word of the day}] :: [::web::b $word] $def"
    set link [string trim [::web::unhtml $link]]
    if {$link ne ""} {append line "[::web::sep]$link"}
    set wotd_cache [list $today $line]
    ::web::say $target $line
}

bind pub - !wotd ::dictionary::pub_wotd
proc ::dictionary::pub_wotd {nick uhost hand chan text} {
    if {![channel get $chan dict] || [flood $uhost]} {return 0}
    wotd $chan
    return 1
}

bind time - "00 * * * *" ::dictionary::hourly
proc ::dictionary::hourly {min hour day month year} {
    variable wotd_hour
    if {[scan $hour %d] != $wotd_hour} return
    foreach chan [channels] {
        if {[channel get $chan wotd] && [botonchan $chan]} {wotd $chan}
    }
}

putlog "dictionary.tcl loaded"
