# =====================================================================
#  qauth.tcl  v1.1.0  -  Q authentication and +x for the bot
# ---------------------------------------------------------------------
#  Part of eggdrop-quakenet-utils (Eggdrop 1.9+ / Tcl 8.6, Linux)
#  License: MIT (see LICENSE)
#
#  DESCRIPTION
#    Authenticates the bot with QuakeNet's Q using CHALLENGEAUTH
#    (HMAC-SHA256), so the password never travels in clear text, then
#    sets user mode +x (host <account>.users.quakenet.org). Channels are
#    joined only after that, so the bot's real IP is never shown.
#    Authentication only: it never asks Q for op/invite/unban.
#    Without tcllib it falls back to AUTH to Q@CServe.quakenet.org.
#
#  REQUIREMENTS
#    tcllib (package sha256) for CHALLENGEAUTH: apt install tcllib
#
#  SETUP
#    In secrets.tcl:  set ::qauth::user "BotAccount"
#                     set ::qauth::pass "password"
#    Load it before the other scripts.
#
#  COMMANDS
#    none on IRC
#  PARTYLINE
#    .qauth                    authenticate again (owner)
# =====================================================================

namespace eval ::qauth {
    # ------------------------- CONFIGURATION -------------------------
    variable user "BotAccount"       ;# the bot's Q account
    variable pass "BotPassword"
    variable hidehost 1              ;# set +x after authenticating
    variable holdjoin 1              ;# don't join channels until authed
    variable timeout 45              ;# secs without an answer from Q -> join anyway

    # --------------------- STATE (do not touch) ---------------------
    variable qhost "TheQBot@CServe.quakenet.org"
    variable authed
    variable sha 0
    if {![info exists authed]} {set authed 0}
}

setudef flag qauth-held

if {![catch {package require sha256}]} {
    set ::qauth::sha 1
} else {
    putlog "qauth: tcllib (sha256) not available, using AUTH against Q@CServe.quakenet.org"
}

bind evnt - preinit-server    ::qauth::ev_preinit
bind evnt - init-server       ::qauth::ev_init
bind evnt - disconnect-server ::qauth::ev_disconnect
bind notc - *                 ::qauth::on_notice
bind dcc n qauth              ::qauth::dcc_qauth

# RFC1459 lowercase, the way Q does it
proc ::qauth::irclower {s} {
    string map [list "\[" "\{" "\]" "\}" "\\" "|" "~" "^"] [string tolower $s]
}

proc ::qauth::response {challenge} {
    variable user
    variable pass
    set u [encoding convertto utf-8 [irclower $user]]
    set p [encoding convertto utf-8 [string range $pass 0 9]]
    set key [::sha2::sha256 -hex -- "$u:[::sha2::sha256 -hex -- $p]"]
    return [::sha2::hmac -hex -key $key -- $challenge]
}

proc ::qauth::start {} {
    variable sha
    variable user
    variable pass
    if {$sha} {
        putquick "PRIVMSG Q@CServe.quakenet.org :CHALLENGE"
    } else {
        putquick "PRIVMSG Q@CServe.quakenet.org :AUTH $user $pass"
    }
}

# Before registering with the server: mark channels inactive
proc ::qauth::ev_preinit {type} {
    variable holdjoin
    variable authed
    set authed 0
    if {!$holdjoin} return
    foreach chan [channels] {
        if {![channel get $chan inactive]} {
            channel set $chan +inactive +qauth-held
        }
    }
}

proc ::qauth::ev_init {type} {
    variable timeout
    foreach t [utimers] {
        if {[string match ::qauth::* [lindex $t 1]]} {killutimer [lindex $t 2]}
    }
    start
    utimer $timeout ::qauth::fallback
}

proc ::qauth::ev_disconnect {type} {
    variable authed
    set authed 0
}

proc ::qauth::on_notice {nick uhost hand text dest} {
    variable qhost
    variable user
    if {![string equal -nocase $nick Q] || ![string equal -nocase $uhost $qhost]} {return 0}

    if {[regexp {^CHALLENGE ([0-9a-fA-F]+) (.*)$} $text -> chal algos]} {
        if {[lsearch -exact $algos HMAC-SHA256] < 0} {
            putlog "qauth: Q does not offer HMAC-SHA256, using AUTH"
            variable pass
            putquick "PRIVMSG Q@CServe.quakenet.org :AUTH $user $pass"
        } else {
            putquick "PRIVMSG Q@CServe.quakenet.org :CHALLENGEAUTH $user [response $chal] HMAC-SHA256"
        }
        return 1
    }
    if {[string match -nocase "*now logged in as*" $text] || [string match -nocase "*already authed*" $text]} {
        authed_ok
        return 1
    }
    if {[string match -nocase "*incorrect*" $text] || [string match -nocase "*suspended*" $text]} {
        putlog "qauth: Q authentication ERROR: $text"
        joinall
        return 1
    }
    return 0
}

proc ::qauth::authed_ok {} {
    variable authed
    variable hidehost
    variable user
    if {$authed} return
    set authed 1
    putlog "qauth: authed with Q as $user"
    if {$hidehost} {putquick "MODE $::botnick +x"}
    utimer 3 ::qauth::joinall
}

proc ::qauth::joinall {} {
    foreach chan [channels] {
        if {[channel get $chan qauth-held]} {
            channel set $chan -inactive -qauth-held
        }
    }
}

proc ::qauth::fallback {} {
    variable authed
    if {!$authed} {
        putlog "qauth: no answer from Q, joining channels unauthenticated"
        joinall
    }
}

proc ::qauth::dcc_qauth {hand idx text} {
    variable authed
    set authed 0
    start
    putdcc $idx "qauth: authenticating with Q..."
    return 1
}

putlog "qauth.tcl loaded (CHALLENGEAUTH [expr {$::qauth::sha ? "HMAC-SHA256" : "not available -> AUTH"}])"
