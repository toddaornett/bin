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
Usage: $(basename "$0") [-w MINUTES] [-d MINUTES] [-i SECONDS] [-c COUNT]

Post a synthetic activity event on a schedule so Microsoft Teams keeps your
presence Available (green) while you are away from the keyboard.

Options:
  -w, --wait MINUTES     Delay this many minutes before the first refresh
                         (default: 0)
  -d, --duration MINUTES Duration in minutes before exiting regardless of COUNT.
                         0 or omitted means no time limit. (default: 0)
  -i, --interval SECONDS Seconds between presence refreshes. Must stay below
                         Teams' roughly 5 minute idle threshold.
                         (default: 295)
  -c, --count COUNT      Number of presence refreshes to perform. 0 or omitted
                         runs until interrupted.
  -h, --help             Show this help

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

wait_minutes=0
duration_minutes=0
interval_seconds=295
iterations=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -w | --wait)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    wait_minutes="$2"
    shift 2
    ;;
  --wait=*)
    wait_minutes="${1#*=}"
    shift
    ;;
  -w*)
    wait_minutes="${1#-w}"
    shift
    ;;
  -d | --duration)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    duration_minutes="$2"
    shift 2
    ;;
  --duration=*)
    duration_minutes="${1#*=}"
    shift
    ;;
  -d*)
    duration_minutes="${1#-d}"
    shift
    ;;
  -i | --interval)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    interval_seconds="$2"
    shift 2
    ;;
  --interval=*)
    interval_seconds="${1#*=}"
    shift
    ;;
  -i*)
    interval_seconds="${1#-i}"
    shift
    ;;
  -c | --count)
    [[ $# -ge 2 ]] || die "$1 requires a value."
    iterations="$2"
    shift 2
    ;;
  --count=*)
    iterations="${1#*=}"
    shift
    ;;
  -c*)
    iterations="${1#-c}"
    shift
    ;;
  *)
    die "unknown option: $1"$'\n'"Try '$(basename "$0") -h' for more information."
    ;;
  esac
done

require_nonneg_int "--wait" "$wait_minutes"
require_nonneg_int "--duration" "$duration_minutes"
require_nonneg_int "--interval" "$interval_seconds"
require_nonneg_int "--count" "$iterations"

if [[ "$interval_seconds" -ge 300 ]]; then
  echo "Warning: --interval ${interval_seconds}s is at or above Teams' ~5 minute idle" >&2
  echo "         threshold, so presence will still drop to Away between refreshes." >&2
fi

if [[ "$interval_seconds" -lt 5 ]]; then
  echo "Warning: --interval ${interval_seconds}s is short enough that macOS drops the" >&2
  echo "         synthetic events; 5s or more is reliable." >&2
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

count=0

# Fail fast on missing permission, ahead of any --wait. This posts one activity
# event of its own, which is unavoidable: sending is the only reliable probe.
# The loop's first refresh landing right after it is harmless -- macOS may drop
# that second event for being too close, but the idle clock is already fresh,
# which is the only thing the refresh verification looks at.
permission_status=$(activity_status)
if [[ "$permission_status" != delivered ]]; then
  fail_permissions "$permission_status"
fi
echo "Permission check passed: synthetic keystrokes are allowed."

if [[ "$wait_minutes" -gt 0 ]]; then
  echo "Waiting ${wait_minutes} minute(s) before starting..."
  sleep $((wait_minutes * 60))
fi

# SIGUSR1 comes from the --duration timer below. The trap lives in the process
# that owns $count, and the loop waits with `sleep & ; wait $!` instead of a
# bare foreground `sleep N`: bash only interrupts an unfinished `wait` when a
# trapped signal lands, so a foreground sleep would defer the handler until the
# sleep completed and overshoot --duration by up to one full --interval.
on_duration_elapsed() {
  echo
  echo "ghost-teams: duration elapsed, refreshing presence one final time..."
  refresh_presence
  exit 0
}
trap on_duration_elapsed USR1

timer_pid=""
sleep_pid=""

# Reap the --duration timer and any in-flight interval sleep so nothing
# outlives the script, including on the SIGUSR1 path where the handler exits
# while a `sleep &` child is still running.
cleanup() {
  local pid
  for pid in "$timer_pid" "$sleep_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

if [[ "$duration_minutes" -gt 0 ]]; then
  echo "Will run for ${duration_minutes} minute(s) before terminating..."
  (
    sleep $((duration_minutes * 60))
    kill -s USR1 "$$"
  ) &
  timer_pid=$!
fi

if [[ "$interval_seconds" -gt "$panel_lead_seconds" ]]; then
  wait_seconds=$((interval_seconds - panel_lead_seconds))
else
  wait_seconds=0
fi

while [[ "$iterations" -eq 0 ]] || [[ "$count" -lt "$iterations" ]]; do
  refresh_presence

  count=$((count + 1))
  if [[ "$iterations" -ne 0 ]] && [[ "$count" -ge "$iterations" ]]; then
    break
  fi

  sleep "$wait_seconds" &
  sleep_pid=$!
  wait "$sleep_pid"
  sleep_pid=""
done
