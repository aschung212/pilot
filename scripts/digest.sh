#!/bin/bash
# Linear Daily Digest — posts a morning summary of all projects to Slack
# Zero tokens, zero LLM calls. Pure CLI + webhook.
#
# Usage:
#   ./linear-digest.sh              # post to Slack
#   ./linear-digest.sh --dry-run    # print to stdout only

set -euo pipefail

# Source env vars when run by launchd (no login shell)
[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

SLACK_WEBHOOK_DAILY_REVIEW="${SLACK_WEBHOOK_DAILY_REVIEW:-}"
DRY_RUN="${1:-}"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"

# Fetch issues by state(s)
fetch_issues() {
  local project="$1" states="$2"
  # shellcheck disable=SC2086
  bash "$TRACKER" list $states
}

# Count issues matching a pattern
count_lines() {
  echo "$1" | grep -c "${LINEAR_TEAM}-" 2>/dev/null || echo "0"
}

# --- Lift ---
LIFT_ACTIVE=$(fetch_issues "Lift" "started")
LIFT_BACKLOG=$(fetch_issues "Lift" "backlog unstarted")
LIFT_ALL=$(fetch_issues "Lift" "triage backlog unstarted started")

LIFT_ACTIVE_COUNT=$(count_lines "$LIFT_ACTIVE")
LIFT_BACKLOG_COUNT=$(count_lines "$LIFT_BACKLOG")

# --- Technical Prep ---
PREP_ACTIVE=$(fetch_issues "Technical Prep" "started")
PREP_BACKLOG=$(fetch_issues "Technical Prep" "backlog unstarted")
PREP_ACTIVE_COUNT=$(count_lines "$PREP_ACTIVE")
PREP_BACKLOG_COUNT=$(count_lines "$PREP_BACKLOG")

# --- Active Applications ---
APPS_ACTIVE=$(fetch_issues "Active Applications" "started backlog unstarted")
APPS_ACTIVE_COUNT=$(count_lines "$APPS_ACTIVE")

# --- AI Competency ---
AI_ACTIVE=$(fetch_issues "AI Competency" "started backlog unstarted")
AI_ACTIVE_COUNT=$(count_lines "$AI_ACTIVE")

# Format top items per project (just titles, max 5)
format_top() {
  local issues="$1" max="${2:-5}"
  echo "$issues" | grep 'MAS-' | head -"$max" | sed 's/^/  /' || echo "  (none)"
}

LIFT_TOP=$(format_top "$LIFT_ALL" 5)
PREP_TOP=$(format_top "$PREP_ACTIVE$PREP_BACKLOG" 3)
APPS_TOP=$(format_top "$APPS_ACTIVE" 3)

# Build message
MSG="*Linear Digest — ${DAY_NAME}, ${DATE}*

*Lift* — ${LIFT_ACTIVE_COUNT} in progress, ${LIFT_BACKLOG_COUNT} backlog
${LIFT_TOP}

*Technical Prep* — ${PREP_ACTIVE_COUNT} in progress, ${PREP_BACKLOG_COUNT} backlog
${PREP_TOP}

*Applications* — ${APPS_ACTIVE_COUNT} open
${APPS_TOP}

*AI Competency* — ${AI_ACTIVE_COUNT} open

<https://linear.app/${LINEAR_ORG:-masterchung}|Open Linear>"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "$MSG"
  exit 0
fi

if [ -n "$SLACK_WEBHOOK_DAILY_REVIEW" ]; then
  payload=$(printf '{"text": %s}' "$(echo "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  curl -s -X POST "$SLACK_WEBHOOK_DAILY_REVIEW" -H 'Content-Type: application/json' -d "$payload"
  echo "Posted Linear digest to #daily-review"
else
  echo "SLACK_WEBHOOK_DAILY_REVIEW not set — printing to stdout:"
  echo "$MSG"
fi
