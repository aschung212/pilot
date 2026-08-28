#!/bin/bash
# Daily Digest — posts a morning summary of all projects to Slack
# Zero tokens, zero LLM calls. Pure CLI + webhook.
#
# Usage:
#   ./linear-digest.sh              # post to Slack
#   ./linear-digest.sh --dry-run    # print to stdout only

# Not `-e`: this script is full of pipelines that "fail" by design — `grep` with
# no match (empty boards) and `head -N` closing a pipe early (SIGPIPE, exit 141)
# would otherwise abort the run mid-digest. See CLAUDE.md "grep -c with pipes".
set -uo pipefail

# Source env vars when run by launchd (no login shell)
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

SLACK_WEBHOOK_DAILY_REVIEW="${SLACK_WEBHOOK_DAILY_REVIEW:-}"
DRY_RUN="${1:-}"
DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"

# Fetch issues by project and state(s)
fetch_issues() {
  local project="$1" states="$2"
  # shellcheck disable=SC2086
  bash "$TRACKER" list --project "$project" $states
}

# Count issues matching a pattern.
# `grep -c` prints "0\n" AND exits 1 when no matches, so a naked `|| echo 0`
# would APPEND a second "0\n" and break any caller that uses the value as a
# single number. head -1 keeps just the first count line.
count_lift_lines() {
  { echo "$1" | grep -c "${ISSUE_PREFIX}-" 2>/dev/null || echo "0"; } | head -1
}
count_tracker_lines() {
  { echo "$1" | grep -c "${LINEAR_TEAM}-" 2>/dev/null || echo "0"; } | head -1
}

# --- Lift ---
LIFT_ACTIVE=$(fetch_issues "Lift" "started")
LIFT_BACKLOG=$(fetch_issues "Lift" "backlog unstarted")
LIFT_ALL=$(fetch_issues "Lift" "triage backlog unstarted started")

LIFT_ACTIVE_COUNT=$(count_lift_lines "$LIFT_ACTIVE")
LIFT_BACKLOG_COUNT=$(count_lift_lines "$LIFT_BACKLOG")

# --- Blockers waiting on a human ---
# state:needs-input = triage FLAGged the issue and parked it until Aaron
# answers. These rot silently unless surfaced daily — by 2026-05-12 eight
# issues had been sitting in this state with nothing pointing at them. The
# digest is the standup, and blockers belong in the standup.
# (Formatting happens further down, after format_top is defined.)
LIFT_BLOCKED=$(fetch_issues "Lift" "needs-input")
LIFT_BLOCKED_COUNT=$(count_lift_lines "$LIFT_BLOCKED")

# Rejected-PR issues cleanup refuses to auto-recycle (their PR was closed
# unmerged — could be a deliberate rejection, so a human must decide: recycle
# to state:unstarted or close as not planned). cleanup.sh snapshots the
# current set to this file every night.
NEEDS_DECISION_FILE="${OUTPUT_DIR:-${PILOT_DIR:-}/data}/lift-needs-decision.txt"
NEEDS_DECISION_IDS=$(grep -oE "${ISSUE_PREFIX}-[0-9]+" "$NEEDS_DECISION_FILE" 2>/dev/null | head -10 | tr '\n' ' ' || true)
NEEDS_DECISION_COUNT=$({ echo "$NEEDS_DECISION_IDS" | tr ' ' '\n' | grep -c "${ISSUE_PREFIX}-" 2>/dev/null || echo "0"; } | head -1)

# --- Technical Prep ---
PREP_ACTIVE=$(fetch_issues "Technical Prep" "started")
PREP_BACKLOG=$(fetch_issues "Technical Prep" "backlog unstarted")
PREP_ACTIVE_COUNT=$(count_tracker_lines "$PREP_ACTIVE")
PREP_BACKLOG_COUNT=$(count_tracker_lines "$PREP_BACKLOG")

# --- Active Applications ---
APPS_ACTIVE=$(fetch_issues "Active Applications" "started backlog unstarted")
APPS_ACTIVE_COUNT=$(count_tracker_lines "$APPS_ACTIVE")

