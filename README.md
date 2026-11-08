# eggdrop-quakenet-utils

A modern (2026) set of Eggdrop scripts for a **utility bot on QuakeNet**: anti-proxy gate, full IP lookups, everyday tools, YouTube and link titles, reminders, RSS feeds, a GitHub profile tracker, Wikipedia, dictionary, countdowns, AI answers and channel statistics.

The bot only uses Q to authenticate. Channel services and takeover protection are left to your main bots, although an optional channel-protection module (`guard.tcl`) is included.

- Eggdrop 1.9 / 1.10, Tcl 8.6, Linux.
- Every web request is asynchronous, so the bot never freezes waiting for a website.
- All APIs are free and need no key, except the optional ones marked below.
- Every script starts with a header explaining what it does, its requirements, setup and commands.
- Use the scripts one by one, or all of them in **one file**: `dist/eggdrop-quakenet-utils.tcl`.
- Clean, consistent output that old mIRC versions also show right (ASCII decoration only):

```
YouTube :: Kase O - Silencio (Channel: 7711zZ | Duration: 6:03 | Views: 6.7M | Likes: 36.4K)
Weather :: Madrid, ES (Now: Partly cloudy, 21.3C | Humidity: 40% | Wind: 12 km/h NE)
GitHub :: torvalds released torvalds/linux v6.20 (Name: Linux 6.20 | https://github.com/...)
```

The tag is orange and bold, the title bold, the labels blue and the separators orange. The colours are set in one place, `::web::style` in `web.tcl`.

## Scripts

| Script | What it does | Enable with | Main commands |
|---|---|---|---|
| `qauth.tcl` | Q auth (CHALLENGEAUTH) and +x before joining | — | `.qauth` |
| `antiproxy.tcl` | Proxy/VPN/Tor detection by score; invite gate for +i channels | `+antiproxy` `+antiproxy-gate` | `/msg bot enter #chan`, `!pcheck`, `!pwhite`, `!pcache`, `!pstats` |
| `ipinfo.tcl` | Location, ASN, RDAP range and abuse contact, proxy/VPN/Tor/DNSBL verdict | `+ipinfo` | `!ip` |
| `utils.tcl` | Weather, forecast, time, currency, crypto, countries, DNS, calculator, quotes | `+utils` | `!weather` `!time` `!convert` `!crypto` `!country` `!dns` `!calc` `!quote` |
| `youtube.tcl` | YouTube links (duration, views, live, Shorts, playlists) and search | `+youtube` | `!yt` |
| `urltitle.tcl` | Titles of pasted links (SSRF-safe) | `+urltitle` | automatic |
| `chanstats.tcl` | Channel statistics plus an HTML page | `+chanstats` | `!stats` `!top` `!hours` `!today` `!words` |
| `reminders.tcl` | Reminders, alarms, recurring reminders, snooze, timezones | `+reminders` | `!remind` `!at` `!reminders` `!snooze` |
| `feeds.tcl` | RSS/Atom: GitHub releases, YouTube channels, Reddit, Mastodon, Bluesky | `+feeds` | `!feed` |
| `github.tcl` | Tracks the GitHub profiles you choose and announces pushes, releases, PRs...; profile and repo cards | `+github` | `!gh` |
| `wiki.tcl` | Wikipedia summaries in any language, on this day | `+wiki` `+otd` | `!wiki` `!otd` |
| `dictionary.tcl` | Definitions, synonyms, rhymes, Urban Dictionary, word of the day | `+dict` `+ud` `+wotd` | `!define` `!syn` `!ud` `!wotd` |
| `countdown.tcl` | Event countdowns with automatic announcements | `+countdown` | `!cd` |
| `ask.tcl` | AI answers (Claude API or a local LLM) | `+ask` `+ask-mention` | `!ask` |
| `tools.tcl` | Op commands, `!seen`, greeting | — | `!seen` `!op` `!kb` `!ban` |
| `help.tcl` | Lists the scripts and the commands *you* can use; MOTD-style guide | — | `!commands` `!help` `!scripts` `.guide` |
| `guard.tcl` | Optional: channel protection with Q and access levels 0-10 | `!status on` | `!showcommands` |
| `web.tcl`, `timeutil.tcl` | Libraries (HTTP/JSON, date parsing) | — | — |

Optional keys:
- proxycheck.io: free, gives more queries per day.
- YouTube Data API v3: free; needed for search and full video details.
- GitHub token: free; raises the GitHub limit from 60 to 5000 requests per hour (optional).
- Claude API (paid): needed for `!ask`, unless you use a local LLM.

## Layout

```
eggdrop.conf            QuakeNet-ready configuration (copy it as mibot.conf)
secrets.tcl.example     passwords and API keys template (copy to secrets.tcl)
scripts/                the Tcl scripts (source of truth)
dist/                   eggdrop-quakenet-utils.tcl: every script in one file (generated)
build/build.tcl         rebuilds dist/ from scripts/
tests/                  test harness: tclsh tests/run.tcl
INSTALL.md              full install, existing bots, updates
docs/GUIDE.md           user guide: every command, with examples
CHANGELOG.md  LICENSE
```

## Install

Every command of every script, with examples, is in the **[user guide](docs/GUIDE.md)**.

Quick version for a new bot (Debian / Ubuntu). **[INSTALL.md](INSTALL.md)** has every step, plus how to add the scripts to an existing bot without losing its users, and how to update.

