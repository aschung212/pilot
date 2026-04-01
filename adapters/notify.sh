#!/bin/bash
# Adapter: Notifications (default: Slack webhooks)
# Provides a unified interface for sending notifications.
# To swap to Discord/email/etc, rewrite this file.
#
# Usage:
#   notify.sh send <channel> <message>
#   notify.sh send-async <channel> <message>   # non-blocking (background)
#
# Channels map to webhook env vars:
#   automation  → $SLACK_WEBHOOK_URL
#   review      → $SLACK_WEBHOOK_DAILY_REVIEW
#   changelog   → $SLACK_WEBHOOK_CHANGELOG

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

get_webhook() {
  case "$1" in
    automation) echo "${SLACK_WEBHOOK_URL:-}" ;;
    review)     echo "${SLACK_WEBHOOK_DAILY_REVIEW:-}" ;;
    changelog)  echo "${SLACK_WEBHOOK_CHANGELOG:-}" ;;
    *)          echo "${1:-}" ;;  # allow raw URL as channel
  esac
}

do_send() {
  local webhook="$1" msg="$2"
  if [ -z "$webhook" ]; then
    return 0
  fi
  local payload
  payload=$(printf '{"text": %s}' "$(echo "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  curl -s -X POST "$webhook" -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1
}

cmd="${1:-}"
shift || true

case "$cmd" in
  send)
    # Args: channel message
    webhook=$(get_webhook "$1")
    do_send "$webhook" "$2"
    ;;

  send-async)
    # Args: channel message (non-blocking)
    webhook=$(get_webhook "$1")
    do_send "$webhook" "$2" &
    ;;

  *)
    echo "Unknown notify command: $cmd" >&2
    echo "Usage: notify.sh {send|send-async} <channel> <message>" >&2
    exit 1
    ;;
esac
