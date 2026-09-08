#! /usr/bin/env bash

################################################################################
# This CLI tool simply outputs a small string indicating the status of your
# unread Slack notifications. It is meant to be paired with XBar to display its
# output in the MacOS MenuBar.
#
# Example output:
#   `# 0 ` => No messages at all (except perhaps in muted rooms)
#   `# 0*` => No DMs or mentions, at least one general unreads
#   `# 3 ` => 3 DMs or mentions, no general unreads
#   `# 3*` => 3 DMs or mentions, at least one general unreads
#
# Installation:
#
# 1. Ensure you have the `jq` utility installed. You can run `brew install jq`.
# 2. Ensure this script is executable: `chmod +x slack_count.1s.bash`
# 3. Install XBar and put this in its configured script directory: https://github.com/matryer/xbar
################################################################################

set -e
file="$HOME/Library/Application Support/Slack/storage/root-state.json"
teamid=$(/opt/homebrew/bin/jq ".webapp.teams | keys[0]" "$file")
direct=$(/opt/homebrew/bin/jq ".webapp.teams.$teamid.unreads.unreadHighlights" "$file")
unreads=$(/opt/homebrew/bin/jq ".webapp.teams.$teamid.unreads.unreads" "$file")
indirect=" "
if [[ $unreads != "0" ]]; then
    indirect="*"
fi

echo "# $direct$indirect"
