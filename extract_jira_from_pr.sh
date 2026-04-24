#!/usr/bin/env bash
set -euo pipefai}

# ─────────────────────────────────────────────
# extract_jira_from_pr.sh
# Usage: ./extract_jira_from_pr.sh <github_url>
#
# Extracts JIRA ${JIRA_ISSUE_KEY_PREFIX}-<n> tickets from a GitHub
# PR title, body, branch name, and commits.
# ─────────────────────────────────────────────

JIRA_BASE="${JIRA_ISSUE_BASE_URL:-"https://atlassian.net"}/browse"
JIRA_PREFIX="${JIRA_ISSUE_KEY_PREFIX:-"JIRA"}"

# ── Resolve GH URL from arg or clipboard ──────
GH_URL="${1:-}"

if [[ -z "$GH_URL" ]]; then
  if command -v pbpaste >/dev/null 2>&1; then
    CLIP=$(pbpaste)
  elif command -v xclip >/dev/null 2>&1; then
    CLIP=$(xclip -selection clipboard -o)
  elif command -v xsel >/dev/null 2>&1; then
    CLIP=$(xsel --clipboard --output)
  else
    CLIP=""
  fi

  if echo "$CLIP" | grep -qE '^https://github\.com/[^/]+/[^/]+/(pull|commit|tree|blob)/[^ ]+$'; then
    GH_URL="$CLIP"
    echo "Using URL from clipboard: $GH_URL"
  else
    echo "Usage: $0 <github_url>" >&2
    echo "       (or copy a GitHub URL to your clipboard)" >&2
    exit 1
  fi
fi

# ── Require gh CLI ─────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed." >&2
  echo "Install it from https://cli.github.com" >&2
  exit 1
fi

# ── Parse owner/repo/number from URL ──────────
parse_gh_url() {
  local url="$1"
  OWNER=$(echo "$url" | sed -E 's|https://github\.com/([^/]+)/.*|\1|')
  REPO=$(echo "$url"  | sed -E 's|https://github\.com/[^/]+/([^/]+).*|\1|')
  TYPE=$(echo "$url"  | sed -E 's|https://github\.com/[^/]+/[^/]+/([^/]+).*|\1|')
  NUMBER=$(echo "$url"| sed -E 's|.*/([0-9a-f]+)$|\1|')
}

# ── Extract ${JIRA_PREFIX}-<n> tickets (case-insensitive) ─
extract_tickets() {
  local text="$1"
  echo "$text" | grep -oiE "\b${JIRA_PREFIX}[ -]+[0-9]+\b" | tr '[:lower:]' '[:upper:]' | sed "s/${JIRA_PREFIX^^}[^0-9]*/${JIRA_PREFIX^^}-/" | sort -u
}

parse_gh_url "$GH_URL"

RAW_TEXT=""

if [[ "$TYPE" == "pull" ]]; then
  echo "Fetching PR #$NUMBER from $OWNER/$REPO …"
  PR_JSON=$(gh pr view "$NUMBER" \
    --repo "$OWNER/$REPO" \
    --json title,body,headRefName,commits)

  TITLE=$(echo "$PR_JSON"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))")
  BODY=$(echo "$PR_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('body',''))")
  BRANCH=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('headRefName',''))")
  COMMITS=$(echo "$PR_JSON"| python3 -c "
import sys, json
d = json.load(sys.stdin)
msgs = [c.get('messageHeadline','') + ' ' + c.get('messageBody','')
        for c in d.get('commits', [])]
print('\n'.join(msgs))
")
  RAW_TEXT="$TITLE $BODY $BRANCH $COMMITS"

elif [[ "$TYPE" == "commit" ]]; then
  echo "Fetching commit $NUMBER from $OWNER/$REPO …"
  COMMIT_JSON=$(gh api "repos/$OWNER/$REPO/commits/$NUMBER")
  COMMIT_MSG=$(echo "$COMMIT_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('commit', {}).get('message', ''))
")
  RAW_TEXT="$COMMIT_MSG"

elif [[ "$TYPE" == "tree" || "$TYPE" == "blob" ]]; then
  BRANCH=$(echo "$GH_URL" | sed -E "s|.*/($TYPE)/(.+)|\2|")
  echo "Using branch name: $BRANCH"
  RAW_TEXT="$BRANCH"

else
  echo "Unsupported URL type: $TYPE" >&2
  echo "Supported: pull, commit, tree" >&2
  exit 1
fi

# ── Find tickets ───────────────────────────────
TICKETS=$(extract_tickets "$RAW_TEXT")

if [[ -z "$TICKETS" ]]; then
  echo ""
  echo "No ${JIRA_PREFIX}-<n> JIRA tickets found."
  exit 0
fi

echo ""
echo "Found JIRA ticket(s):"
echo "─────────────────────────────────────────────"
while IFS= read -r ticket; do
  echo "  $ticket  →  $JIRA_BASE/$ticket"
done <<< "$TICKETS"
echo "─────────────────────────────────────────────"
