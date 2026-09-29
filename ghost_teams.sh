#!/usr/bin/env bash

# Keep Microsoft Teams presence "Available" (green) while you are not touching
# the keyboard or mouse.
#
# Needs permission for the app running this script (your terminal) to send
# keystrokes: allow it to control System Events under System Settings > Privacy
# & Security > Automation, and grant it Accessibility under Privacy & Security.
# Permissions are verified at startup and on every refresh, and a missing one
# opens the System Settings pane that grants it instead of silently leaving you
# Away.
#
# Keeping the machine itself awake is separate: this script does not sleep-manage
# anything, so run `caffeinate` in addition if needed.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w MINUTES | -d MINUTES | -i SECONDS | -c COUNT]...

Post a synthetic activity event on a schedule so Microsoft Teams keeps your
presence Available (green) while you are away from the keyboard.

Arguments are processed as a list, left to right. Each one is a step, and any
of them may be given multiple times:

  -w, --wait MINUTES     Wait this many minutes without refreshing presence.
  -i, --interval SECONDS Set the seconds between refreshes for every later
                         -d/-c step. Must stay below Teams' roughly 5 minute
                         idle threshold. Initial value: 295.
  -d, --duration MINUTES Refresh presence at the current interval for this many
                         minutes, then move on to the next step. 0 means no
                         time limit (the script runs until interrupted, so any
                         later steps are never reached).
  -c, --count COUNT      Refresh presence this many times at the current
                         interval, then move on to the next step. 0 means run
                         until interrupted.
  -h, --help             Show this help

If no -d or -c step is given, the script refreshes until interrupted after
processing the other steps. The script exits after the last step.

Example:
  $(basename "$0") -w 10 -i 120 -d 30 -i 295 -d 240 -w 60 -d 60
    wait 10 min; refresh every 120s for 30 min; refresh every 295s for
    4 hours; idle for an hour; refresh every 295s for another hour.

Permissions are verified on startup and on every refresh. When the terminal is
not allowed to send keystrokes, the matching System Settings pane is opened
automatically. The startup check posts one activity event to prove access.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_nonneg_int() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer (got '$value')."
}

# The ordered plan built from the command line. Parallel arrays: step_types[n]
# is one of wait|interval|duration|count and step_values[n] is its argument.
step_types=()
step_values=()
has_run_step=0
unbounded_seen=0

warn_interval() {
  local seconds="$1"
  if [[ "$seconds" -ge 300 ]]; then
    echo "Warning: --interval ${seconds}s is at or above Teams' ~5 minute idle" >&2
    echo "         threshold, so presence will still drop to Away between refreshes." >&2
  fi
  if [[ "$seconds" -lt 5 ]]; then
    echo "Warning: --interval ${seconds}s is short enough that macOS drops the" >&2
    echo "         synthetic events; 5s or more is reliable." >&2
  fi
}

add_step() {
  local type="$1" value="$2" label="--$1"
  case "$type" in
  wait) label="--wait" ;;
  esac
  require_nonneg_int "$label" "$value"

  if [[ "$unbounded_seen" -eq 1 ]]; then
    echo "Warning: $label $value follows an unlimited -d/-c step and will never run." >&2
  fi

  case "$type" in
  interval)
    warn_interval "$value"
    ;;
  duration | count)
    has_run_step=1
    [[ "$value" -eq 0 ]] && unbounded_seen=1
    ;;
  esac

  step_types+=("$type")
  step_values+=("$value")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -w | --wait)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    add_step wait "$2"
    shift 2
    ;;
  --wait=*)
    add_step wait "${1#*=}"
    shift
    ;;
  -w*)
    add_step wait "${1#-w}"
    shift
    ;;
  -d | --duration)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    add_step duration "$2"
    shift 2
    ;;
  --duration=*)
    add_step duration "${1#*=}"
    shift
    ;;
  -d*)
    add_step duration "${1#-d}"
    shift
    ;;
  -i | --interval)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    add_step interval "$2"
    shift 2
    ;;
  --interval=*)
    add_step interval "${1#*=}"
    shift
    ;;
  -i*)
    add_step interval "${1#-i}"
    shift
    ;;
  -c | --count)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    add_step count "$2"
    shift 2
    ;;
  --count=*)
    add_step count "${1#*=}"
    shift
    ;;
  -c*)
    add_step count "${1#-c}"
    shift
    ;;
  *)
    die "unknown option: $1"$'\n'"Try '$(basename "$0") -h' for more information."
    ;;
  esac
