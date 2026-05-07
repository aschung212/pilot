#!/bin/bash
# Adapter: Issue Tracker (dual-backend — GitHub Issues for Lift, Linear for others)
# Provides a unified interface for issue management.
# Routes based on project: Lift → gh CLI, everything else → linear CLI.
#
# Usage:
#   tracker.sh list [--project <name>] <states>
#   tracker.sh view <id>                  # LIFT-N for GitHub, MAS-N for Linear
#   tracker.sh create <title> <priority> [--state <state>] [--description <desc>] [--label <label>]
#   tracker.sh update <id> --state <state> [--priority <n>]
#   tracker.sh comment-list <id>
#   tracker.sh comment-add <id> <body>
#   tracker.sh issue-url <id>
#   tracker.sh board-url
#   tracker.sh close <id> [--reason <completed|not_planned>]

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

source "$SCRIPT_DIR/../lib/log.sh" 2>/dev/null || true
LOG_COMPONENT="adapter:tracker"

STRIP_ANSI='sed s/\x1b\[[0-9;]*m//g'

# Config
GITHUB_ISSUES_REPO="${GITHUB_ISSUES_REPO:-${GITHUB_REPO:-aschung212/Lift}}"
ISSUE_PREFIX="${ISSUE_PREFIX:-LIFT}"
LIFT_PROJECT="${LIFT_PROJECT:-Lift}"

# ── Routing ──────────────────────────────────────────────────────────────

# Determine backend from project name
route_by_project() {
  case "$1" in
    Lift|lift|"$LIFT_PROJECT") echo "github" ;;
    *) echo "linear" ;;
  esac
}

# Determine backend from issue ID
route_by_id() {
  case "$1" in
    ${ISSUE_PREFIX}-*|LIFT-*) echo "github" ;;
    *) echo "linear" ;;
  esac
}

# Extract GitHub issue number from LIFT-N format
gh_number() {
  echo "$1" | sed "s/^${ISSUE_PREFIX}-//" | sed 's/^LIFT-//'
}

# ── GitHub Backend ───────────────────────────────────────────────────────

gh_list() {
  # Args: state1 [state2 ...]
  # gh issue list ANDs labels, so we query per state and combine
  for state in "$@"; do
    case "$state" in
      completed)
        gh issue list --repo "$GITHUB_ISSUES_REPO" --limit 100 --state closed \
          --json number,title,labels \
          --jq '[.[] | select(.labels | map(.name) | index("state:canceled") | not)] | .[] | "'"${ISSUE_PREFIX}"'-\(.number) \(.title)"' 2>/dev/null || true
        ;;
      canceled)
        gh issue list --repo "$GITHUB_ISSUES_REPO" --limit 100 --state closed --label "state:canceled" \
          --json number,title,labels \
          --jq '.[] | "'"${ISSUE_PREFIX}"'-\(.number) \(.title)"' 2>/dev/null || true
        ;;
      *)
        gh issue list --repo "$GITHUB_ISSUES_REPO" --limit 100 --label "state:$state" \
          --json number,title,labels \
          --jq '.[] | "'"${ISSUE_PREFIX}"'-\(.number) \(.title)"' 2>/dev/null || true
        ;;
    esac
  done
}

gh_view() {
  local num
  num=$(gh_number "$1")
  local detail
  detail=$(gh issue view "$num" --repo "$GITHUB_ISSUES_REPO" 2>/dev/null) || return 1
  # Format to match expected output: "# LIFT-N: Title" on first line
  local title
  title=$(echo "$detail" | head -1 | sed 's/^title:[[:space:]]*//')
  echo "# ${ISSUE_PREFIX}-${num}: $title"
  echo "$detail" | tail -n +2
}

