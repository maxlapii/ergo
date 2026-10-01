#!/bin/zsh
#
# ergo — a lightweight posture & movement companion for macOS.
#
# launchd runs this script every 5 minutes. Each run decides whether a movement
# nudge is due (enabled, work day, work hours, interval elapsed). When it is,
# ergo picks a varied cue from nudges.json, shows a native notification, logs
# the nudge to CSV, and updates its state. Everything stays on this Mac.
#
# Usage:
#   ergo.sh                    Scheduled run (what launchd calls)
#   ergo.sh --test             Send a real nudge now, ignoring schedule and interval
#   ergo.sh --status           Show settings, last nudge, and schedule diagnostics
#   ergo.sh --today            Show today's movement summary
#   ergo.sh --reset-state      Clear nudge history (logs are kept)
#   ergo.sh --toggle           Pause or resume ergo
#   ergo.sh --set KEY VALUE    Change one setting (used by the Shortcuts)
#   ergo.sh --reset-config     Restore default settings
#   ergo.sh --configure        Open the fullscreen settings window (ui/)
#   ergo.sh --install          Install and load the LaunchAgent for this folder
#   ergo.sh --uninstall        Unload and remove the LaunchAgent (keeps your data)
#   ergo.sh --help             Show help
#
# Requirements: macOS built-in tools plus jq.

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
# Resolve the real location of this script (following symlinks) so ergo never
# depends on the working directory that launchd, Shortcuts, or Terminal use.
SCRIPT_PATH="${${(%):-%x}:A}"
PROJECT_DIR="${SCRIPT_PATH:h}"

CONFIG_FILE="$PROJECT_DIR/config.json"
NUDGES_FILE="$PROJECT_DIR/nudges.json"
LOG_DIR="$PROJECT_DIR/logs"
STATE_DIR="$PROJECT_DIR/state"
LOCK_DIR="$STATE_DIR/.ergo.lock"
UI_DIR="$PROJECT_DIR/ui"

LAUNCHD_LABEL="com.yourname.ergo"
PLIST_TEMPLATE="$PROJECT_DIR/com.yourname.ergo.plist"
PLIST_PLACEHOLDER="/Users/YOUR_USERNAME/ACTUAL/PATH/TO/ergo"   # replaced by the real folder on --install
LAUNCH_AGENTS_DIR="${ERGO_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SCHEDULE_GRACE_SECONDS=60   # absorbs launchd timing jitter so nudges don't drift by a whole poll
CSV_HEADER="timestamp,title,cue_id,category,duration_seconds"

# launchd starts jobs with a minimal PATH; make the usual jq locations visible.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin${PATH:+:$PATH}"
umask 022

DEFAULT_CONFIG='{
  "enabled": true,
  "interval_minutes": 60,
  "work_start_hour": 9,
  "work_end_hour": 18,
  "work_days": [1, 2, 3, 4, 5],
  "sound": false,
  "avoid_repeat_count": 3,
  "quiet_mode": false,
  "nudge_style": "fullscreen",
  "break_min_seconds": 10,
  "break_max_seconds": 45,
  "log_file": "logs/nudges.csv",
  "state_file": "state/state.json"
}'

DEFAULT_STATE='{"last_nudge_epoch": 0, "last_cue_id": "", "last_category": "", "recent_cues": []}'

# ─── jq programs ──────────────────────────────────────────────────────────────

# Shared helpers, prepended to the programs below.
JQ_LIB='
def isint: type == "number" and . == floor;
def last_n($n): if $n <= 0 then [] elif length > $n then .[length - $n:] else . end;
def pad2: tostring | if length < 2 then "0" + . else . end;
def clock: "\(pad2):00";
def dayname: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][. - 1];
def days_label:
  unique as $d
  | if $d == [1, 2, 3, 4, 5, 6, 7] then "Every day"
    elif $d == [6, 7] then "Weekends"
    else
      reduce $d[] as $x ([];
        if length > 0 and .[length - 1][-1] + 1 == $x then .[length - 1] += [$x] else . + [[$x]] end)
      | map(if length >= 3 then "\(.[0] | dayname)–\(.[-1] | dayname)" else map(dayname) | join(", ") end)
      | join(", ")
    end;
def duration_label:
  (if type == "number" then floor else 0 end) as $s
  | if $s < 60 then "\($s)s"
    elif $s < 3600 then "\($s / 60 | floor)m" + (if $s % 60 > 0 then " \($s % 60)s" else "" end)
    else "\($s / 3600 | floor)h" + (if $s % 3600 >= 60 then " \($s % 3600 / 60 | floor)m" else "" end)
    end;
def csv_fields:
  [ scan("(?:^|,)(\"(?:[^\"]|\"\")*\"|[^,]*)") | .[0]
    | if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end ];
def summary_lines:
  "Interval: \(.interval_minutes) minutes",
  "Work hours: \(.work_start_hour | clock)–\(.work_end_hour | clock)",
  "Days: \(.work_days | days_label)",
  "Sound: \(if .sound then "On" else "Off" end)",
  "Style: \(if (.nudge_style // "fullscreen") == "fullscreen" then "Fullscreen break" else "Notification banner" end)",
  "Break length: \((.break_min_seconds // 10) as $a | (.break_max_seconds // 45) as $b | if $a == $b then "\($a) sec" else "\($a)–\($b) sec (random, steps of 5)" end)";
'

# Prints one line per problem; prints nothing when config is valid.
JQ_VALIDATE_CONFIG='
def check(key; ok; problem; required):
  if has(key) then (if (.[key] | ok) then empty else "\(key) \(problem)" end)
  elif required then "missing required setting: \(key)"
  else empty end;
