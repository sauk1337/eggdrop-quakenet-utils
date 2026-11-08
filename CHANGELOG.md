# Changelog

## 1.2.2 - 2026-11-04

### Changed
- `ipinfo.tcl` answers much faster. Each of its 3 lines is sent as soon as the services it needs have answered, instead of waiting for the slowest one, and the lines go out at once instead of through the slow help queue. A service that hangs (RDAP often does) no longer holds the answer for 15 seconds: after 6 seconds (`::ipinfo::timeout`) the rest is printed with what is in.
- `antiproxy.tcl`: `!pcheck <nick>` on a `+antiproxy` channel now applies the action (kickban) when the user is detected, instead of only reporting it. Useful for users who joined while the action was `warn`. Users authed with Q are still only reported.
- `antiproxy.tcl`: with `action` set to `warn`, the log now says "not acting (action is warn)", so a detection that isn't acted on is clear.

### Added
- `antiproxy.tcl`: the partyline commands can also be used in the channel: `!pwhite add|del|list [mask]` and `!pcache [clear]` (global `o`, answered by notice; `!pcache` shows up to 5 blocked IPs and the totals) and `!pstats` (ops, in the channel).
- `web.tcl`: `::web::say target text ?queue?` chooses the output queue (`help`, `serv`, `quick` or `now`). `now` uses `putnow`, capped at 4 lines every 4 seconds so the bot can't flood itself off. `::web::get` takes an optional timeout.
- `antiproxy.tcl` runs on its own, without web.tcl: it brings a minimal copy of the output style. A standalone package (script, settings file, README) is published separately as eggdrop-antiproxy.

## 1.2.1 - 2026-10-30

### Fixed
- `github.tcl`: new repositories weren't announced until GitHub's events feed showed them, which GitHub warns can take from 30 seconds to several hours. Each check now also reads the profile's repository list, which is up to date at once, so a new repository is announced on the next check. The events feed still brings pushes, releases, PRs and issues, and the same repository is never announced twice.
- `github.tcl`: `!gh check` now says so when there is nothing new, instead of staying silent.

### Added
- `github.tcl`: `!gh repo <user>` lists a profile's latest repositories.

## 1.2.0 - 2026-10-30

### Added
- `github.tcl`: GitHub profile tracker. Each channel chooses which users/organisations to follow (`!gh add/del/list`) and which activity to announce (`!gh filter`: pushes, releases, new repos/tags, forks, PRs, issues; stars optional). Uses ETag so unchanged profiles don't spend the API limit, waits by itself when the limit is reached, and has `!gh <user>` / `!gh repo <owner/repo>` cards. Optional token in `secrets.tcl`.
- `dist/eggdrop-quakenet-utils.tcl`: every script in one file, built with `tclsh build/build.tcl`, with the guide and a table of contents on top. Load it with a single `source` line.
- `help.tcl`: `.guide` prints a MOTD-style guide (quick start and every command); `!help !command` explains one command; commands are shown in bold.

### Changed
- One output style for every script, set in `web.tcl` (`::web::line`, `::web::lbl`...): `Tag :: title (Label: value | Label: value)` with an orange bold tag, a bold title, blue labels and orange separators. Colours can be changed in `::web::style`.
- Pure ASCII decoration, so old mIRC versions without UTF-8 show it right: no emojis, `·`, `—` or `…`. Typographic quotes, dashes and ellipses coming from websites are turned into ASCII too (`::web::ascii_punct`).
- `antiproxy.tcl` is stricter with throwaway proxies:
  - a bare IP without reverse DNS that already has datacenter/VPN hints gets +1 (`bare_ip_weight`), so a VPS proxy reaches 3 while a BNC with a hostname stays at 2;
  - a proxycheck.io "VPN" with a risk score of 75 or more counts as a proxy (`proxycheck_risk`);
  - the final decision is checked again once every answer is in, so no user ends "clean" above the threshold;
  - log channel lines use the new style and show the score, reasons and location.
- Kick reasons and partyline output stay plain text.

### Fixed
- `tools.tcl`: the greeting setting is now `greet-msg`. It was called `greet`, which clashes with Eggdrop's built-in `+greet` flag, so channels with `+greet` sent "1" by notice to everyone who joined.

## 1.1.0 - 2026-10-26

### Added
- `reminders.tcl`: `!remind`, `!at`, recurring reminders, `!snooze`, per-user timezones, delivery when the person comes back, Q account aware.
- `feeds.tcl`: RSS/Atom announcer with ETag/If-Modified-Since, filters, per-feed interval and shortcuts (`github:`, `youtube:`, `reddit:`, `mastodon:`, `bsky:`).
- `wiki.tcl`: `!wiki` in any language, disambiguation, `!wikisearch`, `!wikirandom`, `!otd` and a daily post.
- `dictionary.tcl`: `!define` (dictionaryapi.dev + Wiktionary), `!synonyms`/`!antonyms`/`!rhymes` (Datamuse), `!ud` (opt-in), `!wotd`.
- `countdown.tcl`: event countdowns with milestone announcements, yearly events and channel timezones.
- `ask.tcl`: `!ask` with the Claude API (`claude-opus-5-5`, server-side fallback) or any OpenAI-compatible endpoint such as a local Ollama. Includes quotas and a short per-channel memory.
- `guard.tcl`: rewrite of the 2005 "protection v1.4b" script for Eggdrop 1.8+. Q only, since L was retired from QuakeNet. Not loaded by default.
- `help.tcl`: `!commands` / `!help` / `!scripts` show only what the asking user can use, a few lines by notice.
- `timeutil.tcl`: shared date parser (English and Spanish).
- `web.tcl`: POST, raw fetch with headers, JSON encoding and HTML helpers.
- `secrets.tcl.example`, `.gitignore`, `LICENSE`, test harness.

### Changed
- `antiproxy.tcl` is BNC friendly. proxycheck.io "VPN" (datacenter ranges, where BNCs live) weighs 1 instead of 3. With the new `allow_authed` (on by default), users authed with Q are let through even if their IP scores as a proxy; this is checked with WHOX before acting.
- Every script has a standard header: description, requirements, setup and commands.
- Top-level loops run in their own scope, so no global variables are overwritten.
- `tools.tcl` no longer has `!help` (moved to `help.tcl`).

### Fixed
- `qauth.tcl`: tcllib's SHA-256 package is `sha256` (commands in `::sha2`); `package require sha2` always failed, so CHALLENGEAUTH was never used.
- `ipinfo.tcl`: answers were sent to an empty target.
- `ipinfo.tcl` / `utils.tcl`: `!ip` and `!quote add` failed for users unknown to the bot (`matchattr` with `-|-`).
- `chanstats.tcl`: every line was counted as a question.
- `youtube.tcl`: any channel line started the cooldown and swallowed the next link.
- `urltitle.tcl`: guard against a progress callback after the request finished.

## 1.0.0 - 2026-10-26

### Added
- First release:
  - `qauth.tcl`, `antiproxy.tcl`, `ipinfo.tcl`, `utils.tcl`, `youtube.tcl`, `urltitle.tcl`, `chanstats.tcl`, `tools.tcl`;
  - QuakeNet `eggdrop.conf`.
