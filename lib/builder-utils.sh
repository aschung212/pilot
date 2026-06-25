#!/bin/bash
# Shared utility functions for the builder pipeline.
# Sourced by scripts/builder.sh. Tested directly by tests/builder.bats.
#
# These functions use shell variables set by the calling script (builder.sh).
# They're extracted here for testability — each can be called with mock state.

# ── parse_usage ──────────────────────────────────────────────────────────────
# Extract token usage from Claude JSON output.
# Input: $1 = path to JSON file
# Output: prints "input,output,cache_read,cache_create" to stdout
parse_usage() {
  local json_file="$1"
  python3 -c "
import json
try:
    with open('$json_file') as f:
        data = json.load(f)
    usage = data.get('usage', {})
    inp = usage.get('input_tokens', 0)
    out = usage.get('output_tokens', 0)
    cache_read = usage.get('cache_read_input_tokens', 0)
    cache_create = usage.get('cache_creation_input_tokens', 0)
    print(f'{inp},{out},{cache_read},{cache_create}')
except:
    print('0,0,0,0')
" 2>/dev/null
}

# ── usage_check ──────────────────────────────────────────────────────────────
# Check iteration and token caps. Returns 1 if a cap is hit.
# Reads: $RUN, $MAX_ITERATIONS_PER_NIGHT, $NIGHTLY_OUTPUT_TOKENS,
#        $MAX_OUTPUT_TOKENS_PER_NIGHT, $ALERT_SENT, $ALERT_THRESHOLD_PCT
# Side effect: calls slack_send() on cap/alert (must be defined by caller)
usage_check() {
  # Check iteration cap
  if [ "$RUN" -ge "$MAX_ITERATIONS_PER_NIGHT" ]; then
    echo "🛑 Iteration cap reached ($RUN/$MAX_ITERATIONS_PER_NIGHT). Stopping."
    slack_send "🛑 *Overnight builder stopped — iteration cap*
$RUN/$MAX_ITERATIONS_PER_NIGHT iterations | ${NIGHTLY_OUTPUT_TOKENS} output tokens"
    return 1
  fi
  # Check token cap
  if [ "$NIGHTLY_OUTPUT_TOKENS" -ge "$MAX_OUTPUT_TOKENS_PER_NIGHT" ]; then
    echo "🛑 Token cap reached (${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens). Stopping."
    slack_send "🛑 *Overnight builder stopped — token cap*
${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens | $RUN iterations"
    return 1
  fi
  # Alert at threshold (once)
  if [ "$ALERT_SENT" = "false" ]; then
    local pct
    pct=$(python3 -c "print(int($NIGHTLY_OUTPUT_TOKENS / $MAX_OUTPUT_TOKENS_PER_NIGHT * 100))")
    if [ "$pct" -ge "$ALERT_THRESHOLD_PCT" ]; then
      slack_send "⚠️ *Overnight builder — ${pct}% of token cap*
${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens | $RUN iterations"
      ALERT_SENT=true
    fi
  fi
  return 0
}

# ── should_continue ──────────────────────────────────────────────────────────
# Main loop sentinel. Returns 1 if the builder should stop.
# Reads: $STOP_AT, $FAILURES, $MAX_CONSECUTIVE_FAILURES, $STALLS, $MAX_STALLS
should_continue() {
  # Check usage caps (iterations + tokens)
  if ! usage_check; then
    return 1
  fi
  # Check time — handles overnight runs (e.g. start at 21:00, stop at 07:00)
  local now_mins stop_mins
  now_mins=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  stop_mins=$(( 10#${STOP_AT%%:*} * 60 + 10#${STOP_AT##*:} ))
  if [ "$stop_mins" -lt 720 ]; then
    # Overnight mode: stop only if current time is after midnight and past stop time
    if [ "$now_mins" -ge "$stop_mins" ] && [ "$now_mins" -lt 720 ]; then
      echo "Past stop time ($STOP_AT). Stopping."
      return 1
    fi
  else
    # Same-day mode: stop if current time is past stop time
    if [ "$now_mins" -ge "$stop_mins" ]; then
      echo "Past stop time ($STOP_AT). Stopping."
      return 1
    fi
  fi
  # Check consecutive failures
  if [ "$FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    echo "$MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping."
    return 1
  fi
  # Check stagnation (no new commits produced)
  if [ "$STALLS" -ge "$MAX_STALLS" ]; then
    echo "$MAX_STALLS consecutive iterations with no new commits. Nothing left to improve. Stopping."
    return 1
  fi
  return 0
}

# ── parse_stop_time ──────────────────────────────────────────────────────────
# Parse the CLI argument: if numeric, treat as iteration count; if time, use as stop time.
# Input: $1 = CLI arg (e.g. "06:00" or "5"), $2 = default stop time
# Sets: $MAX_ITERATIONS_PER_NIGHT, $STOP_AT (global)
parse_stop_time() {
  local arg="$1" default_stop="${2:-07:00}"
  STOP_AT="${arg:-$default_stop}"

  # If no arg or default, use config default
  if [ "$STOP_AT" = "07:00" ]; then
    STOP_AT="$default_stop"
  fi

  # If argument is a number, treat as max iterations override
  if [[ "$STOP_AT" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS_PER_NIGHT="$STOP_AT"
    STOP_AT="23:59"
  fi
}

# ── model_display_name ────────────────────────────────────────────────────────
# Convert a Claude model ID into the human-readable name used in the commit
# co-author trailer. The builder otherwise self-reports a stale version (it
# identifies as its training-cutoff model — historically "Opus 4.6" — regardless
# of the --model flag in use), so we derive the name from $AI_CODE_MODEL and
# instruct the builder to use it verbatim. Single source of truth: project.env.
#   claude-opus-4-8[1m]        -> Claude Opus 4.8
#   claude-sonnet-4-6          -> Claude Sonnet 4.6
#   claude-haiku-4-5-20251001  -> Claude Haiku 4.5
#   claude-fable-5             -> Claude Fable 5
# Input: $1 = model ID. Output: prints display name to stdout.
model_display_name() {
  local id="${1:-}"
  id="${id%%\[*}"                       # strip context-window suffix, e.g. "[1m]"
  # Drop a trailing 8-digit date snapshot, e.g. "-20251001"
  case "$id" in
    *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) id="${id%-*}" ;;
  esac

  local IFS='-'
  local parts
  read -ra parts <<< "$id"              # [0]=brand, [1]=family, [2..]=version
  local family="${parts[1]:-}"
  [ -z "$family" ] && { printf 'Claude\n'; return; }

  # Title-case the family (bash 3.2 has no ${var^}, so use tr on the first char)
  family="$(printf '%s' "${family:0:1}" | tr '[:lower:]' '[:upper:]')${family:1}"

  local version="" i
  for ((i = 2; i < ${#parts[@]}; i++)); do
    if [ -z "$version" ]; then version="${parts[i]}"; else version="$version.${parts[i]}"; fi
  done

  if [ -n "$version" ]; then
    printf 'Claude %s %s\n' "$family" "$version"
  else
    printf 'Claude %s\n' "$family"
  fi
}