# --- AI Competency ---
AI_ACTIVE=$(fetch_issues "AI Competency" "started backlog unstarted")
AI_ACTIVE_COUNT=$(count_tracker_lines "$AI_ACTIVE")

# Format top items per project with clickable links
format_top() {
  local issues="$1" max="${2:-5}" project="${3:-lift}"
  local ids prefix_pattern
  if [ "$project" = "lift" ]; then
    prefix_pattern="${ISSUE_PREFIX}-[0-9]+"
  else
    prefix_pattern="${LINEAR_TEAM}-[0-9]+"
  fi
  ids=$(echo "$issues" | grep -oE "$prefix_pattern" | head -"$max")
  if [ -z "$ids" ]; then
    echo "  (none)"
    return
  fi
  echo "$ids" | while read -r ISSUE_ID; do
    TITLE=$(bash "$TRACKER" view "$ISSUE_ID" 2>/dev/null | head -1 | sed "s/^# *${ISSUE_ID}: *//" | sed 's/[[:space:]]*$//')
    [ -z "$TITLE" ] && TITLE="(untitled)"
    local URL
    URL=$(bash "$TRACKER" issue-url "$ISSUE_ID" 2>/dev/null)
    echo "  • <${URL}|${ISSUE_ID}>: ${TITLE}"
  done
}

LIFT_ACTIVE_TOP=$(format_top "$LIFT_ACTIVE" 3 lift)
LIFT_BACKLOG_TOP=$(format_top "$LIFT_BACKLOG" 5 lift)
LIFT_BLOCKED_TOP=$(format_top "$LIFT_BLOCKED" 5 lift)
PREP_TOP=$(format_top "$PREP_ACTIVE$PREP_BACKLOG" 3 linear)
APPS_TOP=$(format_top "$APPS_ACTIVE" 3 linear)

# Blockers section — rendered only when something is actually waiting.
WAITING_BLOCK=""
if [ "${LIFT_BLOCKED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  WAITING_BLOCK+="
⏳ *Waiting on you* — ${LIFT_BLOCKED_COUNT} issue(s) parked on \`state:needs-input\` (answer, then flip to \`state:unstarted\`):
${LIFT_BLOCKED_TOP}
"
fi
if [ "${NEEDS_DECISION_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  WAITING_BLOCK+="
⚖️ *Needs your call* — ${NEEDS_DECISION_COUNT} issue(s) whose PR was closed unmerged (recycle or close): ${NEEDS_DECISION_IDS}
"
fi

# Build message
MSG="*📋 Issue Digest — ${DAY_NAME}, ${DATE}*

*Lift* — ${LIFT_ACTIVE_COUNT} in progress, ${LIFT_BACKLOG_COUNT} backlog
${LIFT_ACTIVE_TOP:+_In Progress:_
${LIFT_ACTIVE_TOP}
}${LIFT_BACKLOG_TOP:+_Backlog:_
${LIFT_BACKLOG_TOP}}
${WAITING_BLOCK}
*Technical Prep* — ${PREP_ACTIVE_COUNT} in progress, ${PREP_BACKLOG_COUNT} backlog
${PREP_TOP}

*Applications* — ${APPS_ACTIVE_COUNT} open
${APPS_TOP}

*AI Competency* — ${AI_ACTIVE_COUNT} open

<$(bash "$TRACKER" board-url)|Lift Issues> | <https://linear.app/${LINEAR_ORG:-masterchung}|Linear Board>"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "$MSG"
  exit 0
fi

if [ -n "$SLACK_WEBHOOK_DAILY_REVIEW" ]; then
  payload=$(printf '{"text": %s}' "$(echo "$MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  curl -s -X POST "$SLACK_WEBHOOK_DAILY_REVIEW" -H 'Content-Type: application/json' -d "$payload"
  echo "Posted issue digest to #daily-review"
else
  echo "SLACK_WEBHOOK_DAILY_REVIEW not set — printing to stdout:"
  echo "$MSG"
fi
