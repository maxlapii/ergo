# Build ergo — Native macOS Posture & Movement Companion

You are an expert macOS engineer specializing in zsh, launchd, AppleScript, macOS Shortcuts, JSON, and lightweight native macOS automation.

Implement a complete, polished desktop utility called **ergo**.

ergo is a lightweight posture and movement companion for macOS. It runs quietly in the background and periodically reminds the user to stand, walk, stretch, rest their eyes, change posture, or take a short movement break.

The implementation must use only built-in macOS technologies plus `jq`.

Do **not** use:

* Swift
* Xcode
* Python
* Node.js
* Electron
* Homebrew
* App Store applications
* third-party daemons
* cloud services
* external APIs
* databases
* network services

The finished project should feel like a small, polished native macOS utility rather than a collection of unrelated shell scripts.

---

# 1. IMPORTANT: EXISTING PROJECT ROOT

The project already exists and the coding agent is operating inside the existing:

```text
ergo/
```

directory.

**Treat `ergo/` as the project root.**

Do NOT create:

```text
~/Projects/ergo/
```

Do NOT create another nested `ergo` or `ergo` directory.

All implementation files must be created directly inside the existing project root.

The final project structure must be:

```text
ergo/
├── config.json
├── nudges.json
├── ergo.sh
├── com.yourname.ergo.plist
├── logs/
│   ├── nudges.csv
│   ├── ergo.out
│   └── ergo.err
├── state/
│   └── state.json
└── shortcuts/
    └── README.md
```

Create only the missing directories/files.

---

# 2. PRODUCT NAME

Product name:

**ergo**

Main executable:

```text
ergo.sh
```

LaunchAgent identifier:

```text
com.yourname.ergo
```

LaunchAgent filename:

```text
com.yourname.ergo.plist
```

Use **ergo** consistently in:

* notifications
* documentation
* Shortcut names
* comments
* LaunchAgent label
* examples
* log descriptions

---

# 3. PRODUCT GOAL

ergo must:

* run quietly in the background
* start automatically through launchd
* send gentle macOS notifications
* randomly select movement cues
* avoid repeating the same cues
* prefer category variety
* respect work days
* respect work hours
* respect a configurable interval
* log successful nudges to CSV
* provide configuration through macOS Shortcuts
* provide a daily summary
* support manual testing
* support status diagnostics
* keep all data local
* require no interactive Terminal session
* work without an internet connection

The tone should be:

* friendly
* concise
* encouraging
* non-medical
* non-judgmental

Do not use guilt-inducing or alarming language.

---

# 4. TECHNOLOGY

Use:

```text
/bin/zsh
osascript
launchd
jq
```

and standard macOS command-line tools such as:

```text
date
mkdir
printf
awk
sed
grep
tail
mktemp
mv
rm
cat
command
```

The script must use:

```bash
#!/bin/zsh
set -euo pipefail
```

Assume `jq` is installed, but detect it and provide a useful error if it is missing.

---

# 5. PATH HANDLING

Do NOT hard-code the project location into `ergo.sh`.

The script must determine its own directory dynamically.

The script should derive a project root similar to:

```text
PROJECT_DIR
```

from the location of `ergo.sh`.

Then use paths such as:

```text
$PROJECT_DIR/config.json
$PROJECT_DIR/nudges.json
$PROJECT_DIR/logs
$PROJECT_DIR/state
```

This is important because launchd may start the script with a different working directory.

Do not depend on the user's current working directory.

---

# 6. CONFIGURATION

Create:

```text
config.json
```

Use these sensible defaults:

```json
{
  "enabled": true,
  "interval_minutes": 60,
  "work_start_hour": 9,
  "work_end_hour": 18,
  "work_days": [1, 2, 3, 4, 5],
  "sound": false,
  "avoid_repeat_count": 3,
  "quiet_mode": false,
  "log_file": "logs/nudges.csv",
  "state_file": "state/state.json"
}
```

Required fields:

* `enabled`
* `interval_minutes`
* `work_start_hour`
* `work_end_hour`
* `work_days`
* `sound`
* `log_file`

Additional fields:

* `avoid_repeat_count`
* `quiet_mode`
* `state_file`

Validate:

* `interval_minutes > 0`
* `work_start_hour` is 0–23
* `work_end_hour` is 0–23
* every `work_days` value is 1–7
* `avoid_repeat_count >= 0`