gh_create() {
  local title="$1"; shift
  local priority="$1"; shift
  local state="unstarted"
  local description=""
  local extra_labels=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --label) extra_labels="$extra_labels,$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Build label string
  local prio_label
  case "$priority" in
    1) prio_label="priority:1-urgent" ;;
    2) prio_label="priority:2-high" ;;
    3) prio_label="priority:3-medium" ;;
    4) prio_label="priority:4-low" ;;
    *) prio_label="priority:3-medium" ;;
  esac

  local state_label=""
  case "$state" in
    completed|Done|done) state_label="" ;;
    canceled)  state_label="state:canceled" ;;
    *)         state_label="state:${state}" ;;
  esac

  local labels="${prio_label}"
  [ -n "$state_label" ] && labels="${labels},${state_label}"
  [ -n "$extra_labels" ] && labels="${labels}${extra_labels}"
  labels=$(echo "$labels" | sed 's/^,//;s/,$//')

  local body="${description:-No description}"
  local create_args=(--repo "$GITHUB_ISSUES_REPO" --title "$title" --label "$labels" --body "$body")

  local output
  output=$(gh issue create "${create_args[@]}" 2>&1)

  # Extract issue number from returned URL
  local num
  num=$(echo "$output" | grep -oE '[0-9]+$' | tail -1)

  if [ -n "$num" ]; then
    echo "${ISSUE_PREFIX}-${num} https://github.com/${GITHUB_ISSUES_REPO}/issues/${num}"

    # Close if completed/canceled
    case "$state" in
      completed|Done|done) gh issue close "$num" --repo "$GITHUB_ISSUES_REPO" --reason completed >/dev/null 2>&1 ;;
      canceled) gh issue close "$num" --repo "$GITHUB_ISSUES_REPO" --reason "not planned" >/dev/null 2>&1 ;;
    esac
  else
    echo "$output"
  fi
}

gh_update() {
  local id="$1"; shift
  local num
  num=$(gh_number "$id")
  local new_state="" new_priority=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --state) new_state="$2"; shift 2 ;;
      --priority) new_priority="$2"; shift 2 ;;
      --team) shift 2 ;;  # ignore Linear-specific args
      *) shift ;;
    esac
  done

  # Update state via labels
  if [ -n "$new_state" ]; then
    # Remove all existing state labels
    local current_labels
    current_labels=$(gh issue view "$num" --repo "$GITHUB_ISSUES_REPO" --json labels -q '.labels[].name' 2>/dev/null | grep '^state:' || true)
    for old_label in $current_labels; do
      gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --remove-label "$old_label" >/dev/null 2>&1 || true
    done

    case "$new_state" in
      completed|Done|done|"In Progress")
        [ "$new_state" = "In Progress" ] && gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --add-label "state:started" >/dev/null 2>&1
        [ "$new_state" = "completed" ] || [ "$new_state" = "Done" ] || [ "$new_state" = "done" ] && gh issue close "$num" --repo "$GITHUB_ISSUES_REPO" --reason completed >/dev/null 2>&1
        ;;
      canceled)
        gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --add-label "state:canceled" >/dev/null 2>&1
        gh issue close "$num" --repo "$GITHUB_ISSUES_REPO" --reason "not planned" >/dev/null 2>&1
        ;;
      Blocked|blocked)
        gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --add-label "state:blocked" >/dev/null 2>&1
        ;;
      *)
        gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --add-label "state:${new_state}" >/dev/null 2>&1
        ;;
    esac
  fi

  # Update priority via labels
  if [ -n "$new_priority" ]; then
    local current_prio
    current_prio=$(gh issue view "$num" --repo "$GITHUB_ISSUES_REPO" --json labels -q '.labels[].name' 2>/dev/null | grep '^priority:' || true)
    for old_prio in $current_prio; do
      gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --remove-label "$old_prio" >/dev/null 2>&1 || true
    done
    local prio_label
    case "$new_priority" in
      1) prio_label="priority:1-urgent" ;;
      2) prio_label="priority:2-high" ;;
      3) prio_label="priority:3-medium" ;;
      4) prio_label="priority:4-low" ;;
      *) prio_label="priority:3-medium" ;;
    esac
    gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" --add-label "$prio_label" >/dev/null 2>&1
  fi

  echo "✓ Updated issue ${ISSUE_PREFIX}-${num}"
  echo "https://github.com/${GITHUB_ISSUES_REPO}/issues/${num}"
}

gh_comment_list() {
  local num
  num=$(gh_number "$1")
  gh issue view "$num" --repo "$GITHUB_ISSUES_REPO" --json comments \
    --jq '.comments[] | "- **@\(.author.login)** - *\(.createdAt)*\n\n  \(.body)\n"' 2>/dev/null || echo "No comments"
}

gh_comment_add() {
  local num
  num=$(gh_number "$1")
  local body="$2"
  gh issue comment "$num" --repo "$GITHUB_ISSUES_REPO" --body "$body" 2>/dev/null
}

