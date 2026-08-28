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

# ── is_auth_failure ───────────────────────────────────────────────────────────
# Detect whether a `claude` CLI invocation's combined stdout+stderr indicates an
# authentication failure (expired/invalid keychain OAuth token, or logged out)
# rather than a transient/network error. Used by the builder's auth preflight to
# decide whether to abort the whole night vs. let the per-iteration failure
# handling deal with it.
# Input: $1 = captured combined output of a claude probe
# Returns: 0 if the output looks like an auth failure, 1 otherwise
is_auth_failure() {
  local output="$1"
  echo "$output" | grep -qiE 'authentication_error|Invalid authentication|Not logged in|Please run /login|API Error: 401'
}

# ── wip_gate_active ───────────────────────────────────────────────────────────
# Kanban-style WIP limit on the human review queue. Aaron is the merge
# bottleneck: when open PRs pile up unreviewed, more overnight PRs just age,
# conflict with each other, and rebase-churn as earlier ones merge. When the
# open-PR count reaches MAX_OPEN_PRS, the builder gates the night instead of
# adding to the pile — the same backpressure idea as the builder→discovery
# backlog-low signal, pointed at the human constraint.
# Input: $1 = current open PR count
#        $2 = MAX_OPEN_PRS cap (0 or non-numeric disables the gate)
#        $3 = RETRY_ISSUES — non-empty means this iteration re-works failed PRs
#             whose old PRs were closed at startup, so it does not grow the queue
# Returns: 0 if the builder should gate (stop the night), 1 otherwise
wip_gate_active() {
  local open_count="${1:-0}" max="${2:-0}" retry_issues="${3:-}"
  [[ "$max" =~ ^[0-9]+$ ]] || return 1
  [ "$max" -eq 0 ] && return 1
  [[ "$open_count" =~ ^[0-9]+$ ]] || return 1
  [ -n "$retry_issues" ] && return 1
  [ "$open_count" -ge "$max" ]
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
#   claude-opus-5[1m]          -> Claude Opus 5
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

# ── kill_process_tree ─────────────────────────────────────────────────────────
# Recursively signal a process and all of its descendants, deepest-first.
# macOS has no `setsid`/`pkill -g` we can rely on from a non-login launchd shell,
# and killing only the parent leaves reparented children alive — that's exactly
# what left 14 orphaned node/git/gh processes when the 2026-07-09 builder hung.
# Input: $1 = root pid, $2 = signal (default TERM)
kill_process_tree() {
  local pid="$1" sig="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_process_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# ── run_with_timeout ──────────────────────────────────────────────────────────
# Portable wall-clock timeout — this Mac ships neither GNU `timeout` nor
# `gtimeout`, so we roll our own watchdog. Runs "$@", and if it is still alive
# after <seconds>, kills its whole process tree (TERM, then KILL after a grace
# period) and returns 124 (GNU `timeout` convention). Otherwise returns the
# command's own exit code. stdout/stderr pass through untouched so this is safe
# inside `$(...)` capture and `... | tee` pipes.
#
# Why this exists: the overnight builder's `claude` calls had no timeout. On
# 2026-07-09 one call hung indefinitely (0% CPU, blocked); because launchd's
# StartCalendarInterval will not launch a new instance while the previous one is
# still running, that single stuck process silently suppressed every scheduled
# builder run for 5 days. A per-call timeout makes a hung call self-terminate so
# the iteration is scored a failure and the night finishes normally.
#
# Input: $1 = timeout seconds (0 or non-numeric = run with no timeout), $2.. = command
run_with_timeout() {
  local secs="$1"; shift
  if ! [[ "$secs" =~ ^[0-9]+$ ]] || [ "$secs" -eq 0 ]; then
    "$@"
    return $?
  fi

  local fired
  fired="$(mktemp -t pilot-rwt.XXXXXX)" || { "$@"; return $?; }

  "$@" &
  local cmd_pid=$!
  local start_s=$SECONDS

  # Watchdog: poll (so it can exit early when the command finishes) up to $secs,
  # then kill the tree. stdout→/dev/null so it never corrupts a captured stream.
  (
    waited=0
    while [ "$waited" -lt "$secs" ]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$cmd_pid" 2>/dev/null; then
      printf timeout > "$fired"      # marker written BEFORE the kill
      kill_process_tree "$cmd_pid" TERM
      sleep 5
      kill -0 "$cmd_pid" 2>/dev/null && kill_process_tree "$cmd_pid" KILL
    fi
  ) >/dev/null 2>&1 &
  local watch_pid=$!

  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  local elapsed=$((SECONDS - start_s))

  kill "$watch_pid" 2>/dev/null || true   # cancel the watchdog if it is still waiting
  wait "$watch_pid" 2>/dev/null || true

  # Timeout detected two ways: the watchdog's marker file (authoritative — set
  # even if the command traps TERM and exits 0), OR a fallback for harnesses
  # where the marker write races the reap (e.g. bats) — the command was killed
  # by a signal at/after the deadline. Either path returns the GNU convention 124.
  local timed_out=""
  [ -s "$fired" ] && timed_out=1
  [ -z "$timed_out" ] && [ "$elapsed" -ge "$secs" ] && [ "$rc" -gt 128 ] && timed_out=1
  rm -f "$fired"

  [ -n "$timed_out" ] && return 124
  return "$rc"
}

# ── Marker parsing ────────────────────────────────────────────────────────
# The prompt template asks for `ISSUE_DONE:LIFT-N|summary` (pipe), but the
# builder agent has emitted the colon form `ISSUE_DONE:LIFT-N:summary` in
# 96 of 96 recorded runs — the pipe form has never once appeared. Every
# downstream parser used to require the pipe, so all of them silently
# no-opped: the state flip to In Progress, the "Implementation complete"
# comment, the PR title, and the Slack digest links.
#
# That is what stranded LIFT-783 on 2026-07-28. Its pre-pick emitted no
# parseable ISSUE_PICKED marker, so state-flip-on-pick was skipped; the
# commit-driven fallback then skipped it too (its guard matches the colon
# form), and this handler never fired. #783 kept state:unstarted while
# PR #1032 was open, triage saw a live issue as fair game, rescoped it into
# #1039, and the builder rebuilt the same work as PR #1041.
#
# Normalize every accepted separator (`|`, `:`, em dash, or none at all)
# to a single pipe so the existing `IFS='|' read -r marker summary` parsing
# keeps working unchanged.
#
# Emits in FILE order and does not dedupe — callers that loop to write
# comments add their own `| sort -u`, while the `head -1` callers (PR title)
# depend on first-in-the-log, which is what they read before this refactor.
_marker_lines() {
  local kind="$1" log="$2"
  { grep -oE "${kind}:${ISSUE_PREFIX}-[0-9]+[^\"]*" "$log" 2>/dev/null || true; } \
    | sed -E "s/^(${kind}:${ISSUE_PREFIX}-[0-9]+)([[:space:]]*(\||:|—)[[:space:]]*)?/\1|/"
}