If configuration is invalid:

* print a useful error to stderr
* exit non-zero
* do not display a user notification

---

# 7. MOVEMENT CUE LIBRARY

Create:

```text
nudges.json
```

Include at least **15 diverse cues**.

Each cue must contain:

```json
{
  "id": "unique-id",
  "title": "Short title",
  "body": "One or two concise sentences.",
  "category": "Category",
  "duration_seconds": 30,
  "routine_url": ""
}
```

Include cues covering:

1. Standing
2. Walking
3. Upper-body stretch
4. Lower-back movement
5. Hip movement
6. Neck release
7. Shoulder rolls
8. 20-20-20 eye break
9. Wrist/hand stretch
10. Chest-opening posture reset
11. Breathing reset
12. Leg/calf movement
13. Full-body reset
14. Keyboard hand release
15. Posture awareness/reset

Use categories such as:

```text
Standing
Walking
Upper Body
Neck & Shoulders
Lower Back
Hips
Eyes
Wrists & Hands
Breathing
Posture Reset
Legs
Full Body
```

Keep notification bodies short.

Do not make medical claims.

---

# 8. CREATIVE NOTIFICATION STYLE

Make ergo feel polished and friendly.

Example titles:

```text
Posture Reset
Tiny Walking Break
Shoulders Down
Screen Reset
Hands Off the Keyboard
Hip Reset
Open the Chest
Breathe & Reset
Stand Tall
Legs Need a Break
Neck Unclench
Full-Body Reset
```

Example body:

```text
Roll your shoulders back, relax your jaw, and take a moment to reset.
```

or:

```text
Stand up and walk around for a minute before returning to your desk.
```

or:

```text
Look at something in the distance for 20 seconds and let your eyes relax.
```

Keep the tone supportive and concise.

---

# 9. ANTI-REPEAT BEHAVIOR

Create:

```text
state/state.json
```

Example:

```json
{
  "last_nudge_epoch": 0,
  "last_cue_id": "",
  "last_category": "",
  "recent_cues": []
}
```

When selecting a cue:

1. Load all cues.
2. Read recent cue IDs.
3. Exclude recently used cues when enough alternatives exist.
4. Prefer a different category from the immediately previous cue.
5. Randomly select from remaining candidates.
6. Update state.

If every cue becomes excluded, reset the recent pool.

Never allow the anti-repeat system to prevent ergo from selecting a cue indefinitely.

---

# 10. TIME-AWARE VARIETY

Where practical, make cue selection slightly time-aware.

Morning can favor:

* posture reset
* mobility
* shoulders

Midday can favor:

* walking
* hips
* lower back
* standing

Afternoon can favor:

* eye breaks
* breathing
* gentle stretching

Do not over-engineer this.

Random variety should remain the primary selection mechanism.

---

# 11. INTERVAL ARCHITECTURE

Do NOT configure launchd to run once every configured reminder interval.

Instead:

```text
launchd
   ↓
runs ergo every 5 minutes
   ↓
ergo checks config.interval_minutes
   ↓
ergo decides whether a nudge is due
```

Use:

```xml
<key>StartInterval</key>
<integer>300</integer>
```

This means launchd wakes ergo every five minutes.

ergo should compare:

```text
current_epoch - last_nudge_epoch
```

against:

```text
interval_minutes × 60
```

This allows the user to change the interval using Shortcuts without reloading launchd.

Explain this design in the documentation.

---

# 12. WORK HOURS

Normal operation should only send nudges when:

```text
work_start_hour <= current_hour < work_end_hour
```

For example:

```text
09:00–17:59
```

when:

```text
work_start_hour = 9
work_end_hour = 18
```

Work days:

```text
1 = Monday
2 = Tuesday
3 = Wednesday
4 = Thursday
5 = Friday
6 = Saturday
7 = Sunday
```

If the current day or hour is outside the configured schedule:

* exit quietly
* do not log a nudge
* do not show a notification

---

# 13. STATE MANAGEMENT

The state file must track:

* last nudge epoch
* last cue ID
* last category
* recent cue IDs

Example:

```json
{
  "last_nudge_epoch": 0,
  "last_cue_id": "",
  "last_category": "",
  "recent_cues": []
}
```

Use epoch timestamps internally for interval calculations.

Use atomic writes:

1. create temporary file
2. write complete JSON
3. validate with `jq`
4. atomically replace original