if type != "object" then "config.json must contain a JSON object"
else
  check("enabled"; type == "boolean"; "must be true or false"; true),
  check("interval_minutes"; isint and . > 0; "must be a whole number greater than 0"; true),
  check("work_start_hour"; isint and . >= 0 and . <= 23; "must be a whole number from 0 to 23"; true),
  check("work_end_hour"; isint and . >= 0 and . <= 23; "must be a whole number from 0 to 23"; true),
  check("work_days"; type == "array" and length > 0 and all(.[]; isint and . >= 1 and . <= 7);
        "must be a non-empty list of days from 1 (Monday) to 7 (Sunday)"; true),
  check("sound"; type == "boolean"; "must be true or false"; true),
  check("log_file"; type == "string" and length > 0; "must be a non-empty file path"; true),
  check("avoid_repeat_count"; isint and . >= 0; "must be a whole number of 0 or more"; false),
  check("quiet_mode"; type == "boolean"; "must be true or false"; false),
  check("state_file"; type == "string" and length > 0; "must be a non-empty file path"; false),
  check("nudge_style"; . == "fullscreen" or . == "notification"; "must be \"fullscreen\" or \"notification\""; false),
  check("break_min_seconds"; isint and . >= 10 and . <= 240 and . % 5 == 0; "must be a multiple of 5 from 10 to 240"; false),
  check("break_max_seconds"; isint and . >= 10 and . <= 240 and . % 5 == 0; "must be a multiple of 5 from 10 to 240"; false),
  (if ((.break_min_seconds // 10) | isint) and ((.break_max_seconds // 45) | isint)
      and (.break_min_seconds // 10) > (.break_max_seconds // 45)
   then "break_min_seconds must not be greater than break_max_seconds" else empty end),
  (if (.work_start_hour | isint) and .work_start_hour == .work_end_hour
   then "work_start_hour and work_end_hour must be different" else empty end)
end'

JQ_VALIDATE_NUDGES='
if type != "array" then "nudges.json must contain a JSON array of cues"
elif length == 0 then "nudges.json must contain at least one cue"
else
  ( to_entries[] | .key as $i | .value
    | if type != "object" then "cue #\($i + 1) must be a JSON object"
      else
        (if (.id | type) == "string" and (.id | length) > 0 then .id else "#\($i + 1)" end) as $name
        | ( ("id", "title", "body", "category") as $field
            | if (.[$field] | type) == "string" and (.[$field] | length) > 0 then empty
              else "cue \($name): \($field) must be a non-empty string" end ),
          ( if (.duration_seconds | isint) and .duration_seconds >= 0 then empty
            else "cue \($name): duration_seconds must be a whole number of 0 or more" end ),
          ( if has("routine_url") and (.routine_url | type) != "string"
            then "cue \($name): routine_url must be a string" else empty end )
      end ),
  ( [ .[] | objects | .id | strings ] | group_by(.) | map(select(length > 1) | .[0])[]
    | "duplicate cue id: \(.)" )
end'

# Reads state.json slurped (-s) and always yields a complete, well-typed state.
JQ_NORMALIZE_STATE='
(if length > 0 and (.[0] | type) == "object" then .[0] else {} end)
| {
    last_nudge_epoch: (if (.last_nudge_epoch | type) == "number" then (.last_nudge_epoch | floor) else 0 end),
    last_cue_id: (if (.last_cue_id | type) == "string" then .last_cue_id else "" end),
    last_category: (if (.last_category | type) == "string" then .last_category else "" end),
    recent_cues: (if (.recent_cues | type) == "array" then [.recent_cues[] | strings] else [] end)
  }'

# Cue selection. Input: the nudges array. Output: {cue, recent}.
#   1. Skip the last $keep cues when anything else is left; otherwise reset the pool.
#   2. Prefer a category different from the previous cue.
#   3. Give categories that suit the time of day double weight.
#   4. Pick randomly (weighted) using $rand.
JQ_SELECT_CUE='
. as $all
| ($recent | last_n($keep)) as $avoid
| [ $all[] | select(.id as $id | any($avoid[]; . == $id) | not) ] as $fresh
| (if ($fresh | length) > 0 then {pool: $fresh, reset: false}
   else {pool: ([ $all[] | select(.id != $last_id) ] | if length > 0 then . else $all end), reset: true}
   end) as $p
| ([ $p.pool[] | select(.category != $last_category) ] | if length > 0 then . else $p.pool end) as $candidates
| ({ morning:   ["Posture Reset", "Neck & Shoulders", "Upper Body", "Full Body"],
     midday:    ["Walking", "Standing", "Hips", "Lower Back", "Legs"],
     afternoon: ["Eyes", "Breathing", "Wrists & Hands", "Upper Body"] }[$bucket] // []) as $favored
| [ $candidates[] | if (.category as $c | any($favored[]; . == $c)) then 2 else 1 end ] as $weights
| ($rand % ($weights | add)) as $target
| (reduce range(0; $weights | length) as $i ({sum: 0, pick: null};
     if .pick == null then .sum += $weights[$i] | (if $target < .sum then .pick = $i else . end) else . end)
  ) as $choice
| $candidates[$choice.pick] as $cue
| { cue: $cue,
    recent: ((if $p.reset then [] else $recent end) + [$cue.id] | last_n($keep)) }'

# Daily summary data. Input: raw lines of nudges.csv (-R -n).
JQ_TODAY_DATA='
[ inputs | select(startswith($today + " ")) | csv_fields
  | { time: ((.[0] // "")[11:16]),
      title: (.[1] // ""),
      category: (if (.[3] // "") == "" then "Other" else .[3] end),
      seconds: ((.[4] // "") | tonumber? // 0) } ] as $rows
| { count: ($rows | length),
    seconds: ($rows | map(.seconds) | add // 0),
    categories: ([ $rows | group_by(.category)[] | {name: .[0].category, count: length} ] | sort_by(-.count, .name)),
    latest: [ $rows | reverse | .[:3][] | {time, title} ],
    first: ($rows[0].time // null) }'

# Daily summary text. Input: the output of JQ_TODAY_DATA.
JQ_TODAY_TEXT='
if .count == 0 then
  "ergo — Today\n\nNo movement nudges yet.\n\nYour next reset will appear when it’s time."
else
  [ "ergo — Today",
    "",
    "\(.count) movement nudge\(if .count == 1 then "" else "s" end)",
    "",
    "Categories",
    (.categories[] | "• \(.name) — \(.count)"),
    "",
    "Estimated movement",
    (.seconds | duration_label),
    "",
    "Latest",
    (.latest[] | "\(.time) — \(.title)")
  ]
  | join("\n")
end'

# ─── Helpers ──────────────────────────────────────────────────────────────────

die()  { print -u2 -r -- "ergo: $*"; exit 1; }
warn() { print -u2 -r -- "ergo: warning: $*"; }

# Print a heading plus a bullet list of problems to stderr, then exit non-zero.
fail_with_errors() {
  local heading=$1 errors=$2 line
  print -u2 -r -- "ergo: $heading"
  for line in "${(@f)errors}"; do
    print -u2 -r -- "  • $line"
  done
  exit 1
}

usage() {
  cat <<'USAGE'
ergo — a lightweight posture & movement companion for macOS

Usage:
  ergo.sh                    Scheduled run (what launchd calls every 5 minutes)
  ergo.sh --test             Send a real nudge now, ignoring schedule and interval
  ergo.sh --status           Show settings, last nudge, and schedule diagnostics
  ergo.sh --today            Show today's movement summary
  ergo.sh --reset-state      Clear nudge history (logs are kept)
  ergo.sh --toggle           Pause or resume ergo
  ergo.sh --set KEY VALUE    Change one setting, keeping everything else
  ergo.sh --reset-config     Restore default settings
  ergo.sh --configure        Open the fullscreen settings window
  ergo.sh --install          Install and load the LaunchAgent for this folder
  ergo.sh --uninstall        Unload and remove the LaunchAgent (keeps your data)
  ergo.sh --help             Show this help

Used by the settings window and Shortcuts:
  ergo.sh --status-json          Machine-readable status
  ergo.sh --apply-config JSON    Apply several settings at once, validated

Settings for --set:
  interval      15, 30, "45 minutes", ...
  start, end    9, 18, "09:00", "6 PM"
  days          Weekdays, "Every day", Weekends, "Mon,Wed,Fri", "1,3,5"
  sound         On | Off
  quiet         On | Off
  enabled       On | Off
  style         Fullscreen | Notification
  breaks        "10-45" (random multiple of 5 in the range, 10–240 sec) | "30" (fixed)
  avoid-repeat  0, 3, 5, ...
USAGE
}

# ─── Cleanup & locking ────────────────────────────────────────────────────────

LOCK_HELD=false
typeset -a TEMP_FILES=()

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    if [[ -e $file ]]; then rm -f -- "$file"; fi
  done
  if [[ $LOCK_HELD == true ]]; then rm -rf -- "$LOCK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# acquire_lock ATTEMPTS — mkdir is atomic, so only one ergo run can hold the lock.
acquire_lock() {
  local attempts=${1:-1} owner age reclaimed=false
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=true
      print -r -- $$ > "$LOCK_DIR/pid"
      return 0
    fi
    # Reclaim a lock left behind by a run that was killed (e.g. a forced shutdown).
    # A fullscreen break can legitimately hold the lock for many minutes, so only a
    # lock older than an hour is treated as stale while its owner still runs.
    if [[ $reclaimed == false ]]; then
      owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s) ))
      if (( age > 3600 )) || { [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null } \
         || { [[ -z $owner ]] && (( age > 60 )) }; then
        reclaimed=true
        rm -rf -- "$LOCK_DIR" 2>/dev/null || return 1
        continue
      fi
    fi
    attempts=$(( attempts - 1 ))
    if (( attempts <= 0 )); then return 1; fi
    sleep 0.5
  done
}

# ─── Files & JSON ─────────────────────────────────────────────────────────────

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    die "jq is required but was not found. jq ships with macOS 15 (Sequoia) and later as /usr/bin/jq; on older macOS, put a jq binary from https://jqlang.org in /usr/local/bin. Check with: command -v jq"
  fi
}

# write_json_atomic TARGET JSON — temp file → validate → rename. Never leaves a partial file.
write_json_atomic() {
  local target=$1 json=$2 tmp mode
  tmp=$(mktemp "${target:h}/.${target:t}.XXXXXX") || die "cannot create a temporary file next to $target"
  TEMP_FILES+=("$tmp")
  if ! print -r -- "$json" | jq . > "$tmp" 2>/dev/null || ! jq empty "$tmp" 2>/dev/null; then
    die "refusing to write invalid JSON to $target"
  fi
  if [[ -e $target ]]; then mode=$(stat -f %Lp "$target"); else mode=644; fi
  chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$target"
}

resolve_path() {
  case $1 in
    /*)     print -r -- "$1" ;;
    "~/"*)  print -r -- "$HOME/${1#"~/"}" ;;
    *)      print -r -- "$PROJECT_DIR/$1" ;;
  esac
}

ensure_config() {
  if [[ ! -f $CONFIG_FILE ]]; then
    write_json_atomic "$CONFIG_FILE" "$DEFAULT_CONFIG"
    warn "config.json was missing, so a default one was created."
  fi
}

require_config_syntax() {
  local err
  if ! err=$(jq empty "$CONFIG_FILE" 2>&1); then
    die "config.json is not valid JSON ($err). Fix it, or restore defaults with: $SCRIPT_PATH --reset-config"
  fi
}

config_errors() { jq -r "$JQ_LIB $JQ_VALIDATE_CONFIG" 2>&1; }   # JSON on stdin

validate_config_file() {
  local errors
  require_config_syntax
  errors=$(config_errors < "$CONFIG_FILE") || true
  if [[ -n $errors ]]; then
    fail_with_errors "config.json is invalid ($CONFIG_FILE):" "$errors"
  fi
}

validate_nudges_file() {
  local err errors
  [[ -f $NUDGES_FILE ]] || die "cue library not found: $NUDGES_FILE"
  if ! err=$(jq empty "$NUDGES_FILE" 2>&1); then
    die "nudges.json is not valid JSON ($err). Check it with: jq empty nudges.json"
  fi
  errors=$(jq -r "$JQ_LIB $JQ_VALIDATE_NUDGES" "$NUDGES_FILE" 2>&1) || true
  if [[ -n $errors ]]; then
    fail_with_errors "nudges.json is invalid ($NUDGES_FILE):" "$errors"
  fi
}

load_config() {
  eval "$(jq -r "$JQ_LIB"' @sh "
    CFG_ENABLED=\(.enabled)
    CFG_INTERVAL=\(.interval_minutes)
    CFG_START=\(.work_start_hour)
    CFG_END=\(.work_end_hour)
    CFG_DAYS_STR=\(.work_days | unique | map(tostring) | join(" "))
    CFG_DAYS_LABEL=\(.work_days | days_label)
    CFG_HOURS_LABEL=\(.work_start_hour | clock)–\(.work_end_hour | clock)
    CFG_SOUND=\(.sound)
    CFG_REPEAT=\(.avoid_repeat_count // 3)
    CFG_QUIET=\(.quiet_mode // false)
    CFG_STYLE=\(.nudge_style // "fullscreen")
    CFG_BREAK_MIN=\(.break_min_seconds // 10)
    CFG_BREAK_MAX=\(.break_max_seconds // 45)
    CFG_LOG_FILE=\(.log_file)
    CFG_STATE_FILE=\(.state_file // "state/state.json")"' "$CONFIG_FILE")"
  typeset -ga CFG_DAYS=(${=CFG_DAYS_STR})
  LOG_FILE=$(resolve_path "$CFG_LOG_FILE")
  STATE_FILE=$(resolve_path "$CFG_STATE_FILE")
}

# Create logs and state automatically so a fresh checkout just works.
prepare_files() {
  local file
  mkdir -p "$LOG_DIR" "$STATE_DIR" "${LOG_FILE:h}" "${STATE_FILE:h}"
  for file in "$LOG_DIR/ergo.out" "$LOG_DIR/ergo.err"; do
    if [[ ! -e $file ]]; then : > "$file"; fi
  done
  if [[ ! -s $LOG_FILE ]]; then
    print -r -- "$CSV_HEADER" > "$LOG_FILE"
  fi
}

load_state() {
  local backup
  if [[ -s $STATE_FILE ]] && ! jq empty "$STATE_FILE" 2>/dev/null; then
    backup="$STATE_FILE.corrupt-$(date +%Y%m%d-%H%M%S)"
    mv -f -- "$STATE_FILE" "$backup"
    warn "state file was unreadable; moved it to ${backup:t} and started fresh."
  fi
  if [[ ! -s $STATE_FILE ]]; then
    write_json_atomic "$STATE_FILE" "$DEFAULT_STATE"
  fi
  STATE_JSON=$(jq -c -s "$JQ_NORMALIZE_STATE" "$STATE_FILE")
  eval "$(jq -r '@sh "
    ST_LAST_EPOCH=\(.last_nudge_epoch)
    ST_LAST_ID=\(.last_cue_id)
    ST_LAST_CATEGORY=\(.last_category)
    ST_RECENT_COUNT=\(.recent_cues | length)"' <<<"$STATE_JSON")"
}

# ─── Schedule ─────────────────────────────────────────────────────────────────

is_work_day() { (( ${CFG_DAYS[(Ie)$1]} )); }

# work_start <= hour < work_end. A start later than the end wraps past midnight.
is_work_hour() {
  if (( CFG_START < CFG_END )); then
    (( $1 >= CFG_START && $1 < CFG_END ))
  else
    (( $1 >= CFG_START || $1 < CFG_END ))
  fi
}

local_hour() {
  local hour
  hour=$(date -r "$1" +%H)
  print -r -- $(( 10#$hour ))
}

# evaluate_schedule NOW — sets DECISION to: paused | quiet | off_day | off_hours | waiting | due
evaluate_schedule() {
  local now=$1 weekday hour interval_s wait_s
  read -r weekday hour <<<"$(date -r "$now" '+%u %H')"
  hour=$(( 10#$hour ))
  interval_s=$(( CFG_INTERVAL * 60 ))
  wait_s=$(( interval_s > SCHEDULE_GRACE_SECONDS ? interval_s - SCHEDULE_GRACE_SECONDS : 0 ))

  if [[ $CFG_ENABLED != true ]]; then
    DECISION=paused
  elif [[ $CFG_QUIET == true ]]; then
    DECISION=quiet
  elif ! is_work_day "$weekday"; then
    DECISION=off_day
  elif ! is_work_hour "$hour"; then
    DECISION=off_hours
  elif (( ST_LAST_EPOCH > 0 && now >= ST_LAST_EPOCH && now - ST_LAST_EPOCH < wait_s )); then
    DECISION=waiting
  else
    DECISION=due   # never nudged, interval elapsed, or the clock moved backwards
  fi
}

# First moment at or after EPOCH that falls on a work day inside work hours.
next_window_epoch() {
  local t=$1 wd h m s i
  read -r wd h m s <<<"$(date -r "$t" '+%u %H %M %S')"
  h=$(( 10#$h )); m=$(( 10#$m )); s=$(( 10#$s ))
  if is_work_day "$wd" && is_work_hour "$h"; then print -r -- "$t"; return; fi
  t=$(( t - m * 60 - s ))
  for (( i = 0; i < 8 * 24; i++ )); do
    t=$(( t + 3600 )); h=$(( h + 1 ))
    if (( h == 24 )); then h=0; wd=$(( wd % 7 + 1 )); fi
    if is_work_day "$wd" && is_work_hour "$h"; then print -r -- "$t"; return; fi
  done
  print -r -- "$1"
}

time_bucket() {
  if (( $1 < 11 )); then print morning
  elif (( $1 < 14 )); then print midday
  else print afternoon
  fi
}

# ─── Formatting ───────────────────────────────────────────────────────────────

# friendly_time EPOCH NOW → "14:45", "Yesterday 17:00", "Tomorrow 09:00", "Mon 28 Sep, 17:00"
friendly_time() {
  local epoch=$1 now=$2 day
  day=$(date -r "$epoch" +%F)
  if [[ $day == $(date -r "$now" +%F) ]]; then
    date -r "$epoch" '+%H:%M'
  elif [[ $day == $(date -r "$now" -v-1d +%F) ]]; then
    date -r "$epoch" '+Yesterday %H:%M'
  elif [[ $day == $(date -r "$now" -v+1d +%F) ]]; then
    date -r "$epoch" '+Tomorrow %H:%M'
  else
    date -r "$epoch" '+%a %d %b, %H:%M'
  fi
}

# 20 → "20 sec", 60 → "1 min", 90 → "1 min 30 sec"
friendly_duration() {
  local s=$1
  if (( s < 60 )); then print -r -- "$s sec"
  elif (( s % 60 == 0 )); then print -r -- "$(( s / 60 )) min"
  else print -r -- "$(( s / 60 )) min $(( s % 60 )) sec"
  fi
}

# Notifications are single-line; turn tabs, newlines, and other control characters into spaces.
clean_text() { print -r -- "${1//[[:cntrl:]]/ }"; }

print_config_summary() { jq -r "$JQ_LIB summary_lines" "$CONFIG_FILE"; }

# ─── Nudge delivery ───────────────────────────────────────────────────────────

random_number() {
  local n
  n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
  if [[ $n != <-> ]]; then n=$(( RANDOM * 32768 + RANDOM )); fi
  print -r -- "$n"
}

# send_notification TITLE SUBTITLE BODY SOUND
# The text travels to AppleScript as argv items, never spliced into script source,
# so quotes, backslashes, and any other characters cannot break or inject code.
send_notification() {
  osascript - "$1" "$2" "$3" "$4" >/dev/null <<'APPLESCRIPT'
on run argv
	set theTitle to item 1 of argv
	set theSubtitle to item 2 of argv
	set theBody to item 3 of argv
	if item 4 of argv is "true" then
		display notification theBody with title theTitle subtitle theSubtitle sound name "Glass"
	else
		display notification theBody with title theTitle subtitle theSubtitle
	end if
end run
APPLESCRIPT
}

# Break length: a random multiple of 5 between break_min_seconds and break_max_seconds.
pick_break_seconds() {
  local steps=$(( (CFG_BREAK_MAX - CFG_BREAK_MIN) / 5 + 1 ))
  print -r -- $(( CFG_BREAK_MIN + 5 * ($(random_number) % steps) ))
}

# show_break SELECTION — fullscreen break overlay (ui/nudge.*). Blocks until it closes,
# then prints the outcome: completed | ready | skipped | timeout. Fails if it couldn't be shown.
show_break() {
  local selection=$1 payload result outcome
  [[ -f $UI_DIR/nudge.html && -f $UI_DIR/nudge.js ]] || return 1
  payload=$(jq -c -n --argjson selection "$selection" --argjson sound "$CFG_SOUND" \
    '{ cue: ($selection.cue | {id, title, body, category, duration_seconds, routine_url: (.routine_url // "")}),
       sound: $sound }')
  result=$(osascript -l JavaScript "$UI_DIR/nudge.js" "$UI_DIR/nudge.html" "$payload") || return 1
  outcome=$(print -r -- "$result" | jq -r '.outcome // empty' 2>/dev/null) || return 1
  [[ -n $outcome ]] || return 1
  print -r -- "$outcome"
}

deliver_nudge() {
  local now=$1 selection subtitle timestamp csv_row outcome="" delivered=false
  selection=$(jq -c \
    --argjson recent "$(jq -c '.recent_cues' <<<"$STATE_JSON")" \
    --arg last_id "$ST_LAST_ID" \
    --arg last_category "$ST_LAST_CATEGORY" \
    --argjson keep "$CFG_REPEAT" \
    --arg bucket "$(time_bucket "$(local_hour "$now")")" \
    --argjson rand "$(random_number)" \
    "$JQ_LIB $JQ_SELECT_CUE" "$NUDGES_FILE")
  [[ -n $selection ]] || die "could not select a cue from nudges.json"

  # The break length shown, timed, and logged for this nudge.
  selection=$(jq -c --argjson seconds "$(pick_break_seconds)" '.cue.duration_seconds = $seconds' <<<"$selection")

  eval "$(jq -r '.cue | @sh "
    CUE_ID=\(.id)
    CUE_TITLE=\(.title)
    CUE_BODY=\(.body)
    CUE_CATEGORY=\(.category)
    CUE_DURATION=\(.duration_seconds)
    CUE_URL=\(.routine_url // "")"' <<<"$selection")"

  subtitle=$CUE_CATEGORY
  if (( CUE_DURATION > 0 )); then subtitle+=" · $(friendly_duration "$CUE_DURATION")"; fi

  if [[ $CFG_STYLE == fullscreen ]]; then
    if outcome=$(show_break "$selection"); then
      delivered=true
    else
      outcome=""
      warn "the fullscreen break couldn't be shown, so a notification was sent instead."
    fi
  fi
  if [[ $delivered == false ]]; then
    if ! send_notification "ergo — $(clean_text "$CUE_TITLE")" "$(clean_text "$subtitle")" \
                           "$(clean_text "$CUE_BODY")" "$CFG_SOUND"; then
      die "the notification could not be displayed, so this nudge was not logged."
    fi
  fi

  # Log only after the nudge was shown. @csv quotes and escapes every text field.
  timestamp=$(date -r "$now" '+%Y-%m-%d %H:%M:%S')
  csv_row=$(jq -r --arg ts "$timestamp" '
    .cue | [.title, .id, .category, .duration_seconds]
    | map(if type == "string" then gsub("[\r\n\t]+"; " ") else . end)
    | "\($ts),\(@csv)"' <<<"$selection")
  print -r -- "$csv_row" >> "$LOG_FILE"

  write_json_atomic "$STATE_FILE" "$(jq -c --argjson now "$now" '{
    last_nudge_epoch: $now,
    last_cue_id: .cue.id,
    last_category: .cue.category,
    recent_cues: .recent }' <<<"$selection")"

  print -r -- "$timestamp  nudge  $CUE_TITLE ($subtitle)${outcome:+ — $outcome}"
  if [[ -n $CUE_URL && $delivered == false ]]; then print -r -- "Routine: $CUE_URL"; fi
}

# ─── Modes ────────────────────────────────────────────────────────────────────

run_scheduled() {
  local now
  acquire_lock 1 || exit 0          # another run is active: exit quietly
  load_state
  now=$(date +%s)
  evaluate_schedule "$now"
  [[ $DECISION == due ]] || exit 0  # outside schedule or not yet due: exit quietly
  deliver_nudge "$now"
}

run_test() {
  local now
  acquire_lock 6 || die "another ergo run is in progress. Try again in a moment."
  load_state
  now=$(date +%s)
  deliver_nudge "$now"
  if [[ $CFG_ENABLED != true ]]; then
    print "Note: ergo is paused, so scheduled nudges are off. Manual nudges still work."
  elif [[ $CFG_QUIET == true ]]; then
    print "Note: quiet mode is on, so scheduled nudges are muted. Manual nudges still work."
  fi
}

# collect_status — sets STATUS_NOW, STATUS_LABEL, LAST_TEXT, NEXT_TEXT, AGENT_LOADED (and DECISION).
collect_status() {
  local last_title
  load_state
  STATUS_NOW=$(date +%s)
  evaluate_schedule "$STATUS_NOW"

  case $DECISION in
    paused) STATUS_LABEL="Paused" ;;
    quiet)  STATUS_LABEL="Quiet mode (scheduled nudges muted)" ;;
    *)      STATUS_LABEL="Active" ;;
  esac

  if (( ST_LAST_EPOCH > 0 )); then
    LAST_TEXT=$(friendly_time "$ST_LAST_EPOCH" "$STATUS_NOW")
    last_title=$(jq -r --arg id "$ST_LAST_ID" 'map(select(.id == $id))[0].title // empty' "$NUDGES_FILE")
    if [[ -n $last_title ]]; then LAST_TEXT+=" — $last_title"; fi
  else
    LAST_TEXT="Never"
  fi

  case $DECISION in
    paused)    NEXT_TEXT="— (paused)" ;;
    quiet)     NEXT_TEXT="— (quiet mode)" ;;
    due)       NEXT_TEXT="Due now (at the next launchd check)" ;;
    waiting)   NEXT_TEXT="~$(friendly_time "$(next_window_epoch $(( ST_LAST_EPOCH + CFG_INTERVAL * 60 )))" "$STATUS_NOW")" ;;
    off_day)   NEXT_TEXT="~$(friendly_time "$(next_window_epoch "$STATUS_NOW")" "$STATUS_NOW") (not a work day now)" ;;
    off_hours) NEXT_TEXT="~$(friendly_time "$(next_window_epoch "$STATUS_NOW")" "$STATUS_NOW") (outside work hours now)" ;;
  esac

  if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then AGENT_LOADED=true; else AGENT_LOADED=false; fi
}

today_data() {
  jq -c -R -n --arg today "$(date +%F)" "$JQ_LIB $JQ_TODAY_DATA" < "$LOG_FILE"
}

run_status() {
  local today count_today cue_count agent
  collect_status
  today=$(date -r "$STATUS_NOW" +%F)
  count_today=$(grep -c "^$today " "$LOG_FILE" 2>/dev/null || true)
  cue_count=$(jq 'length' "$NUDGES_FILE")
  if [[ $AGENT_LOADED == true ]]; then agent="Loaded ($LAUNCHD_LABEL)"; else agent="Not loaded"; fi

  print "ergo"
  print "────────────────────────────"
  printf '%-13s %s\n' \
    "Status:"      "$STATUS_LABEL" \
    "Work hours:"  "$CFG_HOURS_LABEL" \
    "Work days:"   "$CFG_DAYS_LABEL" \
    "Interval:"    "$CFG_INTERVAL minutes" \
    "Sound:"       "$([[ $CFG_SOUND == true ]] && print On || print Off)" \
    "Nudge style:" "$([[ $CFG_STYLE == fullscreen ]] && print "Fullscreen break" || print "Notification banner")" \
    "Break length:" "$( (( CFG_BREAK_MIN == CFG_BREAK_MAX )) && print "$CFG_BREAK_MIN sec" || print "Random $CFG_BREAK_MIN–$CFG_BREAK_MAX sec (steps of 5)")" \
    "Last nudge:"  "$LAST_TEXT" \
    "Next nudge:"  "$NEXT_TEXT" \
    "Recent cues:" "$ST_RECENT_COUNT" \
    "Today:"       "${count_today:-0} nudge$([[ ${count_today:-0} == 1 ]] || print s)" \
    "Cue library:" "$cue_count cues" \
    "LaunchAgent:" "$agent" \
    "Project:"     "$PROJECT_DIR"
}

run_status_json() {
  collect_status
  jq -n \
    --slurpfile config "$CONFIG_FILE" \
    --slurpfile cues "$NUDGES_FILE" \
    --argjson defaults "$DEFAULT_CONFIG" \
    --argjson state "$STATE_JSON" \
    --argjson today "$(today_data)" \
    --arg label "$STATUS_LABEL" --arg decision "$DECISION" \
    --arg last "$LAST_TEXT" --arg next "$NEXT_TEXT" \
    --argjson agent "$AGENT_LOADED" \
    --arg project "$PROJECT_DIR" --argjson now "$STATUS_NOW" \
    '{ config: $config[0],
       defaults: $defaults,
       state: $state,
       today: $today,
       cues: [ $cues[0][] | {id, title, body, category, duration_seconds} ],
       status: { label: $label, decision: $decision, last: $last, next: $next, launch_agent_loaded: $agent },
       project_dir: $project,
       generated_at: $now }'
}

run_today() {
  today_data | jq -r "$JQ_LIB $JQ_TODAY_TEXT"
}

run_configure() {
  local payload
  [[ -f $UI_DIR/configure.html && -f $UI_DIR/configure.js ]] || die "the settings window files are missing from $UI_DIR"
  payload=$(run_status_json | jq -c .)
  osascript -l JavaScript "$UI_DIR/configure.js" "$UI_DIR/configure.html" "$SCRIPT_PATH" "$payload"
}

run_reset_state() {
  acquire_lock 6 || die "another ergo run is in progress. Try again in a moment."
  write_json_atomic "$STATE_FILE" "$DEFAULT_STATE"
  print "ergo state reset: last nudge and recent cue history cleared. Logs were kept."
}

# save_config JSON — validate the whole config, then write atomically.
save_config() {
  local json=$1 errors
  errors=$(print -r -- "$json" | config_errors) || true
  if [[ -n $errors ]]; then
    fail_with_errors "that change would make config.json invalid, so nothing was saved:" "$errors"
  fi
  write_json_atomic "$CONFIG_FILE" "$json"
}

run_toggle() {
  local updated
  updated=$(jq '.enabled |= not' "$CONFIG_FILE")
  save_config "$updated"
  if [[ $(jq -r '.enabled' "$CONFIG_FILE") == true ]]; then
    print "ergo is active"
  else
    print "ergo is paused"
  fi
}

parse_int() {
  local digits
  digits=$(print -r -- "$1" | tr -d '[:space:]')
  digits=${digits%%[^0-9]*}
  [[ -n $digits ]] || die "expected a number, got: $1"
  print -r -- $(( 10#$digits ))
}

# "9", "09:00", "6 PM", "12 am" → 0–23
parse_hour() {
  local hour lower=${1:l}
  hour=$(parse_int "$1")
  if [[ $lower == *pm* ]] && (( hour < 12 )); then hour=$(( hour + 12 ))
  elif [[ $lower == *am* ]] && (( hour == 12 )); then hour=0
  fi
  print -r -- "$hour"
}

# "10-45", "10 to 45 sec", "10,45", or "30" (fixed) → {"min": 10, "max": 45}
parse_breaks() {
  local value=${1:l} token
  local -a secs=()
  for token in ${=${${value//to/ }//[-–,;\/]/ }}; do
    token=${token%sec}; token=${token%s}
    [[ -z $token ]] && continue
    [[ $token == <-> ]] || die "break length must be seconds, e.g. \"10-45\", got: $1"
    token=$(( 10#$token ))
    (( token >= 10 && token <= 240 && token % 5 == 0 )) || die "break lengths must be multiples of 5 from 10 to 240 seconds, got: $token"
    secs+=($token)
  done
  (( ${#secs} == 1 )) && secs+=(${secs[1]})
  (( ${#secs} == 2 )) || die "give a range like \"10-45\", or one value like \"30\" for a fixed length"
  (( secs[1] <= secs[2] )) || secs=(${secs[2]} ${secs[1]})
  print -r -- "{\"min\": ${secs[1]}, \"max\": ${secs[2]}}"
}

parse_style() {
  case ${${1:l}//[[:space:]]/} in
    fullscreen|full|fullscreenbreak|break|overlay) print '"fullscreen"' ;;
    notification|banner|notificationbanner|notify) print '"notification"' ;;
    *) die "expected Fullscreen or Notification, got: $1" ;;
  esac
}

parse_bool() {
  case ${${1:l}//[[:space:]]/} in
    on|true|yes|1|enabled|enable)    print true ;;
    off|false|no|0|disabled|disable) print false ;;
    *) die "expected On or Off, got: $1" ;;
  esac
}

# "Weekdays", "Every day", "Weekends", "Mon,Wed,Fri", "Monday Tuesday", "1,3,5" → JSON array
parse_days() {
  local value=${1:l} token
  local -a days=()
  case ${value//[[:space:]]/} in
    weekdays|weekday|mon-fri|mon–fri)  print '[1, 2, 3, 4, 5]'; return ;;
    everyday|daily|all|alldays)        print '[1, 2, 3, 4, 5, 6, 7]'; return ;;
    weekends|weekend)                  print '[6, 7]'; return ;;
  esac
  for token in ${=value//[,;\/]/ }; do
    case ${token[1,3]} in
      1|mon) days+=(1) ;;
      2|tue) days+=(2) ;;
      3|wed) days+=(3) ;;
      4|thu) days+=(4) ;;
      5|fri) days+=(5) ;;
      6|sat) days+=(6) ;;
      7|sun) days+=(7) ;;
      *) die "unknown day: $token (use Mon–Sun or 1–7)" ;;
    esac
  done
  (( ${#days} > 0 )) || die "choose at least one work day"
  jq -cn '$ARGS.positional | map(tonumber) | unique' --args "${days[@]}"
}

run_set() {
  local key=$1 raw=$2 field value updated
  case ${${key:l}//-/_} in
    interval|interval_minutes)            field=interval_minutes;   value=$(parse_int "$raw") ;;
    start|work_start|work_start_hour)     field=work_start_hour;    value=$(parse_hour "$raw") ;;
    end|work_end|work_end_hour)           field=work_end_hour;      value=$(parse_hour "$raw") ;;
    days|work_days)                       field=work_days;          value=$(parse_days "$raw") ;;
    sound)                                field=sound;              value=$(parse_bool "$raw") ;;
    quiet|quiet_mode)                     field=quiet_mode;         value=$(parse_bool "$raw") ;;
    style|nudge_style)                    field=nudge_style;        value=$(parse_style "$raw") ;;
    breaks|break|break_length)            field=break_range;        value=$(parse_breaks "$raw") ;;
    enabled)                              field=enabled;            value=$(parse_bool "$raw") ;;
    avoid_repeat|avoid_repeat_count)      field=avoid_repeat_count; value=$(parse_int "$raw") ;;
    *) die "unknown setting: $key (try: interval, start, end, days, sound, quiet, enabled, style, breaks, avoid-repeat)" ;;
  esac
  if [[ $field == break_range ]]; then
    updated=$(jq --argjson r "$value" '.break_min_seconds = $r.min | .break_max_seconds = $r.max | del(.break_durations)' "$CONFIG_FILE")
  else
    updated=$(jq --arg field "$field" --argjson value "$value" '.[$field] = $value' "$CONFIG_FILE")
  fi
  save_config "$updated"
  print "ergo updated"
  print
  print_config_summary
}

# run_apply_config JSON — merge several editable settings at once (settings window).
# Unknown keys are ignored; log_file/state_file and any extra keys are preserved.
run_apply_config() {
  local patch=$1 updated
  if ! print -r -- "$patch" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die "--apply-config expects a JSON object, e.g. '{\"interval_minutes\": 45}'"
  fi
  updated=$(jq --argjson patch "$patch" '. + ($patch | with_entries(select(.key | IN(
    "enabled", "interval_minutes", "work_start_hour", "work_end_hour",
    "work_days", "sound", "quiet_mode", "avoid_repeat_count", "nudge_style",
    "break_min_seconds", "break_max_seconds")))) | del(.break_durations) | .work_days |= (if type == "array" then unique else . end)' "$CONFIG_FILE")
  save_config "$updated"
  print "ergo updated"
  print
  print_config_summary
}

# ─── Install / uninstall ──────────────────────────────────────────────────────
# ERGO_SKIP_LAUNCHCTL=1 writes the plist without loading it (used for testing).

xml_escape() { local s=${1//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -r -- "$s"; }

run_install() {
  local target="$LAUNCH_AGENTS_DIR/$LAUNCHD_LABEL.plist" domain="gui/$(id -u)" content tmp
  [[ $(uname -s) == Darwin ]] || die "ergo runs on macOS only."
  [[ -f $PLIST_TEMPLATE ]] || die "LaunchAgent template not found: $PLIST_TEMPLATE"

  print "Installing ergo from $PROJECT_DIR"
  case $PROJECT_DIR in
    "$HOME"/Desktop|"$HOME"/Desktop/*|"$HOME"/Documents|"$HOME"/Documents/*|"$HOME"/Downloads|"$HOME"/Downloads/*|"$HOME/Library/Mobile Documents"/*)
      warn "this folder is inside Desktop, Documents, Downloads or iCloud Drive, where macOS can block background jobs. If breaks never appear on schedule, move the folder (for example to ~/ergo) and run --install again." ;;
  esac

  chmod +x "$SCRIPT_PATH"
  xattr -dr com.apple.quarantine "$PROJECT_DIR" 2>/dev/null || true
  print "  ✓ ergo.sh is executable"
  print "  ✓ Settings and cue library are valid ($(jq length "$NUDGES_FILE") cues)"

  # Fill the template with this folder's absolute path, XML-escaped, then verify it.
  content=$(<"$PLIST_TEMPLATE")
  [[ $content == *"$PLIST_PLACEHOLDER"* ]] \
    || die "the LaunchAgent template no longer contains the placeholder path $PLIST_PLACEHOLDER; restore com.yourname.ergo.plist"
  content=${content//"$PLIST_PLACEHOLDER"/$(xml_escape "$PROJECT_DIR")}
  mkdir -p "$LAUNCH_AGENTS_DIR"
  tmp=$(mktemp "$LAUNCH_AGENTS_DIR/.ergo.XXXXXX") || die "cannot write to $LAUNCH_AGENTS_DIR"
  TEMP_FILES+=("$tmp")
  print -r -- "$content" > "$tmp"
  plutil -lint -s "$tmp" >/dev/null 2>&1 || die "the generated LaunchAgent is not a valid property list"
  [[ $(plutil -extract ProgramArguments.1 raw -o - "$tmp") == "$PROJECT_DIR/ergo.sh" ]] \
    || die "the generated LaunchAgent does not point at $PROJECT_DIR/ergo.sh"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$target"
  print "  ✓ LaunchAgent written to $target"

  if [[ -z ${ERGO_SKIP_LAUNCHCTL:-} ]]; then
    launchctl bootout "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1 || true   # replace any older copy
    if ! launchctl bootstrap "$domain" "$target" >/dev/null 2>&1; then
      launchctl load "$target" >/dev/null 2>&1 || die "launchctl could not load $target. Try: launchctl load \"$target\""
    fi
    print "  ✓ Loaded: ergo now runs at login and checks every 5 minutes"
  fi

  cat <<EOF

ergo is installed.

Next steps
  ./ergo.sh --test         Show a break now
  ./ergo.sh --configure    Choose your hours, interval and break length
  ./ergo.sh --status       Confirm "LaunchAgent: Loaded"

If macOS shows "Background Items Added", that's expected (it may be listed as zsh).
EOF
}

run_uninstall() {
  local target="$LAUNCH_AGENTS_DIR/$LAUNCHD_LABEL.plist" domain="gui/$(id -u)"
  print "Uninstalling the ergo LaunchAgent"
  if [[ -z ${ERGO_SKIP_LAUNCHCTL:-} ]]; then
    launchctl bootout "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1 \
      || launchctl unload "$target" >/dev/null 2>&1 || true
    print "  ✓ Stopped"
  fi
  if [[ -f $target ]]; then
    rm -f -- "$target"
    print "  ✓ Removed $target"
  else
    print "  · No LaunchAgent found at $target"
  fi
  cat <<EOF

ergo will no longer run automatically. Your settings, cues and history are
untouched in $PROJECT_DIR. Delete any "ergo: …" Shortcuts in the Shortcuts app,
and remove the folder yourself if you no longer need it.
EOF
}

run_reset_config() {
  write_json_atomic "$CONFIG_FILE" "$DEFAULT_CONFIG"
  print "ergo reset to defaults"
  print
  print_config_summary
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode
  case ${1:-} in
    "")               mode=run ;;
    --test|-t)        mode=test ;;
    --status|-s)      mode=status ;;
    --today)          mode=today ;;
    --reset-state)    mode=reset_state ;;
    --toggle)         mode=toggle ;;
    --set)            mode=set ;;
    --reset-config)   mode=reset_config ;;
    --configure)      mode=configure ;;
    --status-json)    mode=status_json ;;
    --apply-config)   mode=apply_config ;;
    --install)        mode=install ;;
    --uninstall)      mode=uninstall ;;
    --help|-h)        usage; exit 0 ;;
    *) print -u2 -r -- "ergo: unknown option: $1"; usage >&2; exit 2 ;;
  esac

  if [[ $mode == set ]]; then
    if (( $# < 3 )); then usage >&2; exit 2; fi
  elif [[ $mode == apply_config ]]; then
    if (( $# != 2 )); then usage >&2; exit 2; fi
  elif (( $# > 1 )); then
    die "unexpected extra arguments after $1"
  fi

  # Uninstalling must work even if jq or the settings are broken.
  if [[ $mode == uninstall ]]; then run_uninstall; return; fi

  require_jq
  mkdir -p "$LOG_DIR" "$STATE_DIR"

  # Configuration commands only need config.json itself.
  case $mode in
    reset_config) run_reset_config; return ;;
    toggle)       ensure_config; require_config_syntax; run_toggle; return ;;
    set)          # Extra words (e.g. several days picked in a Shortcut) are joined with commas.
                  ensure_config; require_config_syntax; run_set "$2" "${(j:,:)@[3,-1]}"; return ;;
    apply_config) ensure_config; require_config_syntax; run_apply_config "$2"; return ;;
  esac

  ensure_config
  validate_config_file
  validate_nudges_file
  load_config
  prepare_files

  case $mode in
    run)          run_scheduled ;;
    test)         run_test ;;
    status)       run_status ;;
    today)        run_today ;;
    reset_state)  run_reset_state ;;
    status_json)  run_status_json ;;
    configure)    run_configure ;;
    install)      run_install ;;
  esac
}

main "$@"
