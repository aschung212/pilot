#!/bin/bash
# Adapter: Notifications (default: Slack)
# Supports both webhooks (simple) and Bot API (threading).
#
# Usage:
#   notify.sh send <channel> <message>                    # simple message via webhook
#   notify.sh send-async <channel> <message>              # non-blocking
#   notify.sh thread-start <channel> <message>            # start a thread, print ts to stdout
#   notify.sh thread-reply <channel> <ts> <message>       # reply in a thread
#
# Channels:
#   automation  → #lift-automation (C0AQAEXQWBT)
#   review      → #daily-review (C0APVGJ5KRC)
#   changelog   → #system (C0APLN358UF)
#
# Identity overrides (optional):
#   notify.sh --as builder send <channel> <message>
#   notify.sh --as triage thread-start <channel> <message>
#
# Supported identities: builder, discovery, triage, review-tuner, budget-tuner, health
# Sets a distinct username and icon_emoji per agent for visual distinction in Slack.
#
# Threading requires SLACK_BOT_TOKEN in env. Falls back to webhook if not set.

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

# Channel ID mapping
get_channel_id() {
  case "$1" in
    automation) echo "${SLACK_CHANNEL_AUTOMATION:-C0AQAEXQWBT}" ;;
    review)     echo "${SLACK_CHANNEL_REVIEW:-C0APVGJ5KRC}" ;;
    changelog)  echo "${SLACK_CHANNEL_CHANGELOG:-C0APLN358UF}" ;;
    C*)         echo "$1" ;;  # already a channel ID
    *)          echo "" ;;
  esac
}

# Agent identity → display name + emoji avatar
# Returns "username|icon_emoji" or empty if no identity set
get_identity() {
  case "${1:-}" in
    builder)       echo "Lift Builder|:robot_face:" ;;
    discovery)     echo "Lift Discovery|:globe_with_meridians:" ;;
    triage)        echo "Lift Triage|:vertical_traffic_light:" ;;
    review-tuner)  echo "Lift Review Tuner|:control_knobs:" ;;
    budget-tuner)  echo "Lift Budget Tuner|:control_knobs:" ;;
    health)        echo "Lift Health|:hospital:" ;;
    *)             echo "" ;;
  esac
}

# Webhook URL mapping (fallback when no bot token)
get_webhook() {
  case "$1" in
    automation) echo "${SLACK_WEBHOOK_URL:-}" ;;
    review)     echo "${SLACK_WEBHOOK_DAILY_REVIEW:-}" ;;
    changelog)  echo "${SLACK_WEBHOOK_CHANGELOG:-}" ;;
    *)          echo "" ;;
  esac
}

# Send via webhook (no threading support)
# Returns 0 on success, 1 on failure (allows fallback to Bot API)
send_webhook() {
  local webhook="$1" msg="$2"
  [ -z "$webhook" ] && return 1
  local payload response
  payload=$(printf '{"text": %s}' "$(echo "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook" -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
  [ "$response" = "200" ] && return 0
  return 1
}

# Send via Bot API (supports threading)
# Returns the message timestamp (ts) on stdout
send_api() {
  local channel_id="$1" msg="$2" thread_ts="${3:-}"
  local token="${SLACK_BOT_TOKEN:-}"
  [ -z "$token" ] && return 1

  local identity_str
  identity_str=$(get_identity "${NOTIFY_AS:-}")
  local api_username="" api_icon=""
  if [ -n "$identity_str" ]; then
    api_username="${identity_str%%|*}"
    api_icon="${identity_str##*|}"
  fi

  local payload
  payload=$(python3 -c "
import json, sys
data = {'channel': '$channel_id', 'text': sys.stdin.read()}
thread_ts = '$thread_ts'
if thread_ts:
    data['thread_ts'] = thread_ts
username = '$api_username'
icon = '$api_icon'
if username:
    data['username'] = username
    data['icon_emoji'] = icon
print(json.dumps(data))
" <<< "$msg")

  local response
  response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$payload")

  # Return the ts for threading
  echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data.get('ok'):
        print(data['ts'])
    else:
        print('ERROR:' + data.get('error', 'unknown'), file=sys.stderr)
        print('')
except:
    print('')
" 2>/dev/null
}

# Parse --as <identity> flag
NOTIFY_AS=""
if [ "${1:-}" = "--as" ]; then
  NOTIFY_AS="${2:-}"
  shift 2
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  send)
    # Args: channel message
    # Priority: --as identity → Bot API; else webhook → Bot API fallback
    channel="$1"; msg="$2"
    if [ -n "$NOTIFY_AS" ] && [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      channel_id=$(get_channel_id "$channel")
      send_api "$channel_id" "$msg" > /dev/null
    else
      webhook=$(get_webhook "$channel")
      if [ -n "$webhook" ] && send_webhook "$webhook" "$msg"; then
        : # webhook succeeded
      elif [ -n "${SLACK_BOT_TOKEN:-}" ]; then
        channel_id=$(get_channel_id "$channel")
        send_api "$channel_id" "$msg" > /dev/null
      fi
    fi
    ;;

  send-async)
    # Args: channel message — non-blocking
    # Note: async can't do webhook-then-fallback, so prefer Bot API when available
    channel="$1"; msg="$2"
    if [ -n "$NOTIFY_AS" ] && [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      channel_id=$(get_channel_id "$channel")
      send_api "$channel_id" "$msg" > /dev/null &
    elif [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      channel_id=$(get_channel_id "$channel")
      send_api "$channel_id" "$msg" > /dev/null &
    else
      webhook=$(get_webhook "$channel")
      if [ -n "$webhook" ]; then
        send_webhook "$webhook" "$msg" &
      fi
    fi
    ;;

  thread-start)
    # Args: channel message — posts message, prints ts to stdout for threading
    channel="$1"; msg="$2"
    channel_id=$(get_channel_id "$channel")
    if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      send_api "$channel_id" "$msg"
    else
      # No bot token — fall back to webhook, return empty ts
      webhook=$(get_webhook "$channel")
      send_webhook "$webhook" "$msg"
      echo ""
    fi
    ;;

  thread-reply)
    # Args: channel ts message — replies in thread
    channel="$1"; ts="$2"; msg="$3"
    if [ -z "$ts" ]; then
      # No thread ts — fall back to standalone message
      webhook=$(get_webhook "$channel")
      send_webhook "$webhook" "$msg"
      return 0
    fi
    channel_id=$(get_channel_id "$channel")
    if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
      send_api "$channel_id" "$msg" "$ts" > /dev/null
    else
      # No bot token — fall back to webhook (no threading)
      webhook=$(get_webhook "$channel")
      send_webhook "$webhook" "$msg"
    fi
    ;;

  *)
    echo "Unknown notify command: $cmd" >&2
    echo "Usage: notify.sh {send|send-async|thread-start|thread-reply} <channel> <message>" >&2
    exit 1
    ;;
esac
