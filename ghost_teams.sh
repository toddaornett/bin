#!/usr/bin/env bash

# Cycle Microsoft Teams app-bar panels so presence stays active.
# New Teams (WebView2) ignores synthetic Cmd+1/2/3, so navigate with
# msteams: deep links instead of System Events keystrokes.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w MINUTES] [-d MINUTES] [-i SECONDS] [-c COUNT]

Cycle Microsoft Teams app-bar panels so presence stays active.

Options:
  -w, --wait MINUTES     Delay this many minutes before the first panel switch
                         (default: 0)
  -d, --duration MINUTES Duration in minutes before exiting regardless of COUNT.
                         0 or omitted means no time limit. (default: 0)
  -i, --interval SECONDS Seconds between emissions of switch app-bar panel messages.
                         (default: 295)
  -c, --count COUNT      Number of panel switches to perform. 0 or omitted
                         runs until interrupted.
  -h, --help             Show this help
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

# Shared, global state. switch_panel and main_loop both read/write
# these directly (no `local` shadowing) so that the duration signal
# handler below can call switch_panel and operate on the exact same
# panel sequence the main loop was using.
panel=1
count=0

switch_panel() {
  case "$panel" in
  1) open "msteams:/l/activity" ;;
  2) open "msteams:/l/chats" ;;
  3) open "msteams:/l/calendar" ;;
  *) open "msteams:/l/activity" ;;
  esac
  echo "Teams Status Refreshed: Switched to panel $panel"
  panel=$((panel % 3 + 1))
}

if [[ "$wait_minutes" -gt 0 ]]; then
  echo "Waiting ${wait_minutes} minute(s) before starting..."
  sleep $((wait_minutes * 60))
fi

# The main cycling loop runs as its own background process. It sets
# its own trap for the duration signal (rather than relying on a trap
# in the parent) so that the handler runs in the same process that
# owns $panel/$count, can call switch_panel one last time, and can
# exit immediately rather than waiting for a `kill` to land.
#
# Using `sleep & ; wait $!` instead of a bare `sleep N` matters here:
# a trapped signal only interrupts the `wait` builtin promptly. A
# trap on a genuinely blocking foreground `sleep N` is deferred until
# that sleep finishes, which would let the timeout overshoot by up to
# one full --interval.
main_loop() {
  trap '
    echo
    echo "ghost-teams: duration elapsed, switching one final time..."
    switch_panel
    exit 100
  ' USR1

  while [[ "$iterations" -eq 0 ]] || [[ "$count" -lt "$iterations" ]]; do
    switch_panel

    count=$((count + 1))
    if [[ "$iterations" -ne 0 ]] && [[ "$count" -eq "$iterations" ]]; then
      break
    fi

    sleep "$interval_seconds" &
    wait $!
  done
}

main_loop &
LOOP_PID=$!

TIMER_PID=""
if [[ "$duration_minutes" -gt 0 ]]; then
  echo "Will run for ${duration_minutes} minute(s) before terminating..."
  (
    sleep $((duration_minutes * 60))
    kill -s USR1 "$LOOP_PID" 2>/dev/null
  ) &
  TIMER_PID=$!
fi

cleanup() {
  if [[ -n "$TIMER_PID" ]]; then
    kill "$TIMER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Wait for the loop to finish, either by exhausting --count or via
# the duration signal handler's `exit 100`.
set +e
wait "$LOOP_PID"
loop_status=$?
set -e

if [[ "$loop_status" -eq 100 ]]; then
  echo "ghost-teams exiting after ${duration_minutes} minute(s)."
  exit 0
fi

exit "$loop_status"