done

# With no explicit run step (e.g. just -w 5, or no arguments at all), keep
# refreshing until interrupted once the other steps are done.
if [[ "$has_run_step" -eq 0 ]]; then
  step_types+=(duration)
  step_values+=(0)
fi

# Seconds since the last real (or synthetic) input event, straight from the
# kernel. Returns non-zero when the field is unreadable so callers can skip
# verification instead of mistaking "unknown" for "idle".
idle_seconds() {
  local ns
  ns=$(ioreg -rn IOHIDSystem | sed -n 's/.*"HIDIdleTime" = \([0-9][0-9]*\).*/\1/p')
  [[ -n "$ns" ]] || return 1
  echo $((ns / 1000000000))
}

# Bare modifier taps: left Shift, Control, Option. Each is a genuine input event
# (so it resets the idle clock) but commits nothing to the frontmost app -- no
# cursor movement, no text, no click. Rotating them keeps any single modifier
# from being tapped five times in a row, which would trip the Sticky Keys or
# Mouse Keys accessibility shortcuts.
activity_keys=(56 59 58)
activity_key_index=0

post_activity() {
  local key="${activity_keys[$activity_key_index]}"
  activity_key_index=$(((activity_key_index + 1) % ${#activity_keys[@]}))
  # osascript stays the last command so the function's status is its status:
  # callers must be able to tell a denied keystroke (non-zero) from a delivered
  # one, which a trailing assignment would mask.
  osascript -e "tell application \"System Events\" to key code ${key}"
}

# System Settings panes that grant the two permissions a synthetic keystroke
# needs. Both anchors were verified on macOS 26.6.2 by reading the pane back
# through the accessibility API: Privacy_Automation renders "Allow the
# applications below to control other applications", Privacy_Accessibility
# renders "Allow the applications below to control your computer". A wrong
# anchor does not error, it silently lands on the generic Privacy & Security
# list, so keep these exact strings.
AUTOMATION_PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
ACCESSIBILITY_PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# Apple event errors that mean "System Events is busy, restarting, or not
# reachable yet", not "you are not allowed to do this". Seen in practice: a
# refresh five seconds after the previous one returned -609 even though both
# permissions were granted. Worth another attempt rather than opening a
# permission pane for a problem the user does not have.
is_transient_error() {
  case "$1" in
  *"(-609)"* | *"(-600)"* | *"(-1712)"* | *"(-1708)"*) return 0 ;;
  *) return 1 ;;
  esac
}

# Send one activity event and classify what happened. Injecting is the only
# reliable probe of the two permissions involved, because it exercises the exact
# path Teams depends on: System Events must accept the Apple event (Automation),
# and the keystroke must reach the input system (Accessibility). Reports:
#   delivered     the event reached the idle clock
#   automation    System Events refused the Apple event
#   accessibility System Events reported assistive access denied
#   suppressed    accepted but never reached the clock (silent AX denial)
#   unknown       failed in a way that is not attributable to a permission
activity_status() {
  local attempt output idle_after

  for attempt in 1 2 3; do
    if output=$(post_activity 2>&1); then
      idle_after=$(idle_seconds || true)
      if [[ -n "$idle_after" ]] && [[ "$idle_after" -gt 3 ]]; then
        echo suppressed
      else
        echo delivered
      fi
      return
    fi

    [[ -n "$output" ]] && echo "$output" >&2

    if is_transient_error "$output" && [[ "$attempt" -lt 3 ]]; then
      sleep 2
      continue
    fi

    case "$output" in
    *"(-25211)"* | *"(-1719)"*) echo accessibility ;; # assistive access denied
    *"(-1743)"* | *"(-10004)"*) echo automation ;;    # errAEEventNotPermitted
    *) echo unknown ;;
    esac
    return
  done
}

# Never fatal: the caller's message still says which pane to click if this fails.
open_settings_pane() {
  open "$1" >/dev/null 2>&1 ||
    echo "Could not open System Settings automatically; open it by hand." >&2
}

# Stop, and put the pane that grants the missing permission on screen.
fail_permissions() {
  case "$1" in
  automation)
    open_settings_pane "$AUTOMATION_PANE"
    die "System Events refused the activity keystroke, so Teams never sees any
input. System Settings > Privacy & Security > Automation is opening now: enable
'System Events' underneath the app running this script (your terminal)."
    ;;
  accessibility | suppressed)
    open_settings_pane "$ACCESSIBILITY_PANE"
    die "The activity keystroke was accepted but never reached the system idle
