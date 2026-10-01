# ergo — Shortcuts

Optional macOS Shortcuts that make ergo feel like a small menu-bar app. They
call `ergo.sh`, so every change gets the same validation and safe writing as the
command line. Install ergo first ([SETUP.md](../SETUP.md)); for an overview see
the [README](../README.md).

---

## Shortcuts setup

ergo comes with four Shortcuts you build once in the **Shortcuts** app:

| Shortcut | What it does |
|---|---|
| **ergo: Toggle** | Pause or resume ergo |
| **ergo: Configure** | Change interval, hours, days, or sound |
| **ergo: Today** | Show today's movement summary |
| **ergo: Nudge Now** | Take a break right now |

### Before you start

1. Open **Shortcuts → Settings → Advanced** and turn on **Allow Running Scripts**. The **Run Shell Script** action needs this.
2. Find your ergo path by running `pwd` inside the `ergo` folder. The examples below use `/Users/you/Projects/ergo`. Replace it with yours everywhere.
3. In every **Run Shell Script** action, set **Shell** to `zsh` and leave **Run as Administrator** off.

### Why Run Shell Script?

Shortcuts can read and write JSON on its own, but it doesn't reliably keep JSON types when saving. A `true` can come back as the text `"true"`, and `45` as `"45"`. So the Shortcuts call small ergo helper commands (`--toggle`, `--set`, `--today`, `--test`), and those do the file work:

- read `config.json`
- change **only** the selected setting and keep every other setting as it was
- validate the whole configuration before saving, and refuse to save an invalid one
- write atomically (temporary file → `jq` check → rename)
- print a confirmation for the Shortcut to show

If a change is rejected, the Run Shell Script action fails and Shortcuts shows ergo's error message. `config.json` stays untouched.

---

### Shortcut A — "ergo: Toggle"

**Actions:**

1. **Run Shell Script**
   - Shell: `zsh`
   - Pass Input: `to stdin` (no input is used)
   - Script:
     ```bash
     /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --toggle
     ```
2. **Show Notification**
   - Title: `ergo`
   - Body: the **Shell Script Result** variable

**Result:** `ergo is active` or `ergo is paused`.

`--toggle` performs each step of the toggle safely: it reads `config.json`, gets `enabled`, inverts it, keeps every other property, writes JSON back, validates it, and saves atomically.

