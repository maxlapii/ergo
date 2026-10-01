# ergo — Setup & Reference

Everything needed to install, run, configure and troubleshoot ergo. For an
overview of what ergo is and how it works, see [README.md](README.md). To build
the optional macOS Shortcuts, see [shortcuts/README.md](shortcuts/README.md).

## Contents

1. [Requirements](#1-requirements)
2. [Install](#2-install)
3. [Run in the background (LaunchAgent)](#3-run-in-the-background-launchagent)
4. [Testing from Terminal](#4-testing-from-terminal)
5. [The settings window](#5-the-settings-window)
6. [Configuration reference](#6-configuration-reference)
7. [The fullscreen break](#7-the-fullscreen-break)
8. [Cues](#8-cues)
9. [Logs and state](#9-logs-and-state)
10. [Troubleshooting](#10-troubleshooting)
11. [Uninstall](#11-uninstall)
12. [Command reference](#12-command-reference)
13. [Project layout](#13-project-layout)

---

## 1. Requirements

| Requirement | Notes |
|---|---|
| macOS | Uses `zsh`, `launchd` and `osascript`, all built in. Developed and tested on macOS 26. |
| `jq` | The only dependency. macOS 15 Sequoia and later include it as `/usr/bin/jq`. Check with `command -v jq`. |
| Folder location | Keep `ergo/` in your home folder (for example `~/ergo`), not in Desktop, Documents, Downloads or iCloud Drive, where macOS can block background jobs. |

On older macOS without `jq`, download the macOS binary from <https://jqlang.org>,
make it executable, and place it at `/usr/local/bin/jq`. ergo also looks in
`/usr/local/bin` and `/opt/homebrew/bin` when launchd gives it a minimal `PATH`.

## 2. Install

Installation takes about a minute: put the folder somewhere permanent, then run
one command.

### Step 1 — Get ergo

Use either option, and place the folder at `~/ergo` (your home folder):

- **Git:** `git clone <repository-url> ~/ergo`
- **Download:** download the ZIP, double-click it to unzip, rename the folder to
  `ergo`, and drag it into your home folder (in Finder, **Go → Home**).

Then open **Terminal** (Applications → Utilities) and confirm `jq` is available:

```bash
command -v jq
```

It should print a path such as `/usr/bin/jq`. If it prints nothing, see
[Requirements](#1-requirements).

### Step 2 — Run the installer

```bash
cd ~/ergo
```

```bash
zsh ergo.sh --install
```

Running it with `zsh` works even if the download didn't keep the file's
executable permission; the installer restores it. You'll see:

```text
Installing ergo from /Users/you/ergo
  ✓ ergo.sh is executable
  ✓ Settings and cue library are valid (76 cues)
  ✓ LaunchAgent written to /Users/you/Library/LaunchAgents/com.yourname.ergo.plist
  ✓ Loaded: ergo now runs at login and checks every 5 minutes

ergo is installed.
```

What the installer does:

1. Checks that this is macOS and that `jq` is available.
2. Validates `config.json` and `nudges.json`; it refuses to install an invalid
   setup and names the problem.
3. Makes `ergo.sh` executable and clears the "downloaded from the internet"
   quarantine flag from the folder.
4. Warns if the folder is in a location macOS protects from background jobs.
5. Writes `~/Library/LaunchAgents/com.yourname.ergo.plist` with this folder's
   absolute path, checks it with `plutil`, and loads it (replacing any earlier
   copy).

Running `--install` again is safe at any time.

### Step 3 — Try it

```bash
./ergo.sh --test
```

```bash
./ergo.sh --configure
```

```bash
./ergo.sh --status
```

`--test` shows a real break immediately, `--configure` opens the settings
window to set your hours, interval and break length, and `--status` should
report `LaunchAgent: Loaded (com.yourname.ergo)`.

### Step 4 — Allow the macOS prompts

- **Background Items Added:** expected. The item may be listed as `zsh`. If
  ergo never runs on schedule, allow it under **System Settings → General →
  Login Items & Extensions**.
- **Notifications** (only for the banner style and the fallback): allow
  **Script Editor** under **System Settings → Notifications**.
- **Shortcuts** (optional): to control ergo from the menu bar, follow
  [shortcuts/README.md](shortcuts/README.md).

### Moving or updating ergo

- **Moved the folder?** Run `zsh ergo.sh --install` from the new location. The
  LaunchAgent always points at the folder it was installed from.
- **Updating?** Replace the program files (`ergo.sh`, `ui/`,
  `com.yourname.ergo.plist`, the docs), keep your `config.json`, `nudges.json`,
  `logs/` and `state/`, then run `zsh ergo.sh --install` again.

### Manual installation (advanced)

If you prefer to install the LaunchAgent yourself, run these from inside the
`ergo` folder. launchd needs absolute paths without `~`, so the `sed` command
fills in the real path:

```bash
mkdir -p ~/Library/LaunchAgents
```

```bash
sed "s#/Users/YOUR_USERNAME/ACTUAL/PATH/TO/ergo#$PWD#g" com.yourname.ergo.plist > ~/Library/LaunchAgents/com.yourname.ergo.plist
```

```bash
plutil -lint ~/Library/LaunchAgents/com.yourname.ergo.plist
```

```bash
launchctl load ~/Library/LaunchAgents/com.yourname.ergo.plist
```

## 3. Run in the background (LaunchAgent)

`./ergo.sh --install` sets this up for you (see [Install](#2-install)). The
LaunchAgent starts ergo at login and wakes it every five minutes; this section
covers managing it directly.

### Managing the agent

| Task | Command |
|---|---|
| Load (now and at every login) | `launchctl load ~/Library/LaunchAgents/com.yourname.ergo.plist` |
| Unload (stop) | `launchctl unload ~/Library/LaunchAgents/com.yourname.ergo.plist` |
| Run once now | `launchctl start com.yourname.ergo` |
| Is it loaded? | `launchctl list \| grep com.yourname.ergo` |
| Details | `launchctl print gui/$(id -u)/com.yourname.ergo` |

In `launchctl list` output (`-  0  com.yourname.ergo`) the first column is a PID
while ergo runs and `-` between runs; the second is the last exit status, where
`0` is good. After editing the installed plist, unload and load it again.
Editing `config.json` or `nudges.json` never needs a reload.

The modern equivalents work too: `launchctl bootstrap gui/$(id -u) <plist>`,
`launchctl bootout gui/$(id -u)/com.yourname.ergo`, and
`launchctl kickstart gui/$(id -u)/com.yourname.ergo`.

### Why every five minutes?

launchd does not run ergo once per reminder interval. It wakes ergo every five
minutes (`StartInterval 300`), and ergo decides whether a break is due:

1. Is ergo enabled, and is quiet mode off?
2. Is today one of `work_days`?
3. Is the hour inside `work_start_hour <= hour < work_end_hour`?
4. Has `interval_minutes × 60` seconds passed since the last nudge?

If any answer is no, it exits silently and logs nothing. This is why interval
changes apply within five minutes without reloading launchd. A 60-second grace
window absorbs launchd's timer jitter, so a break due at 10:00:00 that is checked
at 09:59:58 isn't pushed to 10:05.

## 4. Testing from Terminal

| Command | What it does |
|---|---|
| `./ergo.sh --test` | Shows a real break now, ignoring hours, days and interval. Still validates everything, picks a real cue, logs it, and updates state. Works even while paused or in quiet mode. |
| `./ergo.sh --status` | Settings, last and next nudge, today's count, cue count, and whether the LaunchAgent is loaded. Prints validation errors instead if a file is invalid. |
| `./ergo.sh --today` | Today's summary: nudges, categories, estimated movement, latest breaks. |
| `./ergo.sh --reset-state` | Clears last nudge, last cue and recent history. Logs are kept. |

`Next nudge` reads as a time, `Due now`, `outside work hours`,
`not a work day`, `paused` or `quiet mode`.

## 5. The settings window

```bash
./ergo.sh --configure
```

A native fullscreen window (built with `osascript`'s JavaScript bridge and
WebKit) that follows your light or dark appearance:

- **Header:** status, next nudge, and the master **Enabled** switch.
- **Schedule:** interval presets with a stepper; a 24-hour work-hours timeline
  with draggable handles and dots at the approximate nudge times; work days.
- **Notifications:** nudge style (fullscreen break or banner); break length as
  a 10–240 second range slider in 5-second steps; sound with a preview; quiet
  mode; variety (how many recent cues to avoid).
- **Cue library:** counts, and a button that opens `nudges.json`.
- **Today** and **Preview:** today's activity, and a live preview with
  **Send a test nudge**.

| Key | Action |
|---|---|
| `⌘S` | Save |
| `Esc`, `⌘W`, `⌘Q` | Close (asks Save / Don't Save / Cancel if there are changes) |
| `⌃⌘F` | Leave or enter fullscreen |
| Arrow keys, Page Up/Down, Home/End | Move a focused slider handle or change the interval |

Changes apply only when you save, through `ergo.sh --apply-config`, so the
window can't save an invalid configuration. If macOS doesn't bring the window
forward immediately, click it or its Dock icon. To keep it windowed, run
`ERGO_WINDOWED=1 ./ergo.sh --configure`. Opened in a browser,
`ui/configure.html` runs in preview mode with sample data.

## 6. Configuration reference

Everything lives in `config.json`. Change it from the settings window, the
Shortcuts, `./ergo.sh --set`, or by editing the file.

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` pauses ergo entirely |
| `interval_minutes` | `60` | Minimum minutes between nudges (whole number > 0) |
| `work_start_hour` | `9` | First hour nudges may appear (0–23) |
| `work_end_hour` | `18` | Nudges stop at this hour (exclusive: 18 means through 17:59). A start later than the end wraps past midnight. |
| `work_days` | `[1,2,3,4,5]` | 1 = Monday … 7 = Sunday |
| `sound` | `false` | Play a chime when a break starts and when its timer completes |
| `avoid_repeat_count` | `3` | Recent cues to avoid repeating (0 turns it off) |
| `quiet_mode` | `false` | Mute scheduled nudges temporarily |
| `nudge_style` | `"fullscreen"` | `"fullscreen"` break or `"notification"` banner |
| `break_min_seconds` | `10` | Shortest break: a multiple of 5 from 10 to 240 |
| `break_max_seconds` | `45` | Longest break: a multiple of 5 from 10 to 240, not below the minimum |
| `log_file` | `logs/nudges.csv` | Relative to the ergo folder, or absolute |
| `state_file` | `state/state.json` | Relative to the ergo folder, or absolute |

### Changing settings from Terminal

| Command | Accepted values |
|---|---|
| `./ergo.sh --set interval 45` | `45`, `45 minutes` |
| `./ergo.sh --set start 8` / `end 17` | `9`, `09:00`, `6 PM` |
| `./ergo.sh --set days "Mon,Wed,Fri"` | `Weekdays`, `Every day`, `Weekends`, `Monday Wednesday`, `1,3,5` |
| `./ergo.sh --set sound on` | `On`, `Off` (also `quiet`, `enabled`) |
| `./ergo.sh --set style fullscreen` | `Fullscreen`, `Notification` / `Banner` |
| `./ergo.sh --set breaks "20-60"` | A range like `20-60` or `20 to 60 sec`, or `30` for a fixed length |
| `./ergo.sh --set avoid-repeat 5` | `0`, `3`, `5`, … |
| `./ergo.sh --toggle` | Pause or resume |
| `./ergo.sh --reset-config` | Restore every default |

Each change keeps all other settings, validates the whole file, refuses an
invalid result with the exact reason, and writes atomically.

### Quiet mode vs. paused

Both stop scheduled nudges. **Paused** (`enabled: false`) means ergo is off.
**Quiet mode** (`quiet_mode: true`) is a temporary mute for presentations,
screen sharing and calls. In both, `--status`, `--today` and manual breaks
(`--test`, **ergo: Nudge Now**) keep working. Turn on quiet mode before you
share your screen, so a break never covers it.

## 7. The fullscreen break

- Covers every display with a native blur; the break itself appears on the
  display your pointer is on. It is a borderless overlay, not a fullscreen
  Space, so it appears instantly and also works over fullscreen apps.
- Shows the category and length, the title and instructions, then a two-digit
  countdown with a dashed progress line: one dash per second (grouped into about
  30 dashes for long breaks), with one whole dash deducted from the right each
  second, in step with the number. The last three seconds brighten.
- **Yes, Ready** (`Space` / `Return`) ends it; **Skip** (`Esc`) closes it; click
  the countdown or press `P` to pause and resume.
- It closes by itself when the countdown reaches zero, and after 15 minutes
  without interaction.
- Every break is logged once with its real length; the outcome (`completed`,
  `ready`, `skipped`, `timeout`) goes to `logs/ergo.out`.
- If it can't be shown, ergo sends a standard notification instead and notes the
  reason in `logs/ergo.err`.

## 8. Cues

`nudges.json` is an array of cues:

```json
{
  "id": "desk-push-ups",
  "title": "Desk Push-Ups",
  "body": "Place your hands on the desk edge and do a few slow, easy push-ups.",
  "category": "Upper Body",
  "duration_seconds": 30,
  "routine_url": ""
}
```

- `id` must be unique; it is used in the log and the anti-repeat history.
- `title` and `body` are what the break shows. Keep the body to one or two
  friendly sentences, and avoid naming a fixed duration, since break length
  comes from your configured range.
- `category` can be anything. The existing names (Standing, Walking, Upper Body,
  Neck & Shoulders, Lower Back, Hips, Eyes, Wrists & Hands, Breathing, Posture
  Reset, Legs, Full Body) also drive time-of-day weighting.
- `duration_seconds` is required by the format; the break length itself comes
  from `break_min_seconds`–`break_max_seconds`.
- `routine_url` is optional; when it's an `http(s)` link, the break shows an
  **Open the full routine** link.

How a cue is chosen: skip the last `avoid_repeat_count` cues, prefer a new
category, give double weight to categories suited to the time of day (morning:
posture, neck and shoulders, upper and full body; midday: walking, standing,
hips, lower back, legs; afternoon: eyes, breathing, wrists and hands, upper
body), then pick at random. If everything is excluded, the history resets.
After editing, `./ergo.sh --status` validates the file and names any problem
cue.

## 9. Logs and state

| File | Contents | Inspect with |
|---|---|---|
| `logs/nudges.csv` | One row per break | `tail logs/nudges.csv` |
| `logs/ergo.out` | One line per break when run by launchd | `tail logs/ergo.out` |
| `logs/ergo.err` | Errors and warnings | `tail logs/ergo.err` |
| `state/state.json` | Last nudge, last cue and category, recent cues | `cat state/state.json` |

```csv
timestamp,title,cue_id,category,duration_seconds
2026-10-01 09:47:05,"Shoulder Sunrise","shoulder-sunrise","Neck & Shoulders",15
```

Text fields are always quoted with internal quotes doubled, so the file opens
cleanly in Numbers or Excel. An unreadable `state.json` is moved aside as
`state.json.corrupt-<time>` and replaced. The logs grow by about ten lines a
day; empty them any time (keep the CSV header line).

Safety in brief: `state/.ergo.lock` prevents overlapping runs and cleans up
after a crash; state and config are written to a temporary file, checked with
`jq`, then renamed into place.

## 10. Troubleshooting

Start with `./ergo.sh --status`. It validates both JSON files, shows whether
the LaunchAgent is loaded, and explains what ergo would do now.

**The break doesn't appear.**
Run `./ergo.sh --test`; the printed line ends with the outcome, such as
`— ready`. If it says `the fullscreen break couldn't be shown`, the reason is
in `logs/ergo.err`. The break needs `ui/nudge.html` and `ui/nudge.js`. If keys
don't respond, click the break once (recent macOS sometimes withholds keyboard
focus from background apps until a click); the buttons always work.

**Banner notifications don't appear** (banner style, or the fallback).
Notifications from `osascript` are listed under **Script Editor**: allow them in
**System Settings → Notifications → Script Editor**. If it isn't listed, open
Script Editor, run `display notification "hello"` once and approve. Also check
Focus / Do Not Disturb.

**launchd doesn't run ergo.**
First run `zsh ergo.sh --install` again from the folder; it regenerates and
reloads the agent with the correct path. If it still doesn't run, check that
`launchctl list | grep com.yourname.ergo` shows it loaded with exit status `0`,
that background items are allowed, and that `logs/ergo.err` is clean. Outside
work hours or days, a silent exit is correct.

**It works manually but not under launchd.**
launchd uses a minimal environment; ergo already finds its own folder and `jq`.
The usual causes are the plist path, background-item permission, or folder
privacy: a project in Desktop, Documents, Downloads or iCloud Drive shows
`Operation not permitted` in `logs/ergo.err`. Move it, update the plist, and
reload.

**`jq` is missing.** See [Requirements](#1-requirements).

**Invalid JSON.** `jq empty config.json` and `jq empty nudges.json` print the
line and column of the problem; common causes are trailing commas and smart
quotes. `./ergo.sh --reset-config` restores default settings.

**A Shortcut can't change settings.** Turn on **Allow Running Scripts**
(Shortcuts → Settings → Advanced), check the path in each Run Shell Script, and
allow folder access if macOS asks. If ergo says a change "would make config.json
invalid", nothing was saved and the message names the setting.

## 11. Uninstall

From the `ergo` folder:

```bash
./ergo.sh --uninstall
```

This stops ergo and removes `~/Library/LaunchAgents/com.yourname.ergo.plist`.
Your settings, cues and history stay in the folder. It works even if the
settings are invalid or `jq` is missing. To do the same by hand:

```bash
launchctl unload ~/Library/LaunchAgents/com.yourname.ergo.plist
```

```bash
rm ~/Library/LaunchAgents/com.yourname.ergo.plist
```

Delete the **ergo: …** Shortcuts yourself in the Shortcuts app. Optionally
remove the folder, which permanently deletes your settings and history
(`logs/`, `state/`):

```bash
rm -rf /path/to/ergo
```

Nothing else is installed anywhere on your Mac.

## 12. Command reference

```text
ergo.sh                    Scheduled run (what launchd calls every 5 minutes)
ergo.sh --test             Show a real break now, ignoring schedule and interval
ergo.sh --status           Settings, last/next nudge, diagnostics
ergo.sh --today            Today's movement summary
ergo.sh --reset-state      Clear nudge history (logs are kept)
ergo.sh --toggle           Pause or resume
ergo.sh --set KEY VALUE    Change one setting, keeping everything else
ergo.sh --reset-config     Restore default settings
ergo.sh --configure        Open the settings window
ergo.sh --install          Install and load the LaunchAgent for this folder
ergo.sh --uninstall        Unload and remove the LaunchAgent (keeps your data)
ergo.sh --help             Show help

ergo.sh --status-json          Machine-readable status (used by the settings window)
ergo.sh --apply-config JSON    Apply several settings at once, validated and atomic
```

`--apply-config` accepts only the editable settings (`enabled`,
`interval_minutes`, `work_start_hour`, `work_end_hour`, `work_days`, `sound`,
`quiet_mode`, `avoid_repeat_count`, `nudge_style`, `break_min_seconds`,
`break_max_seconds`). Other keys are ignored, and `log_file`, `state_file` and
any custom keys are preserved.

Exit codes: `0` success or a quiet skip, `1` error (message on stderr),
`2` unknown option.

## 13. Project layout

```text
ergo/
├── ergo.sh                    the engine: schedule, cue choice, breaks, logging, CLI
├── config.json                your settings (section 6)
├── nudges.json                the cue library (section 8)
├── com.yourname.ergo.plist    LaunchAgent template (section 3)
├── ui/
│   ├── nudge.html             the fullscreen break page
│   ├── nudge.js               JXA host: blurred overlay on every display, keyboard, chime
│   ├── configure.html         the settings page (also opens in a browser as a preview)
│   └── configure.js           JXA host: native settings window and its bridge to ergo.sh
├── shortcuts/
│   └── README.md              building the macOS Shortcuts and pinning them to the menu bar
├── logs/                      nudges.csv, ergo.out, ergo.err (created automatically)
├── state/                     state.json and the run lock (created automatically)
├── assets/                    icon and README images
├── README.md                  overview
└── SETUP.md                   this guide
```

Only `ergo.sh`, the two JSON files, the plist and `ui/` are needed to run ergo;
`logs/` and `state/` are recreated on demand. Both pages in `ui/` are
self-contained (no external resources) and never write files themselves: the
JXA hosts pass every change to `ergo.sh`.