```bash
sudo apt install tcl tcllib tcl-tls tzdata git
git clone https://github.com/sauk1337/eggdrop-quakenet-utils.git

# with Eggdrop 1.9/1.10 already installed in ~/mibot:
cp eggdrop-quakenet-utils/dist/eggdrop-quakenet-utils.tcl ~/mibot/scripts/
cp eggdrop-quakenet-utils/eggdrop.conf ~/mibot/mibot.conf
cp eggdrop-quakenet-utils/secrets.tcl.example ~/mibot/secrets.tcl
chmod 600 ~/mibot/secrets.tcl
```

1. In `mibot.conf`:
   - edit the lines marked `<-- CHANGE`;
   - in the SCRIPTS section, keep option **A** (one file) and comment out list **B**.
2. In `secrets.tcl`, set the bot's Q account and password.
3. Start the bot with `./eggdrop -m mibot.conf`, then run `/msg <bot> hello`.
4. On the partyline:

   ```
   .+chan #chan
   .chanset #chan +antiproxy +utils +youtube ...
   .guide
   ```

## Guide

`.guide` on the partyline prints the guide below. The same text heads `dist/eggdrop-quakenet-utils.tcl`. On IRC, `!commands` shows only the commands each person can use, `!help <script>` explains a script and `!help !command` explains one command.

```
+----------------------------------------------------------------------+
|                    eggdrop-quakenet-utils  v1.2.2                    |
|        Utility bot for QuakeNet - Eggdrop 1.9/1.10 - Tcl 8.6         |
+----------------------------------------------------------------------+

 QUICK START
   1. secrets.tcl  ->  Q account, password and optional API keys
   2. .+chan #chan
   3. .chanset #chan +antiproxy +ipinfo +utils +youtube +urltitle
      .chanset #chan +chanstats +reminders +feeds +github +wiki
      .chanset #chan +dict +countdown +ask
   4. .save   and on IRC:  !commands

 ON IRC (everyone)                      answers by notice where noted
   !commands  !help <script|!cmd>       what YOU can use here (notice)
   !scripts [name]                      loaded scripts, on/off here
   !ip <ip|host>                        location, network, abuse, proxy
   !weather !forecast !time <city>      weather and local time
   !convert <n> <FROM> <TO>  !crypto    currencies and crypto
   !country !dns !calc !quote           facts, DNS, maths, quotes
   !yt <search|link>                    YouTube (links are automatic)
   !stats !top !hours !today !words     channel statistics
   !remind <when> <text>  !at  !snooze  reminders and alarms
   !feed list|latest <name>             RSS/Atom feeds
   !gh <user>  !gh repo <owner/repo>    GitHub profiles and repos
   !wiki [lang:]<query>  !otd           Wikipedia, on this day
   !define !synonyms !rhymes !ud !wotd  dictionary
   !cd [name]                           countdowns
   !ask <question>                      AI answers
   !seen <nick>                         last time someone was seen
   /msg <bot> enter #chan               invite after an IP check (+i)

 ON IRC (channel ops)
   !op !deop !voice !devoice !kick !kb !ban !unban !topic
   !pcheck <ip|nick>   !ip <nick>       proxy check, IP of a user
   !pwhite !pcache !pstats              antiproxy whitelist, cache, counters
   !feed add|del|pause|filter ...       manage feeds
   !gh add|del|filter|check ...         manage tracked GitHub profiles
   !cd add|del|edit|alerts ...          manage countdowns
   !quote del <n>

 PARTYLINE
   .guide                    this guide
   .scripts                  loaded scripts and where they're on
   .pcheck .pwhite .pcache .pstats      antiproxy
   .qauth  .reminders  .github  .askstats  .askreset

 ANTIPROXY IN ONE LINE
   Each method adds points; at 3 the user is kickbanned (or warned).
   BNC with a hostname: 2, allowed.  Bare VPS IP: 3, banned.
   Real proxy / Tor / DNSBL: 3+, banned.  Q-authed users: always in.

 MORE:  !help <script>  -  the header of every .tcl  -  README.md
+----------------------------------------------------------------------+
```

## Notes per script

The full documentation is in each script's header. A few points worth knowing:

- **antiproxy**: each method adds points, and `threshold` (default 3) decides.
  - BNCs and shells with a hostname (VPN +1, hosting +1 = 2) get in; the same hints on a bare IP with no reverse DNS get +1 more and are banned.
  - Users authed with Q always get in (checked with WHOX before acting), and so do `*.users.quakenet.org` hosts.
  - Set the channel `+r` to require a Q account.
- **ipinfo**: looking up a *nick* reveals their IP, so only bot ops can do it, and the answer goes by notice.
- **ask**:
  - The default is Claude Opus 5.5 at `low` effort, which suits short chat answers.
  - Server-side fallback is on (`::ask::fallbacks`): if the model declines a request, the API retries it on a fallback model by itself.
  - Daily request caps, a token budget and per-user cooldowns are configurable at the top of the script.
  - To use a local model instead, see `secrets.tcl.example`.
- **github**: `!gh add <user>` tracks a profile on the channel and `!gh filter` chooses what to announce. The first check only records what is already there. Without a token GitHub allows 60 requests per hour; ETag keeps unchanged profiles from spending it.
- **feeds**: the first fetch only records the existing items. After that, only new items are announced (3 per check by default), never older than 3 days.
- **guard**: compatible with the channel settings of the original protection v1.4b, so existing chanfiles keep working. It is not loaded by default; uncomment it in the conf.

## Tests

```bash
tclsh tests/run.tcl          # 184 checks with a stubbed Eggdrop API and recorded API answers
tclsh tests/load_check.tcl   # every script and the single-file build load cleanly
tclsh build/build.tcl        # rebuild dist/eggdrop-quakenet-utils.tcl after changing a script
```

## License

MIT (see `LICENSE`).

`scripts/guard.tcl` is the exception. It is based on the 2005 "protection v1.4b" script and keeps that script's license and notice in its header, as that license requires.