Never leave a partially written state file.

---

# 14. LOCKING

Prevent multiple copies of ergo from running simultaneously.

Use a lightweight lock directory:

```text
state/.ergo.lock
```

If the lock already exists:

* exit quietly
* do not send a duplicate notification

Clean the lock up when the script exits.

---

# 15. CORE SCRIPT

Create:

```text
ergo.sh
```

It must:

1. determine its own project directory
2. locate configuration
3. locate cue library
4. create required directories
5. verify jq
6. validate JSON
7. read configuration
8. process command-line arguments
9. check enabled state
10. check quiet mode
11. determine local weekday
12. determine local hour
13. check work days
14. check work hours
15. check interval
16. select a cue
17. display notification
18. optionally play notification sound
19. log the successful nudge
20. update state
21. exit cleanly

No interactive input.

---

# 16. NOTIFICATION IMPLEMENTATION

Use `osascript`.

Use:

```applescript
display notification "..." with title "ergo"
```

or:

```applescript
display notification "..." with title "ergo — Posture Reset"
```

Properly escape:

* double quotes
* backslashes
* newlines
* special characters

Do not insert raw JSON strings into AppleScript without escaping.

If `sound=true`, use a native macOS notification sound or simple native beep.

---

# 17. LOGGING

Create:

```text
logs/nudges.csv
```

Initialize it with:

```csv
timestamp,title,cue_id,category,duration_seconds
```

Each successful nudge adds exactly one row.

Example:

```csv
2026-09-30 14:00:00,"Shoulder Rolls","shoulder-rolls","Neck & Shoulders",30
```

Implement proper CSV escaping.

Do not assume titles/categories contain no commas.

Do not log failed notification attempts as successful nudges.

---

# 18. COMMAND-LINE MODES

Implement:

### Normal mode

```bash
./ergo.sh
```

Runs normal ergo logic.

### Test

```bash
./ergo.sh --test
```

Test mode must:

* ignore work hours
* ignore work days
* ignore interval throttling
* still validate configuration
* select a real cue
* display a real notification
* log the nudge
* update state

### Status

```bash
./ergo.sh --status
```

Show something similar to:

```text
ergo
────────────────────────────
Status: Active
Work hours: 09:00–18:00
Work days: Mon–Fri
Interval: 60 minutes
Sound: Off
Last nudge: 13:45
Recent cues: 3
```

If disabled:

```text
Status: Paused
```

If never run:

```text
Last nudge: Never
```

### Reset state

```bash
./ergo.sh --reset-state
```

Clear:

* last nudge
* last cue
* last category
* recent cue history

Do not delete logs.

---

# 19. QUIET MODE

If:

```json
"quiet_mode": true
```

ergo should not display normal notifications.

It may still perform diagnostics if explicitly requested.

Document the behavior clearly.

---

# 20. LAUNCHAGENT

Create:

```text
com.yourname.ergo.plist
```

Use:

```xml
<key>Label</key>
<string>com.yourname.ergo</string>
```

Use:

```xml
<key>ProgramArguments</key>
<array>
    <string>/bin/zsh</string>
    <string>/Users/YOUR_USERNAME/ACTUAL/PATH/TO/ergo/ergo.sh</string>
</array>
```

The user must replace the example path with the actual absolute path to the existing `ergo` directory.

Use:

```xml
<key>RunAtLoad</key>
<true/>
```

and:

```xml
<key>StartInterval</key>
<integer>300</integer>
```

Use:

```xml
<key>StandardOutPath</key>
<string>/Users/YOUR_USERNAME/ACTUAL/PATH/TO/ergo/logs/ergo.out</string>

<key>StandardErrorPath</key>
<string>/Users/YOUR_USERNAME/ACTUAL/PATH/TO/ergo/logs/ergo.err</string>
```

Include comments at the top explaining:

* replacing `YOUR_USERNAME`
* replacing the example project path
* installing the plist
* loading it
* unloading it
* starting it manually

Do not use `~` inside plist paths where an absolute path is required.

---

# 21. MACOS SHORTCUTS

Create documentation for the following Shortcuts.

## Shortcut A — “ergo: Toggle”

Steps:

1. Read `config.json`.
2. Get `enabled`.
3. Invert the value.
4. Preserve every other configuration property.
5. Convert back to JSON.
6. Validate it.
7. Write it back safely.
8. Show notification.