clock, so Teams would keep seeing you as idle. System Settings > Privacy &
Security > Accessibility is opening now: enable the app running this script
(your terminal) there. If it is already enabled, the same symptom means macOS is
dropping synthetic events posted only seconds apart (raise --interval), or a
Secure Input prompt is swallowing keystrokes."
    ;;
  unknown)
    die "System Events failed in a way that is not attributable to a permission,
so this script cannot post activity and nothing was changed. The raw error is
above. Re-run; if it persists, relaunch System Events with
'killall \"System Events\"' (macOS restarts it on demand) or open
System Settings > Privacy & Security > Automation and Accessibility yourself.
Presence will sit at Away until this works."
    ;;
  esac
}

panel_urls=(msteams:/l/activity msteams:/l/chats msteams:/l/calendar)
panel_names=(activity chats calendar)
panel_index=0
panel_lead_seconds=2

switch_panel() {
  local name="${panel_names[$panel_index]}" url="${panel_urls[$panel_index]}"
  panel_index=$(((panel_index + 1) % ${#panel_urls[@]}))
  open "$url" >/dev/null 2>&1 || echo "Could not switch the Teams panel." >&2
  echo "Teams panel switched to ${name}"
}

refresh_presence() {
  local status

  switch_panel
  sleep "$panel_lead_seconds"

  status=$(activity_status)
  [[ "$status" == delivered ]] || fail_permissions "$status"

  echo "Teams presence refreshed at $(date '+%H:%M:%S')"
}

# Refresh presence repeatedly at $interval_seconds until either limit is hit.
# A limit of 0 means "no limit". When a duration ends, one final refresh lands
# right at the deadline so presence is fresh going into whatever step is next.
#   run_phase DURATION_MINUTES MAX_REFRESHES
run_phase() {
  local duration_minutes="$1" max_refreshes="$2"
  local count=0 deadline=0 remaining sleep_for final wait_seconds

  if [[ "$interval_seconds" -gt "$panel_lead_seconds" ]]; then
    wait_seconds=$((interval_seconds - panel_lead_seconds))
  else
    wait_seconds=0
  fi

  if [[ "$duration_minutes" -gt 0 ]]; then
    echo "Refreshing every ${interval_seconds}s for ${duration_minutes} minute(s)..."
    deadline=$((SECONDS + duration_minutes * 60))
  elif [[ "$max_refreshes" -gt 0 ]]; then
    echo "Refreshing every ${interval_seconds}s, ${max_refreshes} time(s)..."
  else
    echo "Refreshing every ${interval_seconds}s until interrupted..."
  fi

  while true; do
    refresh_presence

    count=$((count + 1))
    if [[ "$max_refreshes" -gt 0 ]] && [[ "$count" -ge "$max_refreshes" ]]; then
      return
    fi

    sleep_for="$wait_seconds"
    final=0
    if [[ "$duration_minutes" -gt 0 ]]; then
      remaining=$((deadline - SECONDS))
      [[ "$remaining" -gt 0 ]] || return
      if [[ "$remaining" -le "$sleep_for" ]]; then
        sleep_for="$remaining"
        final=1
      fi
    fi

    sleep "$sleep_for"

    if [[ "$final" -eq 1 ]]; then
      echo "Duration elapsed, refreshing presence one final time..."
      refresh_presence
      return
    fi
  done
}

# Fail fast on missing permission, ahead of any --wait. This posts one activity
# event of its own, which is unavoidable: sending is the only reliable probe.
# The first refresh landing right after it is harmless -- macOS may drop that
# second event for being too close, but the idle clock is already fresh, which
# is the only thing the refresh verification looks at.
permission_status=$(activity_status)
if [[ "$permission_status" != delivered ]]; then
  fail_permissions "$permission_status"
fi
echo "Permission check passed: synthetic keystrokes are allowed."

interval_seconds=295

for ((step = 0; step < ${#step_types[@]}; step++)); do
  value="${step_values[$step]}"
  case "${step_types[$step]}" in
  wait)
    if [[ "$value" -gt 0 ]]; then
      echo "Waiting ${value} minute(s)..."
      sleep $((value * 60))
    fi
    ;;
  interval)
    interval_seconds="$value"
    echo "Interval set to ${interval_seconds}s"
    ;;
  duration)
    run_phase "$value" 0
    ;;
  count)
    run_phase 0 "$value"
    ;;
  esac
done
