# User guide

How to use every script once the bot is running. To install it, see [INSTALL.md](../INSTALL.md).

## Contents

- [The basics](#the-basics)
- [Getting help on IRC](#getting-help-on-irc)
- [Scripts](#scripts):
  - [antiproxy](#antiproxy) · [ipinfo](#ipinfo) · [utils](#utils)
  - [youtube](#youtube) · [urltitle](#urltitle) · [chanstats](#chanstats)
  - [reminders](#reminders) · [feeds](#feeds) · [github](#github) · [wiki](#wiki)
  - [dictionary](#dictionary) · [countdown](#countdown) · [ask](#ask)
  - [tools](#tools) · [qauth](#qauth) · [guard](#guard-optional)
- [Partyline reference](#partyline-reference)
- [Customising](#customising)
- [Data and backups](#data-and-backups)
- [FAQ](#faq)

## The basics

- **Every script is off until you enable it on a channel**, with a channel flag on the partyline. Examples:
  - `.chanset #chan +youtube` enables YouTube links.
  - `.chanset #chan -youtube` disables them again.
  - Run `.save` afterwards.
- **Who can do what:**
  - **everyone**: lookups such as `!weather`, `!yt` and `!wiki`;
  - **channel ops**: commands that change things, like adding feeds or kicking. A channel op here is a bot user with the `o` flag, global or for that channel (`o|o`), not just someone with `@`;
  - **masters and owners**: partyline administration.
- **Where answers go:**
  - lookups answer on the channel;
  - help, lists and private data (a user's IP, your reminders) go by notice.
- **Every answer looks the same:**

  ```
  Tag :: main text (Label: value | Label: value | link)
  ```

  - The tag is orange and bold, the main text bold, the labels blue and the separators orange.
  - Decoration is plain ASCII, so old mIRC versions show it right.
- **Everything web-related is asynchronous:** a slow website never freezes the bot.

## Getting help on IRC

| Command | What it does |
|---|---|
| `!commands` (`!help`, `!comandos`, `!ayuda`) | The commands **you** can use on this channel, by notice. Scripts that are off and commands you lack access to are hidden. |
| `!help <script>` | What a script does and its commands, e.g. `!help reminders` |
| `!help <!command>` | Syntax of one command, e.g. `!help !remind` |
| `!scripts` | Loaded scripts, and whether each one is on here |
| `/msg <bot> help [script]` | The same, in private |
| `.guide` (partyline) | The full one-page guide |

Answers are capped at a few lines and throttled per user, so asking for help never floods the bot.

## Scripts

### antiproxy

Checks the IP of everyone who joins and kickbans proxies, VPN abuse and Tor.

| Enable | |
|---|---|
| `+antiproxy` | Check on join; act with `kickban` (default), `kick` or `warn` |
| `+antiproxy-gate` | For `+i` channels: users ask for an invite and get one only if their IP is clean |

| Command | Who | |
|---|---|---|
| `/msg <bot> enter #chan` | everyone | Ask for an invite on a gate channel |
| `!pcheck <ip\|host\|nick>` | ops | Check by hand and show the score |

**How it decides.** Each method adds points. At 3 points (`threshold`) the bot acts.

| Method | Points |
|---|---|
| DNSBL hit (DroneBL, EFnetRBL, dan.me.uk Tor) | 3 |
| Tor exit node list | 3 |
| proxycheck.io: proxy, SOCKS, compromised host | 3 |
| proxycheck.io: "VPN" (datacenter range) | 1, or 3 if its risk is 75 or more |
| ip-api.com: proxy | 3 |
| ip-api.com: hosting / datacenter | 1 |
| Suspicious reverse DNS (`*vpn*`, `*.amazonaws.com`...) | 1 |
| Bare IP (no reverse DNS) that already has other hints | 1 |
| Country in `country_block` | 3 |

What that means in practice:

| User | Score | Result |
|---|---|---|
| BNC or shell with a hostname (`*.xshellz.com`, `freakshells.net`) | 1 + 1 = 2 | allowed |
| Throwaway VPS with a bare IP | 1 + 1 + 1 = 3 | kickbanned |
| Open proxy, Tor, DNSBL-listed IP | 3 or more | kickbanned |
| Authed with Q (checked with WHOX before acting) | any | always allowed |
| `*.users.quakenet.org` host (+x) | none | allowed, the IP is hidden |

- Results are cached: clean IPs for 6 hours, bad ones for 24.
- Set `logchan` in the script to watch the decisions on a channel:

  ```
  Antiproxy :: Kicked bad!x@1.2.3.4 from #chan (Score: 3 | Reasons: ip-api: proxy +3 | Geo: UA ISP)
  Antiproxy :: Allowed shanon!x@away.ink on #chan, below threshold (Score: 2 | Reasons: ...)
  ```

- A legitimate user banned? On the partyline:
  1. `.pcheck <ip>` shows why.
  2. `.pwhite add *!*@their.host` lets them in for good.
  3. `.pcache clear` forgets old results.
  4. `.-chanban #chan <mask>` removes the ban.
- For a fully verified channel, combine it with `+r` (Q account required).

### ipinfo

Everything about an IP in three lines.

| Command | Who | |
|---|---|---|
| `!ip <ip\|host>` | everyone | Location, network, abuse contact, proxy verdict |
| `!ip <nick>` | ops | Looks up a user's IP; answered by notice, since it reveals the IP |
| `/msg <bot> ip <ip\|host\|nick>` | | Private |

```
IP :: 1.2.3.4 (Host: host.example.es | Location: Madrid, Spain (ES, Europe) | Time: Europe/Madrid)
Network :: AS3352 Telefonica (Range: 1.2.0.0/16 | Abuse: abuse@example.es)
Security :: CLEAN (proxycheck: no | ip-api: proxy no / hosting no / mobile no | DNSBL: none)
```

Enable with `+ipinfo`.

### utils

Enable with `+utils`.

| Command | Example | |
|---|---|---|
| `!weather <city>` (`!w`) | `!w Madrid` | Current weather |
| `!forecast <city>` | `!forecast Paris, FR` | 4-day forecast |
| `!time <city>` | `!time Tokyo` | Local time |
| `!convert <n> <FROM> <TO>` (`!cur`) | `!convert 50 EUR USD` | Currency (ECB rates) |
| `!crypto <coin> [currency]` | `!crypto btc eur` | Crypto price and 24 h change |
| `!country <name\|code>` | `!country es` | Capital, population, languages... |
| `!dns <host> [type]` | `!dns example.com MX` | DNS records over DoH |
| `!calc <expr>` | `!calc (2+3)*4^2` | Safe calculator |
| `!quote` | `!quote add <text>` / `!quote 12` / `!quote search <word>` | Channel quotes. `!quote del <n>` needs ops. |

```
Weather :: Madrid, ES (Now: Partly cloudy, 21.3C | Feels: 20.1C | Humidity: 40% | Wind: 12 km/h NE)
```

### youtube

Pasted YouTube links get one line. This covers watch, youtu.be, shorts, live, music and playlist links.

```
YouTube :: Kase O - Silencio (Channel: 7711zZ | Duration: 6:03 | Views: 6.7M | Likes: 36.4K | Published: 29.04.2012)
```

- The tag changes with the link: `YouTube Shorts`, `YouTube LIVE`, `YouTube Premiere`, `YouTube Playlist`.
- `!yt <search>` returns the first result.
- `!yt <link>` shows details on demand.
- Search and full details need a free YouTube Data API v3 key (`::youtube::key` in `secrets.tcl`). Without it you get the title and channel, plus views, likes and dislikes from Return YouTube Dislike.

Enable with `+youtube`.

### urltitle

Shows the title of other links pasted on the channel:

```
Title :: Some article title (Site: example.com)
```

- It follows redirects and detects the charset.
- It never fetches private or local addresses (SSRF-safe).
- YouTube links are left to youtube.tcl.

Enable with `+urltitle`.

### chanstats

Enable with `+chanstats`.

| Command | |
|---|---|
| `!stats [nick]` | Lines, words, questions, smileys, rank, first and last seen |
| `!top [lines\|words\|questions\|shouts\|smileys\|actions\|kicks\|kicked\|joins]` | Rankings |
| `!hours` / `!today` | Activity by hour, as an ASCII graph |
| `!words` | Most used words |
| `!chanstats` | Channel totals |

For an HTML stats page, set `htmldir` and `htmlurl` in `secrets.tcl`.

### reminders

Enable with `+reminders`.

| Command | |
|---|---|
| `!remind <when> <text>` | Remind me: `!remind 10m tea`, `!remind tomorrow 9:00 call mum` |
| `!remind <nick> <when> <text>` | Remind someone on the channel |
| `!remind every <interval> [at <time>] <text>` | Recurring (minimum 10 minutes) |
| `!at <time> <text>` | Alarm: `!at 18:30 match` |
| `!reminders` | Your pending reminders, by notice |
| `!remind del <id\|all>` | Delete yours. Ops can delete any on the channel. |
| `!remind tz <Area/City>` | Your timezone: `!remind tz America/Mexico_City` |
| `!snooze [interval]` | Repeat the last reminder (default 10 minutes) |
| `/msg <bot> remind <when> <text>` | Private reminder |

- `<when>` understands English and Spanish:
  - `10m`, `2h30m`, `in 1 hour`, `at 18:30`, `tomorrow 9:00`;
  - `friday 20:00`, `24/12 20:00`, `dec 24`;
  - `manana 9:00`, `en 10 minutos`.
- If you're away when a reminder is due, it's delivered when you come back.
- Reminders follow you through nick changes and your Q account.

### feeds

RSS and Atom announcer. Adding or changing feeds needs ops. Enable with `+feeds`.

| Command | |
|---|---|
| `!feed add <url\|shortcut> [name] [minutes]` | Subscribe the channel |
| `!feed del <name>` | Unsubscribe |
| `!feed list` | Subscriptions and their state |
| `!feed latest <name> [n]` | The latest items |
| `!feed check <name>` | Check it now |
| `!feed pause\|resume <name>` | |
| `!feed interval <name> <minutes>` | |
| `!feed filter <name> <words\|off>` | Only items with any of the words. `-word` excludes a word. |
| `!feed rename <name> <new>` / `!feed max <name> <n>` | |
| `!feed test <url\|shortcut>` | Preview without saving |

Shortcuts:

| Shortcut | Follows |
|---|---|
| `github:owner/repo` | Releases |
| `github-commits:owner/repo` | Commits |
| `youtube:@channel` | A channel's videos |
| `reddit:subreddit` | A subreddit |
| `mastodon:@user@server` | A Mastodon account |
| `bsky:handle` | A Bluesky account |

- The first check only records what's already there; after that, only new items are announced.
- At most 3 items per check, never older than 3 days.

### github

Follows the GitHub users and organisations you choose and announces their activity. Enable with `+github`.

| Command | Who | |
|---|---|---|
| `!gh <user>` | everyone | Profile card |
| `!gh repo <owner/repo>` | everyone | Repository card |
| `!gh repo <user>` | everyone | That profile's latest repositories |
| `!gh list` | everyone | Profiles tracked here |
| `!gh add <user>` | ops | Track a user or organisation |
| `!gh del <user>` | ops | Stop tracking it |
| `!gh filter <user> [types\|all\|default]` | ops | What to announce. Types: `push release create fork public pr issues star` |
| `!gh check` | ops | Check now; also says when there's nothing new |

```
GitHub :: torvalds pushed 2 commits to torvalds/linux (Branch: master | Last: "Fix the scheduler" | https://github.com/...)
GitHub :: torvalds released torvalds/linux v6.20 (Name: Linux 6.20 | https://github.com/...)
GitHub :: user created repository user/thing (A new thing | Language: Tcl | https://github.com/user/thing)
```

- **New repositories** show on the next check: the bot reads the profile's repository list, which GitHub updates at once.
- **Pushes, releases, PRs and issues** come from GitHub's public events feed. GitHub warns it can lag from 30 seconds to a few hours.
- **Private repositories** are never visible.
- **Rate limit:** without a token GitHub allows 60 requests per hour, and each check uses two. A free token (`::github::token` in `secrets.tcl`, a fine-grained token with no permissions is enough) raises the limit to 5000.

### wiki

Enable with `+wiki`.

| Command | |
|---|---|
| `!wiki <query>` | Summary of the best match |
| `!wiki <lang>: <query>` | Another language: `!wiki es: Madrid` |
| `!wikisearch <query>` | Top 5 titles |
| `!wikirandom [lang]` | A random article |
| `!otd [lang]` | On this day |

Settings:
- `.chanset #chan wiki-lang es` sets the default language.
- `+otd` posts "on this day" every day at 9:00, bot time (`otd_hour`).

### dictionary

Enable with `+dict`.

| Command | |
|---|---|
| `!define <word>` (`!def`) | Definitions: `!define serendipity` |
| `!define <lang>:<word>` | Another language: `!define es:casa` |
| `!synonyms` / `!antonyms` / `!rhymes <word>` | Related words |
| `!ud <term> [n]` / `!udrandom` | Urban Dictionary (opt-in with `+ud`) |
| `!wotd` | Word of the day |

Settings:
- `.chanset #chan dict-lang es` sets the default language.
- `+wotd` posts the word of the day daily.

### countdown

Enable with `+countdown`.

| Command | |
|---|---|
| `!cd` | Upcoming events |
| `!cd <name>` | Time left, date, progress bar, description |
| `!cd add <name> <date> [time] [\| description]` | `!cd add xmas 24/12 20:00 \| dinner` (ops) |
| `!cd add -yearly <name> <day/month> [time]` | Repeats every year |
| `!cd del` / `edit` / `desc <name> ...` | Manage events (ops) |
| `!cd alerts <name> <list\|off\|default>` | When to announce, e.g. `30d,7d,1d,1h,10m,0` |
| `!cd tz <Area/City>` | Channel timezone |

```
Countdown :: xmas in 55d 5h 4m (When: Thu 24 Dec 2026 20:00 CET | [#####-----] 50% | dinner)
```

### ask

AI answers with the Claude API, or with a local model through any OpenAI-compatible server such as Ollama. Enable with `+ask`.

| Command | |
|---|---|
| `!ask <question>` (`!ai`) | Ask |
| `!ask reset` | Forget this channel's conversation |
| `BotNick: <question>` | With `+ask-mention` |

- It needs `::ask::api_key` in `secrets.tcl`. For a local model, see `secrets.tcl.example`.
- Daily caps, a token budget and per-user cooldowns are at the top of `ask.tcl`.
- `.chanset #chan ask-persona "You are..."` gives the bot a personality on that channel.

### tools

Always loaded, no flag needed.

| Command | Who | |
|---|---|---|
| `!seen <nick>` | everyone | Last time someone was seen, and what they were doing |
| `!op` / `!deop` / `!voice` / `!devoice [nicks]` | ops | Modes |
| `!kick <nick> [reason]` / `!kb <nick> [reason]` | ops | Kick / kickban |
| `!ban <nick\|mask> [minutes] [reason]` / `!unban <mask>` | ops | Bans |
| `!topic <text>` | ops | Topic |

For a join greeting by notice: `.chanset #chan greet-msg Welcome %nick% to %chan%`.

### qauth

Authenticates the bot with Q on connect, using CHALLENGEAUTH (HMAC-SHA256), so the password never travels in plain text.

- Set the account in `secrets.tcl`.
- `::qauth::hidehost 1` sets +x after auth.
- `.qauth` on the partyline authenticates again.

### guard (optional)

Channel protection with Q and access levels 0-10, for a main channel bot. It's not in the single file and not loaded by default.

- Load `scripts/guard.tcl` after the other scripts.
- Enable it per channel with `!status on`.
- `!showcommands` lists the commands for your level.
- It keeps the license of the 2005 script it is based on (see its header).

## Partyline reference

| Command | Flag | |
|---|---|---|
| `.guide` | | The one-page guide |
| `.scripts` | | Loaded scripts and the channels using them |
| `.pcheck <ip\|host\|nick>` | o | Antiproxy check |
| `.pwhite add\|del\|list [mask]` | o | Antiproxy whitelist |
| `.pcache [clear]` | o | Antiproxy cache |
| `.pstats` | o | Antiproxy counters |
| `.ip <ip\|host\|nick>` | | IP lookup |
| `.github` | o | Tracked GitHub profiles and their state |
| `.feeds` | m | Every feed on the bot |
| `.reminders [nick]` | m | Pending reminders |
| `.chanstats-reset #chan` / `.chanstats-html` | m | Stats |
| `.askstats` / `.askreset [#chan]` | m | AI usage / forget conversations |
| `.qauth` | n | Authenticate with Q again |

## Customising

- **Settings** are at the top of each script, in its CONFIGURATION block. To keep your changes across updates, put them in `secrets.tcl` instead, which is loaded last:

  ```tcl
  set ::antiproxy::threshold 4
  set ::antiproxy::action "warn"
  set ::antiproxy::logchan "#mychan-log"
  set ::github::interval 15
  ```

- **Colours:** all of them live in `::web::style` (mIRC colour numbers):

  ```tcl
  array set ::web::style {tag 04 label 10 sep 14 dim 14}
  ```

- **Typographic punctuation:** quotes, dashes and ellipses from websites are turned into ASCII for old clients. To send them untouched: `set ::web::ascii_punct 0`.

## Data and backups

Each script keeps its data in a directory next to the bot's conf:

| Directory / file | Contents |
|---|---|
| `antiproxy/` | Whitelist and Tor list |
| `chanstats/` | Statistics |
| `reminders/` | Reminders and timezones |
| `feeds/` | Subscriptions and seen items |
| `github/` | Tracked profiles |
| `countdown/` | Events |
| `utils/` | Quotes |
| `seen.db` | `!seen` |

- Back them up together with the userfile and chanfile.
- Updating the scripts never touches them.

## FAQ

**A command doesn't answer.**
The script is probably off on that channel. Check with `!scripts` or `.chaninfo #chan`, then enable it with `.chanset #chan +<flag>`.

**The bot says "1" by notice when someone joins.**
That came from an old version that used the `greet` setting, which clashes with Eggdrop's own `+greet` flag. Update; the setting is now `greet-msg`.

**I see strange characters (`Â·`, `ï¿½`).**
The bot's own decoration is ASCII. Accents inside titles still need a UTF-8 client (mIRC 7 or newer).

**The GitHub tracker didn't announce my push.**
GitHub's events feed can take a while. New repositories show at once; pushes and releases show when GitHub publishes them. `!gh check` tells you if there's nothing new yet.

**Antiproxy banned a BNC user.**
Run `.pcheck <ip>` to see the score. BNCs with a hostname stay at 2 and get in, and so does anyone authed with Q. If one still scores 3, whitelist it with `.pwhite add *!*@host`.
