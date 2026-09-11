#!/usr/bin/env bash

# Cycle Microsoft Teams app-bar panels so presence stays active.
# New Teams (WebView2) ignores synthetic Cmd+1/2/3, so navigate with
# msteams: deep links instead of System Events keystrokes.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-w MINUTES] [-n COUNT]

Cycle Microsoft Teams app-bar panels so presence stays active.

Options:
  -w, --wait MINUTES   Delay this many minutes before the first panel switch
                       (default: 0)
  -c, --count COUNT    Number of panel switches to perform. 0 or omitted
                       runs until interrupted.
  -h, --help           Show this help
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
require_nonneg_int "--count" "$iterations"

panel=1
count=0

switch_panel() {
  case "$1" in
  1) open "msteams:/l/activity" ;;
  2) open "msteams:/l/chats" ;;
  3) open "msteams:/l/calendar" ;;
  *) open "msteams:/l/activity" ;;
  esac
}

if [[ "$wait_minutes" -gt 0 ]]; then
  echo "Waiting ${wait_minutes} minute(s) before starting..."
  sleep $((wait_minutes * 60))
fi

while [[ "$iterations" -eq 0 ]] || [[ "$count" -lt "$iterations" ]]; do
  switch_panel "$panel"
  echo "Teams Status Refreshed: Switched to panel $panel"

  panel=$((panel + 1))
  if [[ "$panel" -gt 3 ]]; then
    panel=1
  fi

  count=$((count + 1))
  if [[ "$iterations" -ne 0 ]] && [[ "$count" -eq "$iterations" ]]; then
    break
  fi

  sleep 300
done
