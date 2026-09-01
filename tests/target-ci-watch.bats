#!/usr/bin/env bats
# Tests for scripts/target-ci-watch.sh
#
# The bug this script exists to catch went unnoticed for months, so the tests
# are weighted toward the ways a WATCHER can lie: reporting green when a
# workflow is red, resetting a streak because a DIFFERENT workflow passed, and
# staying silent when the check itself breaks.
#
# Every test drives the real script through a `gh` shim. Nothing here
# re-implements the streak logic — see CLAUDE.md, "Tests that re-implement the
# logic they test".

load test_helper

WATCH="$PILOT_DIR/scripts/target-ci-watch.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME" "$TEST_TMPDIR/bin"
  export _PILOT_TEST_MODE=1
  export PILOT_DIR="$PILOT_DIR"
  export GITHUB_REPO="aschung212/Lift"
  export DEFAULT_BRANCH="master"
  export SLACK_BOT_TOKEN="" SLACK_WEBHOOK_URL=""

  export RUNS_FIXTURE="$TEST_TMPDIR/runs.json"
  export JOBS_FIXTURE="$TEST_TMPDIR/jobs.json"
  echo '{"jobs":[{"name":"migrate-db","conclusion":"failure"}]}' > "$JOBS_FIXTURE"

  cat > "$TEST_TMPDIR/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "run list")
    jqexpr=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr="$a"; prev="$a"; done
    if [ -z "$jqexpr" ]; then cat "$RUNS_FIXTURE"; else jq -r "$jqexpr" "$RUNS_FIXTURE"; fi
    ;;
  "run view")
    jqexpr=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr="$a"; prev="$a"; done
    if [ -z "$jqexpr" ]; then cat "$JOBS_FIXTURE"; else jq -r "$jqexpr" "$JOBS_FIXTURE"; fi
    ;;
esac
exit 0
SHIM
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Each arg: workflowName|conclusion|createdAt
mkruns() {
  local json="[" first=1 i=0
  for row in "$@"; do
    IFS='|' read -r wf concl created <<< "$row"
    i=$((i + 1))
    [ $first -eq 0 ] && json="$json,"
    json="$json{\"databaseId\":$((1000 + i)),\"conclusion\":\"$concl\",\"status\":\"completed\",\"displayTitle\":\"commit $i\",\"createdAt\":\"$created\",\"url\":\"https://github.com/aschung212/Lift/actions/runs/$((1000 + i))\",\"workflowName\":\"$wf\"}"
    first=0
  done
  echo "$json]" > "$RUNS_FIXTURE"
}

# STDOUT specifically, not bats' merged $output: stdout is the payload digest.sh
# embeds in the Slack post, while lib/log.sh's diagnostics go to stderr. Asserting
# on the merged stream would fail on a correct script — and, worse, would pass a
# script that leaked a log line into the middle of a Slack message.
@test "silent on stdout in slack mode when every workflow is green" {
  mkruns "CI|success|2026-08-30T05:00:00Z" "CI|success|2026-08-29T05:00:00Z"
  stdout=$(bash "$WATCH" --slack 2>/dev/null)
  [ -z "$stdout" ]
}

@test "log output goes to stderr, never into the slack payload" {
  mkruns "CI|failure|2026-08-30T05:00:00Z"
  stdout=$(bash "$WATCH" --slack 2>/dev/null)
  [[ "$stdout" != *"| WARN |"* ]] || return 1
  [[ "$stdout" != *"| INFO |"* ]] || return 1
  stderr=$(bash "$WATCH" --slack 2>&1 >/dev/null)
  [[ "$stderr" == *"target-ci-watch"* ]] || return 1
}

@test "human mode says so when everything is green" {
  mkruns "CI|success|2026-08-30T05:00:00Z"
  run bash "$WATCH"
  [[ "$output" == *"all workflows green"* ]] || return 1
}

@test "reports a red workflow with its streak" {
  mkruns "CI|failure|2026-08-30T05:00:00Z" "CI|failure|2026-08-29T05:00:00Z" "CI|success|2026-08-28T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"CI"* ]] || return 1
  [[ "$output" == *"2 consecutive"* ]] || return 1
}

