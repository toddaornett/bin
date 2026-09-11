#!/usr/bin/env bash
panel="3"
while true; do
  osascript -e 'tell application "Microsoft Teams" to activate'
  osascript -e "tell application \"System Events\" to keystroke \"$panel\" using {command down}"
  panel=$((panel + 1))
  if [[ "$panel" -gt "3" ]]; then
    panel="1"
  fi
  echo "Teams Status Refreshed"
  sleep 300
done