When enabled:

```text
ergo is active
```

When disabled:

```text
ergo is paused
```

Recommend pinning this Shortcut to the Menu Bar.

---

# 22. SHORTCUT B — “ergo: Configure”

Main menu:

```text
What would you like to change?
```

Options:

* Interval
* Work start
* Work end
* Work days
* Notification sound
* Reset to defaults

Interval options:

```text
15 minutes
30 minutes
45 minutes
60 minutes
90 minutes
120 minutes
```

Work start:

```text
07:00
08:00
09:00
10:00
```

Work end:

```text
16:00
17:00
18:00
19:00
20:00
```

Sound:

```text
On
Off
```

Work days:

```text
Weekdays
Every day
Custom
```

When changing configuration:

* modify only the selected property
* preserve unrelated properties
* validate the JSON
* write safely
* show a confirmation

Example:

```text
ergo updated

Interval: 45 minutes
Work hours: 09:00–18:00
Days: Mon–Fri
Sound: Off
```

---

# 23. SHORTCUT C — “ergo: Today”

Read:

```text
logs/nudges.csv
```

Filter entries for today's date.

Display:

```text
ergo — Today

7 movement nudges

Categories
• Upper Body — 2
• Eyes — 1
• Walking — 2
• Hips — 1
• Wrists — 1

Estimated movement
3m 30s

Latest
14:45 — Shoulder Rolls
14:00 — Walking Break
13:15 — Eye Reset
```

Calculate estimated movement from `duration_seconds`.

Do not invent durations.

If there are no nudges:

```text
ergo — Today

No movement nudges yet.

Your next reset will appear when it's time.
```

---

# 24. OPTIONAL SHORTCUT D — “ergo: Nudge Now”

Also document:

```text
ergo: Nudge Now
```

It should:

1. run ergo in test/manual mode
2. display a real nudge
3. log it
4. update state

This is useful for testing and manually triggering a break.

---

# 25. SHORTCUT ACTION COMPATIBILITY

Use real built-in macOS Shortcuts actions such as:

* Get File
* Get Contents of File
* Get Text from Input
* Ask for Input
* Choose from Menu
* If
* Dictionary
* Get Dictionary Value
* Set Dictionary Value
* Convert to JSON
* Write File
* Show Notification
* Show Result
* Run Shell Script

If macOS versions use slightly different action names, explain the closest available built-in equivalent.

Do not invent nonexistent actions.

---

# 26. MENU BAR EXPERIENCE

Explain how to pin these Shortcuts to the macOS Menu Bar:

```text
ergo: Toggle
ergo: Configure
ergo: Today
ergo: Nudge Now
```

The goal is to make ergo feel like a lightweight menu-bar companion without building a native Swift menu-bar application.

---

# 27. DAILY SUMMARY

The “ergo: Today” Shortcut should calculate:

* total nudges
* category counts
* estimated movement duration
* latest nudge

Optionally include:

* first nudge
* number of unique categories
* longest movement cue

Keep the result compact.

---

# 28. PRIVACY

Document that ergo:

* stores everything locally
* makes no network requests
* collects no analytics
* does not access clipboard contents
* does not access camera
* does not access microphone
* does not access Health data
* does not send data to external services

The log contains only reminder-related information.

---

# 29. INSTALLATION

Because the `ergo/` directory already exists, do NOT create another project directory.

Start installation with:

```bash
cd /path/to/ergo
```

Then:

```bash
mkdir -p logs state shortcuts
```

Make the script executable:

```bash
chmod +x ergo.sh
```

Validate:

```bash
jq empty config.json
jq empty nudges.json
```

Run:

```bash
./ergo.sh --test
```

Then configure the LaunchAgent.

---

# 30. LAUNCHAGENT INSTALLATION

Create the LaunchAgents directory if necessary:

```bash
mkdir -p ~/Library/LaunchAgents
```

Copy the plist:

```bash
cp com.yourname.ergo.plist ~/Library/LaunchAgents/
```

Before loading it, replace the placeholder absolute paths with the real path to the existing `ergo` directory.

Then load:

```bash
launchctl load ~/Library/LaunchAgents/com.yourname.ergo.plist
```

Start manually:

```bash
launchctl start com.yourname.ergo
```

Explain how to inspect whether it is loaded.

---

# 31. LOGS

Explain how to inspect:

```text
logs/nudges.csv
logs/ergo.out
logs/ergo.err
state/state.json
```

The user should be able to diagnose most problems without opening source code.

---

# 32. TROUBLESHOOTING

Cover at least:

### Notifications don't appear

Check:

* macOS notification settings
* `./ergo.sh --test`
* `logs/ergo.err`

### launchd does not run

Check:

* absolute path in plist
* username
* executable permissions
* plist syntax
* launchctl state
* `logs/ergo.err`

### jq missing

Check:

```bash
command -v jq
```

Explain that `jq` is the only external dependency.

### Invalid JSON

Use:

```bash
jq empty config.json
jq empty nudges.json
```

### Works manually but not under launchd

Explain that launchd has a different environment and that ergo intentionally resolves its own project path.

### Shortcut cannot modify config

Explain:

* file permissions
* selecting the correct file
* preserving JSON structure
* using the project's actual `ergo/config.json`

---

# 33. CUSTOMIZATION

Document how to:

* change the reminder interval
* change working hours
* change working days
* enable sound
* add movement cues
* modify cue wording
* change cue duration
* change anti-repeat behavior
* enable/disable ergo
* reset state

Changing `config.json` should not require reloading launchd.

---

# 34. UNINSTALLATION

Provide exact commands to:

Unload:

```bash
launchctl unload ~/Library/LaunchAgents/com.yourname.ergo.plist
```

Remove:

```bash
rm ~/Library/LaunchAgents/com.yourname.ergo.plist
```

Optionally remove the project files:

```text
ergo/
```

Explain that macOS Shortcuts must be deleted separately.

Do not automatically delete user data without explicitly telling the user.

---

# 35. FINAL OUTPUT FORMAT

Return the implementation in exactly this structure:

## 1. Overview

Brief explanation of ergo.

## 2. Architecture

Show:

```text
launchd
   ↓
ergo.sh
   ↓
config.json + nudges.json + state/
   ↓
macOS notification
   ↓
logs/nudges.csv
   ↓
macOS Shortcuts
```

Explain the 5-minute launchd polling design.

## 3. Project Tree

Show:

```text
ergo/
├── config.json
├── nudges.json
├── ergo.sh
├── com.yourname.ergo.plist
├── logs/
├── state/
└── shortcuts/
```

## 4. Complete File Contents

Provide complete, ready-to-copy contents for:

### `config.json`

Full file.

### `nudges.json`

Full file.

### `ergo.sh`

Full file.

### `com.yourname.ergo.plist`

Full file.

### `shortcuts/README.md`

Full file.

Do NOT use:

```text
# rest of file...
```

Do NOT omit implementation details.

Do NOT provide pseudo-code where executable code is required.

## 5. Installation

Exact copy/paste commands.

## 6. Testing

Explain:

```bash
./ergo.sh --test
./ergo.sh --status
./ergo.sh --reset-state
```

## 7. LaunchAgent Management

Explain:

* load
* unload
* start
* inspect
* reload

## 8. Shortcut Setup

Detailed instructions for:

* ergo: Toggle
* ergo: Configure
* ergo: Today
* ergo: Nudge Now

## 9. Customization

Explain configuration and cue customization.

## 10. Troubleshooting

Provide practical diagnostics.

## 11. Uninstall

Provide exact cleanup steps.

---

# 36. FINAL QUALITY CHECK

Before presenting the implementation, verify internally that:

* `config.json` is valid JSON
* `nudges.json` is valid JSON
* `ergo.sh` has valid zsh syntax
* `set -euo pipefail` is used
* the project root is the existing `ergo/` directory
* no nested `ergo` directory is created
* no hard-coded project path exists in `ergo.sh`
* launchd uses an absolute executable path
* logs are created automatically
* state is created automatically
* CSV output is properly escaped
* JSON writes are atomic
* locking prevents duplicate runs
* anti-repeat behavior eventually resets
* notification text is safely escaped
* work-hour logic is correct
* work-day logic is correct
* interval logic is independent of launchd polling
* `--test` bypasses schedule and interval restrictions
* `--status` works
* `--reset-state` works
* Shortcuts preserve unrelated configuration values
* installation instructions match the actual project structure
* uninstall instructions match the installation
* no undocumented external dependencies are introduced

The implementation must be **complete, executable, internally consistent, copy/paste friendly, and ready to run from the existing `ergo/` project root**.