gh_issue_url() {
  local num
  num=$(gh_number "$1")
  echo "https://github.com/${GITHUB_ISSUES_REPO}/issues/${num}"
}

gh_board_url() {
  echo "https://github.com/${GITHUB_ISSUES_REPO}/issues"
}

gh_close() {
  local num
  num=$(gh_number "$1")
  local reason="${2:-completed}"
  gh issue close "$num" --repo "$GITHUB_ISSUES_REPO" --reason "$reason" >/dev/null 2>&1
  echo "✓ Closed ${ISSUE_PREFIX}-${num}"
}

# ── Linear Backend (unchanged) ───────────────────────────────────────────

linear_list() {
  local project="$1"; shift
  local local_args=(--project "$project" --all-assignees --sort priority --team "$LINEAR_TEAM" --no-pager)
  for state in "$@"; do
    local_args+=(--state "$state")
  done
  linear issue list "${local_args[@]}" 2>&1 | $STRIP_ANSI
}

linear_view() {
  linear issue view "$1" 2>&1 | $STRIP_ANSI
}

linear_create() {
  local title="$1"; shift
  local priority="$1"; shift
  local create_args=(--team "$LINEAR_TEAM" --project "$LINEAR_PROJECT" --title "$title" --priority "$priority")
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) create_args+=(--state "$2"); shift 2 ;;
      --description) create_args+=(--description "$2"); shift 2 ;;
      --label) create_args+=(--label "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  local OUTPUT
  OUTPUT=$(linear issue create "${create_args[@]}" 2>&1 | $STRIP_ANSI)
  if echo "$OUTPUT" | grep -q "Failed\|Error\|error"; then
    log_error "create failed: $title — $OUTPUT" 2>/dev/null
  fi
  echo "$OUTPUT"
}

linear_update() {
  local issue_id="$1"; shift
  local update_args=("$issue_id" --team "$LINEAR_TEAM")
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) update_args+=(--state "$2"); shift 2 ;;
      --priority) update_args+=(--priority "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  linear issue update "${update_args[@]}" 2>&1 | $STRIP_ANSI
}

linear_comment_list() {
  linear issue comment list "$1" 2>&1 | $STRIP_ANSI
}

linear_comment_add() {
  linear issue comment add "$1" -b "$2" 2>&1 | $STRIP_ANSI
}

linear_issue_url() {
  echo "https://linear.app/$LINEAR_ORG/issue/$1"
}

linear_board_url() {
  echo "https://linear.app/$LINEAR_ORG"
}

# ── Router ───────────────────────────────────────────────────────────────

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    # Args: [--project <name>] state1 [state2 ...]
    list_project="$LIFT_PROJECT"
    if [ "${1:-}" = "--project" ]; then
      list_project="$2"; shift 2
    fi
    backend=$(route_by_project "$list_project")
    if [ "$backend" = "github" ]; then
      gh_list "$@"
    else
      linear_list "$list_project" "$@"
    fi
    ;;

  view)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_view "$1"
    else
      linear_view "$1"
    fi
    ;;

  create)
    # Route based on configured tracker backend
    if [ "${TRACKER_ADAPTER:-github}" = "github" ]; then
      gh_create "$@"
    else
      linear_create "$@"
    fi
    ;;

  update)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_update "$@"
    else
      linear_update "$@"
    fi
    ;;

  comment-list)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_comment_list "$1"
    else
      linear_comment_list "$1"
    fi
    ;;

  comment-add)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_comment_add "$1" "$2"
    else
      linear_comment_add "$1" "$2"
    fi
    ;;

  issue-url)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_issue_url "$1"
    else
      linear_issue_url "$1"
    fi
    ;;

  board-url)
    gh_board_url
    ;;

  close)
    backend=$(route_by_id "$1")
    if [ "$backend" = "github" ]; then
      gh_close "$1" "${2:-completed}"
    else
      # Linear doesn't have a close command — use update --state instead
      local close_state="canceled"
      [ "${2:-}" = "completed" ] && close_state="Done"
      linear_update "$1" --state "$close_state"
    fi
    ;;

  *)
    echo "Unknown tracker command: $cmd" >&2
    echo "Usage: tracker.sh {list|view|create|update|comment-list|comment-add|issue-url|board-url|close}" >&2
    exit 1
    ;;
esac
