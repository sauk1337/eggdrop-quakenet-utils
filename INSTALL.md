# Installing eggdrop-quakenet-utils

Three cases:

- [A. New bot](#a-new-bot): you're starting from scratch.
- [B. Existing bot](#b-existing-bot-keep-users-and-channels): you already run an Eggdrop and want to keep its users and channels.
- [C. Updating](#c-updating-to-a-new-version): a bot that already runs these scripts.

Every command runs on the Linux server as the user that runs the bot, not as root, unless it starts with `sudo`.

## Requirements

- Linux (Debian / Ubuntu shown, any distribution works).
- Eggdrop 1.9 or 1.10, Tcl 8.6.
- Packages:

```bash
sudo apt update
sudo apt install build-essential tcl tcl-dev tcllib tcl-tls libssl-dev tzdata wget git
```

| Package | Why |
|---|---|
| `tcllib` | SHA-256 for Q's CHALLENGEAUTH (without it the bot sends the password in plain text) |
| `tcl-tls` | HTTPS: every web API |
| `tzdata` | timezones for `!time`, reminders and countdowns |

Check that Tcl finds them:

```bash
echo 'puts [package require tls]; puts [package require sha256]' | tclsh
```

It must print two version numbers.

## Get the scripts

```bash
git clone https://github.com/sauk1337/eggdrop-quakenet-utils.git ~/eggdrop-quakenet-utils
```

There are two ways to load them. Pick one.

| | File(s) | When to use it |
|---|---|---|
| **One file** | `dist/eggdrop-quakenet-utils.tcl` | Simplest: one file to copy, one `source` line |
| **One per script** | `scripts/*.tcl` | You want to leave some scripts out, or edit them |

`guard.tcl` (optional channel protection) is not in the single file. Load it separately if you want it.

## A. New bot

### 1. Build Eggdrop

```bash
cd ~
wget https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-1.10.0.tar.gz
tar xzf eggdrop-1.10.0.tar.gz
cd eggdrop-1.10.0
./configure
make config
make
make install DEST=~/mibot
```

Get the latest stable version from https://www.eggheads.org/downloads.

### 2. Copy the scripts and the config

```bash
cp ~/eggdrop-quakenet-utils/dist/eggdrop-quakenet-utils.tcl ~/mibot/scripts/
cp ~/eggdrop-quakenet-utils/eggdrop.conf ~/mibot/mibot.conf
cp ~/eggdrop-quakenet-utils/secrets.tcl.example ~/mibot/secrets.tcl
chmod 600 ~/mibot/secrets.tcl
mkdir -p ~/mibot/logs
```

If you prefer one file per script, copy `scripts/*.tcl` instead of the `dist/` file.

### 3. Configure

1. In `~/mibot/mibot.conf`:
   - Change every line marked `<-- CHANGE`: nick, altnick, username, admin, owner.
   - In the SCRIPTS section, choose the load method. **A** (one file) is a single `source` line; **B** is the list of scripts. Leave only one of them active.
2. In `~/mibot/secrets.tcl`:
   - Set the bot's Q account and password (`::qauth::user`, `::qauth::pass`).
   - Optionally, add API keys: proxycheck.io, YouTube, GitHub token, Claude. Each one is explained in the file.

`secrets.tcl` is in `.gitignore`. Never commit it or paste it anywhere.

### 4. First run

```bash
cd ~/mibot
./eggdrop -m mibot.conf
```

Use `-m` only the first time: it creates the userfile.

1. On IRC, `/msg <botnick> hello` makes you the owner.
2. Set a password: `/msg <botnick> pass <password>`.
3. In `mibot.conf`, uncomment `unbind msg - hello *msg:hello`.
4. On the partyline (`/dcc chat <botnick>`), run `.rehash`.

### 5. Set up a channel

On the partyline:

```
.+chan #mychannel
.chanset #mychannel +antiproxy +ipinfo +utils +youtube +urltitle +chanstats
.chanset #mychannel +reminders +feeds +github +wiki +dict +countdown +ask
.save
```

Enable only what you want. Then:

- `.guide` shows the full guide.
- On IRC, `!commands` lists what each person can use.

### 6. Keep it running

With systemd:

```ini
# /etc/systemd/system/mibot.service
[Unit]
Description=Eggdrop mibot
After=network-online.target

[Service]
User=youruser
WorkingDirectory=/home/youruser/mibot
ExecStart=/home/youruser/mibot/eggdrop -n mibot.conf
Restart=on-failure
RestartSec=30
Environment=LANG=C.UTF-8

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mibot
```

Without root, use `./autobotchk mibot.conf` instead, which uses cron.

## B. Existing bot (keep users and channels)

Your users and channels live in the userfile and chanfile (for example `egg.user` and `egg.chan`). They are never touched; you only add the scripts and some lines to your conf.

```bash
cd ~/yourbot
cp yourbot.conf yourbot.conf.bak            # backup first
cp ~/eggdrop-quakenet-utils/dist/eggdrop-quakenet-utils.tcl scripts/
cp ~/eggdrop-quakenet-utils/secrets.tcl.example secrets.tcl
chmod 600 secrets.tcl
nano secrets.tcl                            # Q account and keys
```

At the end of `yourbot.conf`, add:

```tcl
encoding system utf-8
source scripts/eggdrop-quakenet-utils.tcl
if {[file exists secrets.tcl]} {source secrets.tcl}
```

On the partyline, run `.rehash`.

Notes for old bots:

- **Upgrading from Eggdrop 1.6 / 1.8:** keep `loadmodule blowfish` together with `loadmodule pbkdf2` in the conf, so the old password hashes still work.
- **Other scripts that use the same commands:** remove any script whose commands clash (`!seen`, `!weather`, `!yt`...). It's the last script loaded that answers.

## C. Updating to a new version

Your data is kept: reminders, feeds, stats, seen, countdowns, GitHub profiles and the antiproxy whitelist each live in their own directory next to the conf.

```bash
cd ~/eggdrop-quakenet-utils && git pull
cp dist/eggdrop-quakenet-utils.tcl ~/mibot/scripts/
```

Then run `.rehash` on the partyline. Read `CHANGELOG.md` for new settings.

### From separate scripts to the single file

```bash
cd ~/mibot
cp mibot.conf mibot.conf.bak
mkdir -p scripts/old
for f in web timeutil qauth antiproxy tools ipinfo utils youtube urltitle chanstats reminders feeds github wiki dictionary countdown ask help; do
    [ -f scripts/$f.tcl ] && mv scripts/$f.tcl scripts/old/
done
sed -i -E '/^source scripts\/(web|timeutil|qauth|antiproxy|tools|ipinfo|utils|youtube|urltitle|chanstats|reminders|feeds|github|wiki|dictionary|countdown|ask|help)\.tcl/d' mibot.conf
sed -i 's|^if {\[file exists secrets.tcl\]} {source secrets.tcl}|source scripts/eggdrop-quakenet-utils.tcl\n&|' mibot.conf
grep -n "eggdrop-quakenet-utils\|secrets.tcl" mibot.conf
```

The last command must show the `source scripts/eggdrop-quakenet-utils.tcl` line just before the `secrets.tcl` line. Then run `.rehash` on the partyline. The single file defines the same commands as the separate scripts, so nothing is left over.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `can't find package tls` | `sudo apt install tcl-tls` |
| `can't find package sha256` | `sudo apt install tcllib` |
| The bot doesn't auth with Q | `.qauth` on the partyline shows the state. Check `secrets.tcl`. |
| A command doesn't answer | Is the channel flag on? `.chaninfo #chan`, or `!scripts` on IRC. |
| Antiproxy bans a legitimate user | `.pcheck <ip>` shows why. `.pwhite add *!*@host` lets them in. `.pcache clear` forgets old results. |
| Bad characters in old mIRC | Bot decoration is ASCII. Accents in titles need a UTF-8 client (mIRC 7+). |
| GitHub tracker stops for a while | GitHub's limit is 60 requests per hour without a token. Add `::github::token` in `secrets.tcl`. |

## Tests (optional, for developers)

```bash
cd ~/eggdrop-quakenet-utils
tclsh tests/run.tcl          # must end in ALL OK
tclsh tests/load_check.tcl   # every script and the single file load
tclsh build/build.tcl        # rebuild dist/ after changing a script in scripts/
```