# The whole point: a green run of ANOTHER workflow must not reset the streak.
# Interleaved "npm audit" successes are what made the real branch look healthy.
@test "a different workflow's green run does not reset the streak" {
  mkruns \
    "CI|failure|2026-08-30T06:00:00Z" \
    "npm audit|success|2026-08-30T05:30:00Z" \
    "CI|failure|2026-08-30T05:00:00Z" \
    "npm audit|success|2026-08-29T05:30:00Z" \
    "CI|failure|2026-08-29T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"3 consecutive"* ]] || return 1
  [[ "$output" == *"1 workflow(s)"* ]] || return 1
}

@test "reports EVERY red workflow, not just the worst" {
  mkruns \
    "CI|failure|2026-08-30T06:00:00Z" \
    "CI|failure|2026-08-30T05:00:00Z" \
    "Integration Tests|failure|2026-08-30T04:00:00Z" \
    "Integration Tests|failure|2026-08-29T04:00:00Z" \
    "Integration Tests|failure|2026-08-28T04:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"2 workflow(s)"* ]] || return 1
  [[ "$output" == *"CI"* ]] || return 1
  [[ "$output" == *"Integration Tests"* ]] || return 1
}

@test "escalates to BROKEN at 10 consecutive failures" {
  args=(); for i in $(seq 1 10); do args+=("CI|failure|2026-08-$(printf '%02d' $((10 + i)))T05:00:00Z"); done
  mkruns "${args[@]}"
  run bash "$WATCH" --slack
  [[ "$output" == *"BROKEN"* ]] || return 1
  [[ "$output" == *"🚨"* ]] || return 1
}

@test "a single failure is reported without the BROKEN escalation" {
  mkruns "CI|failure|2026-08-30T05:00:00Z" "CI|success|2026-08-29T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" != *"BROKEN"* ]] || return 1
  [[ "$output" == *"1 consecutive"* ]] || return 1
}

# Never let the scan window imply a bound on the outage.
@test "says the streak is a lower bound when no green exists in the window" {
  mkruns "CI|failure|2026-08-30T05:00:00Z" "CI|failure|2026-08-29T05:00:00Z" "CI|failure|2026-08-28T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"at least this long"* ]] || return 1
}

@test "reports days since last green when there is one" {
  mkruns "CI|failure|2026-08-30T05:00:00Z" "CI|success|2020-01-01T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"last green"* ]] || return 1
  [[ "$output" != *"at least this long"* ]] || return 1
}

@test "names the failing jobs" {
  mkruns "CI|failure|2026-08-30T05:00:00Z"
  run bash "$WATCH" --slack
  [[ "$output" == *"migrate-db"* ]] || return 1
}

# Silence is not success: an unreadable branch must not look green.
@test "an unreadable branch is reported as UNKNOWN, not green" {
  echo '[]' > "$RUNS_FIXTURE"
  run bash "$WATCH" --slack
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNKNOWN"* ]] || return 1
  [[ "$output" != *"all workflows green"* ]] || return 1
}

@test "still-running rows are ignored when judging state" {
  cat > "$RUNS_FIXTURE" <<'JSON'
[{"databaseId":1,"conclusion":null,"status":"in_progress","displayTitle":"c","createdAt":"2026-08-30T07:00:00Z","url":"u","workflowName":"CI"},
 {"databaseId":2,"conclusion":"success","status":"completed","displayTitle":"c","createdAt":"2026-08-30T05:00:00Z","url":"u","workflowName":"CI"}]
JSON
  stdout=$(bash "$WATCH" --slack 2>/dev/null)
  [ -z "$stdout" ]
}

@test "TARGET_CI_WATCH_ENABLED=0 disables it" {
  mkruns "CI|failure|2026-08-30T05:00:00Z"
  stdout=$(TARGET_CI_WATCH_ENABLED=0 bash "$WATCH" --slack 2>/dev/null)
  [ -z "$stdout" ]
}

@test "rejects an unknown argument" {
  mkruns "CI|success|2026-08-30T05:00:00Z"
  run bash "$WATCH" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]] || return 1
}

@test "--limit must be numeric" {
  mkruns "CI|success|2026-08-30T05:00:00Z"
  run bash "$WATCH" --limit abc
  [ "$status" -eq 1 ]
}