**Recommended:** pin this one to the menu bar (see [Menu bar experience](#menu-bar-experience)).

<details>
<summary>Alternative: native actions only, without a shell script (advanced)</summary>

You can build Toggle from native actions only. Shortcuts' handling of JSON booleans varies between macOS versions, though, so check the result with `./ergo.sh --status` afterward. If ergo reports `enabled must be true or false`, use the Run Shell Script version above.

1. **File**: choose `ergo/config.json`. On some macOS versions this action is called **Get File** or **Get File from Folder**. Shortcuts has no separate "Get Contents of File" action; passing the file on reads its contents.
2. **Get Dictionary from Input**: parses the JSON.
3. **Get Dictionary Value**: Get `Value` for `enabled`.
4. **If** Dictionary Value **is** true (the Boolean toggle, where offered):
   - **Dictionary**: one key `enabled`, type **Boolean**, value **off**
5. **Otherwise**:
   - **Dictionary**: one key `enabled`, type **Boolean**, value **on**
6. **End If**, then **Get Dictionary Value** `enabled` from the If Result. This gives a real Boolean.
7. **Set Dictionary Value**: set `enabled` to that value in the dictionary from step 2. All other keys are kept.
8. **Get Text from Input** with that dictionary: Shortcuts turns a dictionary into JSON text this way. It's the closest built-in equivalent to "Convert to JSON".
9. **Save File**: the macOS equivalent of "Write File". Turn **Ask Where to Save** off, set the destination to the `ergo` folder and subpath `config.json`, and turn **Overwrite If File Exists** on.
10. **Show Notification**: `ergo is active` or `ergo is paused`, using another If on the new value.

Native Save File isn't atomic and doesn't validate. Even if something goes wrong, ergo refuses to use an invalid config and writes the reason to `logs/ergo.err`. You can always restore defaults with `./ergo.sh --reset-config`.

</details>

---

### Shortcut B — "ergo: Configure"

**Option 1 (recommended): open the settings window.** One action gives you the full fullscreen settings screen (see [The settings window](../SETUP.md#5-the-settings-window)):

1. **Run Shell Script**
   ```bash
   /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --configure
   ```

The Shortcut finishes when you close the window. If the window doesn't appear when launched from Shortcuts on your macOS version, run `./ergo.sh --configure` from Terminal, or use Option 2.

**Option 2: native menus.** This works entirely inside Shortcuts' own dialogs:

**Actions:**

1. **Choose from Menu**
   - Prompt: `What would you like to change?`
   - Items: `Interval`, `Work start`, `Work end`, `Work days`, `Notification sound`, `Reset to defaults`

2. **Under "Interval":**
   1. **List**: `15 minutes`, `30 minutes`, `45 minutes`, `60 minutes`, `90 minutes`, `120 minutes`
   2. **Choose from List**, prompt `Remind me every…`
   3. **Run Shell Script**, Pass Input: **as arguments**
      ```bash
      /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set interval "$1"
      ```

3. **Under "Work start":**
   1. **List**: `07:00`, `08:00`, `09:00`, `10:00`
   2. **Choose from List**, prompt `Start reminders at…`
   3. **Run Shell Script**, Pass Input: **as arguments**
      ```bash
      /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set start "$1"
      ```

4. **Under "Work end":**
   1. **List**: `16:00`, `17:00`, `18:00`, `19:00`, `20:00`
   2. **Choose from List**, prompt `Stop reminders at…`
   3. **Run Shell Script**, Pass Input: **as arguments**
      ```bash
      /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set end "$1"
      ```

5. **Under "Work days":**
   1. **Choose from Menu**, prompt `Which days?`, items `Weekdays`, `Every day`, `Custom`
      - **Weekdays** → **Run Shell Script**:
        ```bash
        /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set days Weekdays
        ```
      - **Every day** → **Run Shell Script**:
        ```bash
        /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set days "Every day"
        ```
      - **Custom** →
        1. **List**: `Monday`, `Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday`, `Sunday`
        2. **Choose from List** with **Select Multiple** turned on
        3. **Run Shell Script**, Pass Input: **as arguments**
           ```bash
           /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set days "$@"
           ```
   2. **End Menu**

6. **Under "Notification sound":**
   1. **Choose from Menu**, items `On`, `Off`
      - **On** → **Run Shell Script**: `/bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set sound On`
      - **Off** → **Run Shell Script**: `/bin/zsh "/Users/you/Projects/ergo/ergo.sh" --set sound Off`
   2. **End Menu**

7. **Under "Reset to defaults":**
   1. **Show Alert**: `Reset all ergo settings to their defaults?`, with **Show Cancel Button** on. Cancel stops the Shortcut.
   2. **Run Shell Script**:
      ```bash
      /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --reset-config
      ```

8. **End Menu**, then **Show Result** with the **Menu Result** variable. That's the output of whichever branch ran.

**Example result:**

```text
ergo updated

Interval: 45 minutes
Work hours: 09:00–18:00
Days: Mon–Fri
Sound: Off
```

`--set` accepts friendly values, so the list items above can be passed straight through:

| Setting | Accepted values |
|---|---|
| `interval` | `45`, `45 minutes` |
| `start`, `end` | `9`, `09:00`, `6 PM` |
| `days` | `Weekdays`, `Every day`, `Weekends`, `Monday Wednesday`, `Mon,Wed,Fri`, `1,3,5` |
| `sound`, `quiet`, `enabled` | `On`, `Off` |
| `style` | `Fullscreen`, `Notification` (or `Banner`) |
| `breaks` | `10-45` (random multiple of 5 in the range, 10–240 sec), or `30` for a fixed length |
| `avoid-repeat` | `0`, `3`, `5` |

---

### Shortcut C — "ergo: Today"

**Actions:**

1. **Run Shell Script**
   ```bash
   /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --today
   ```
2. **Show Result**: the **Shell Script Result** variable

**Example:**

```text
ergo — Today

7 movement nudges

Categories
• Upper Body — 2
• Walking — 2
• Eyes — 1
• Hips — 1
• Wrists & Hands — 1

Estimated movement
3m 30s

Latest
14:45 — Shoulder Rolls
14:00 — Tiny Walking Break
13:15 — Screen Reset
```

With nothing logged yet today:

```text
ergo — Today

No movement nudges yet.

Your next reset will appear when it’s time.
```

How it's calculated:

- It reads `logs/nudges.csv` and keeps rows whose timestamp starts with today's date.
- Categories are counted and sorted by frequency.
- **Estimated movement** is the sum of the logged `duration_seconds`. Nothing is estimated or invented beyond what each cue declares.
- **Latest** lists the three most recent nudges.

Parsing CSV in Shortcuts alone (Split Text, Repeat, Match Text) breaks when a title contains a comma. `--today` uses a proper CSV parser.

---

### Shortcut D — "ergo: Nudge Now" (optional)

**Actions:**

1. **Run Shell Script**
   ```bash
   /bin/zsh "/Users/you/Projects/ergo/ergo.sh" --test
   ```

That's it. The nudge itself (the fullscreen break, or a banner if you chose that style) is the result. It's logged and counts toward the next interval like any other nudge. Handy for testing, or when you just want a break now.

### Optional: "ergo: Status"

A **Run Shell Script** with `--status` followed by **Show Result** gives you diagnostics from the menu bar.

---

## Menu bar experience

Pinned Shortcuts make ergo feel like a small menu-bar app, without a native app.

1. Open the **Shortcuts** app.
2. Optionally, create a folder called **ergo** in the sidebar and drag the four Shortcuts into it.
3. For each of **ergo: Toggle**, **ergo: Configure**, **ergo: Today**, and **ergo: Nudge Now**:
   1. Double-click the Shortcut to open it.
   2. Click the **ⓘ Shortcut Details** button in the right sidebar.
   3. Turn on **Pin in Menu Bar**.
4. A Shortcuts icon appears in the menu bar. Click it to see your pinned ergo Shortcuts.

Extras from the same Details panel:

- **Add Keyboard Shortcut**: for example `⌃⌥⌘E` for **ergo: Toggle**
- **Use as Quick Action**: run from the Services menu or Finder

