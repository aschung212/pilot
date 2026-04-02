#!/bin/bash
# Adapter: Issue Tracker (default: Linear CLI)
# Provides a unified interface for issue management.
# To swap to a different tracker, rewrite this file.
#
# Usage:
#   tracker.sh list <states>              # list issues (space-separated states)
#   tracker.sh view <id>                  # view issue details
#   tracker.sh create <title> <priority> [--state <state>] [--description <desc>]
#   tracker.sh update <id> --state <state> [--priority <n>]
#   tracker.sh comment-list <id>          # list comments on an issue
#   tracker.sh comment-add <id> <body>    # add a comment

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

source "$SCRIPT_DIR/../lib/log.sh" 2>/dev/null || true
LOG_COMPONENT="adapter:tracker"

STRIP_ANSI='sed s/\x1b\[[0-9;]*m//g'

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    # Args: [--project <name>] state1 [state2 ...]
    # If --project is not passed, defaults to $LINEAR_PROJECT
    list_project="$LINEAR_PROJECT"
    if [ "${1:-}" = "--project" ]; then
      list_project="$2"; shift 2
    fi
    local_args=(--project "$list_project" --all-assignees --sort priority --team "$LINEAR_TEAM" --no-pager)
    for state in "$@"; do
      local_args+=(--state "$state")
    done
    linear issue list "${local_args[@]}" 2>&1 | $STRIP_ANSI
    ;;

  view)
    # Args: issue_id
    linear issue view "$1" 2>&1 | $STRIP_ANSI
    ;;

  create)
    # Args: title priority [--state state] [--description desc]
    title="$1"; shift
    priority="$1"; shift
    create_args=(--team "$LINEAR_TEAM" --project "$LINEAR_PROJECT" --title "$title" --priority "$priority")
    while [ $# -gt 0 ]; do
      case "$1" in
        --state) create_args+=(--state "$2"); shift 2 ;;
        --description) create_args+=(--description "$2"); shift 2 ;;
        --label) create_args+=(--label "$2"); shift 2 ;;
        *) shift ;;
      esac
    done
    OUTPUT=$(linear issue create "${create_args[@]}" 2>&1 | $STRIP_ANSI)
    if echo "$OUTPUT" | grep -q "Failed\|Error\|error"; then
      log_error "create failed: $title — $OUTPUT" 2>/dev/null
    fi
    echo "$OUTPUT"
    ;;

  update)
    # Args: issue_id [--state state] [--priority n]
    issue_id="$1"; shift
    update_args=("$issue_id" --team "$LINEAR_TEAM")
    while [ $# -gt 0 ]; do
      case "$1" in
        --state) update_args+=(--state "$2"); shift 2 ;;
        --priority) update_args+=(--priority "$2"); shift 2 ;;
        *) shift ;;
      esac
    done
    linear issue update "${update_args[@]}" 2>&1 | $STRIP_ANSI
    ;;

  comment-list)
    # Args: issue_id
    linear issue comment list "$1" 2>&1 | $STRIP_ANSI
    ;;

  comment-add)
    # Args: issue_id body
    linear issue comment add "$1" -b "$2" 2>&1 | $STRIP_ANSI
    ;;

  issue-url)
    # Args: issue_id — returns the web URL for an issue
    echo "https://linear.app/$LINEAR_ORG/issue/$1"
    ;;

  board-url)
    # Returns the web URL for the project board
    echo "https://linear.app/$LINEAR_ORG"
    ;;

  *)
    echo "Unknown tracker command: $cmd" >&2
    echo "Usage: tracker.sh {list|view|create|update|comment-list|comment-add|issue-url|board-url}" >&2
    exit 1
    ;;
esac
