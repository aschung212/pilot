#!/usr/bin/env bats
# Tests for builder utilities (lib/builder-utils.sh)
# These test the ACTUAL functions, not copies of the logic.

load test_helper

# Source the real functions
setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"
  export PATH="$TEST_DIR/mocks:$PATH"
  export _PILOT_TEST_MODE=1

  # Stub slack_send so usage_check doesn't fail
  slack_send() { :; }
  export -f slack_send

  source "$PILOT_DIR/lib/builder-utils.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ── parse_usage ──────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: parse_usage extracts tokens from valid JSON" {
  cat > "$TEST_TMPDIR/output.json" << 'EOF'
{
  "result": "some code",
  "usage": {
    "input_tokens": 50000,
    "output_tokens": 12000,
    "cache_read_input_tokens": 8000,
    "cache_creation_input_tokens": 3000
  }
}
EOF
  result=$(parse_usage "$TEST_TMPDIR/output.json")
  [ "$result" = "50000,12000,8000,3000" ]
}

# bats test_tags=fast
@test "builder: parse_usage handles missing/corrupt JSON" {
  echo "not json" > "$TEST_TMPDIR/bad.json"
  result=$(parse_usage "$TEST_TMPDIR/bad.json")
  [ "$result" = "0,0,0,0" ]
}

# bats test_tags=fast
@test "builder: parse_usage handles missing file" {
  result=$(parse_usage "$TEST_TMPDIR/nonexistent.json")
  [ "$result" = "0,0,0,0" ]
}

# ── usage_check ──────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: usage_check stops at iteration cap" {
  RUN=12; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=0; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  run usage_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Iteration cap"* ]] || return 1
}

# bats test_tags=fast
@test "builder: usage_check stops at token cap" {
  RUN=5; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=550000; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  run usage_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Token cap"* ]] || return 1
}

# bats test_tags=fast
@test "builder: usage_check passes when under caps" {
  RUN=5; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=100000; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  run usage_check
  [ "$status" -eq 0 ]
}

# ── should_continue ──────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: should_continue stops on consecutive failures" {
  RUN=1; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=0; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  STOP_AT="23:59"; FAILURES=3; MAX_CONSECUTIVE_FAILURES=3
  STALLS=0; MAX_STALLS=2
  run should_continue
  [ "$status" -eq 1 ]
  [[ "$output" == *"consecutive failures"* ]] || return 1
}

# bats test_tags=fast
@test "builder: should_continue stops on stalls" {
  RUN=1; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=0; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  STOP_AT="23:59"; FAILURES=0; MAX_CONSECUTIVE_FAILURES=3
  STALLS=2; MAX_STALLS=2
  run should_continue
  [ "$status" -eq 1 ]
  [[ "$output" == *"no new commits"* ]] || return 1
}

# bats test_tags=fast
@test "builder: should_continue passes when everything is under limit" {
  RUN=1; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=0; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  STOP_AT="23:59"; FAILURES=0; MAX_CONSECUTIVE_FAILURES=3
  STALLS=0; MAX_STALLS=2
  run should_continue
  [ "$status" -eq 0 ]
}

# ── parse_stop_time ──────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: parse_stop_time treats number as iteration count" {
  MAX_ITERATIONS_PER_NIGHT=12
  parse_stop_time "5" "07:00"
  [ "$MAX_ITERATIONS_PER_NIGHT" = "5" ]
  [ "$STOP_AT" = "23:59" ]
}

# bats test_tags=fast
@test "builder: parse_stop_time keeps time as stop time" {
  MAX_ITERATIONS_PER_NIGHT=12
  parse_stop_time "06:00" "07:00"
  [ "$STOP_AT" = "06:00" ]
  [ "$MAX_ITERATIONS_PER_NIGHT" = "12" ]
}

# bats test_tags=fast
@test "builder: parse_stop_time uses default when arg matches 07:00" {
  parse_stop_time "07:00" "06:30"
  [ "$STOP_AT" = "06:30" ]
}

# ── model_display_name ────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: model_display_name strips [1m] context suffix" {
  [ "$(model_display_name 'claude-opus-4-8[1m]')" = "Claude Opus 4.8" ]
}

# bats test_tags=fast
@test "builder: model_display_name handles the current pinned model" {
  [ "$(model_display_name 'claude-opus-5[1m]')" = "Claude Opus 5" ]
}

# bats test_tags=fast
@test "builder: model_display_name handles plain model id" {
  [ "$(model_display_name 'claude-opus-4-8')" = "Claude Opus 4.8" ]
  [ "$(model_display_name 'claude-sonnet-4-6')" = "Claude Sonnet 4.6" ]
}

# bats test_tags=fast
@test "builder: model_display_name drops trailing date snapshot" {
  [ "$(model_display_name 'claude-haiku-4-5-20251001')" = "Claude Haiku 4.5" ]
}

# bats test_tags=fast
@test "builder: model_display_name handles single-component version" {
  [ "$(model_display_name 'claude-fable-5')" = "Claude Fable 5" ]
}

# bats test_tags=fast
@test "builder: model_display_name does not emit the stale self-reported version" {
  # Regression: the builder used to self-report "Opus 4.6" in commit trailers
  # regardless of the --model flag. The trailer must follow AI_CODE_MODEL.
  run model_display_name 'claude-opus-4-8[1m]'
  [ "$status" -eq 0 ]
  [[ "$output" != *"4.6"* ]] || return 1
}

# bats test_tags=fast
@test "builder: model_display_name degrades gracefully on bare alias" {
  # A bare alias has no parseable version; fall back to plain "Claude".
  [ "$(model_display_name 'opus')" = "Claude" ]
  [ "$(model_display_name '')" = "Claude" ]
}

# ── is_auth_failure ───────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: is_auth_failure detects the launchd 401 signature" {
  # The exact string the builder logged on 2026-06-19 and 2026-06-22.
  run is_auth_failure 'Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"},"request_id":"req_x"}'
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "builder: is_auth_failure detects the logged-out signature" {
  run is_auth_failure $'warn: CPU lacks AVX support\nNot logged in · Please run /login'
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "builder: is_auth_failure passes a healthy authenticated response" {
  run is_auth_failure '{"type":"result","result":"AUTH_OK","is_error":false}'
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "builder: is_auth_failure does not abort on a transient network error" {
  # Non-auth failures must fall through to the loop's per-iteration handling.
  run is_auth_failure '{"type":"result","result":"Network error: connection reset","is_error":true}'
  [ "$status" -eq 1 ]
}

# ── run_with_timeout / kill_process_tree ─────────────────────────────────────
# Guards the 2026-07-09 regression: a claude call with no wall-clock bound hung
# indefinitely and, because launchd will not start a new instance while the
# previous one is alive, silently blocked the builder for 5 days.

# bats test_tags=fast
@test "builder: run_with_timeout returns 124 when the command overruns" {
  run run_with_timeout 1 sleep 10
  [ "$status" -eq 124 ]
}

# bats test_tags=fast
@test "builder: run_with_timeout returns 0 for a command that finishes in time" {
  run run_with_timeout 5 sleep 1
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "builder: run_with_timeout passes through the command's own exit code" {
  run run_with_timeout 5 bash -c 'exit 7'
  [ "$status" -eq 7 ]
}

# bats test_tags=fast
@test "builder: run_with_timeout preserves stdout for \$(...) capture" {
  out=$(run_with_timeout 5 echo hello)
  [ "$out" = "hello" ]
}

# bats test_tags=fast
@test "builder: run_with_timeout treats 0 / non-numeric as no-timeout passthrough" {
  run run_with_timeout 0 bash -c 'exit 3'
  [ "$status" -eq 3 ]
  run run_with_timeout abc bash -c 'exit 4'
  [ "$status" -eq 4 ]
}

# bats test_tags=fast
@test "builder: run_with_timeout returns 124 for a nested backgrounded overrun" {
  run run_with_timeout 1 bash -c 'sleep 6 & wait'
  [ "$status" -eq 124 ]
}

# bats test_tags=fast
@test "builder: kill_process_tree signals every descendant, not just the root" {
  pidfile="$TEST_TMPDIR/tree.pids"
  # Builds root(sh) -> mid(sh) -> sleep and asserts ALL THREE die. Recursion
  # has to run twice to reach the sleep, which is the whole property.
  #
  # This replaces a test that drove the same property through
  # `run run_with_timeout 1 ...` and asserted a `touch` scheduled at 2s never
  # landed after a kill at 1s. That form was wrong twice over. It was
  # load-sensitive — the entire proof was one second of scheduling slack, and
  # on a loaded machine the kill slips past 2s (measured failing 2 of 3 runs at
  # load ~102 on 2026-08-31). And it could not fail even when the property was
  # broken: with the recursion deleted from kill_process_tree so that only the
  # root was ever signalled, bats' own `run` plumbing tore the descendants down
  # anyway, and the test still reported ok. Verified by logging every signal
  # kill_process_tree actually issued.
  #
  # So: call kill_process_tree directly, with no `run` in the path. That the
  # watchdog reaches it on expiry is covered by the 124 tests above.
  cat > "$TEST_TMPDIR/mid.sh" << EOF
#!/bin/sh
echo \$\$ >> "$pidfile"
sleep 30 &
echo \$! >> "$pidfile"
wait
EOF
  cat > "$TEST_TMPDIR/root.sh" << EOF
#!/bin/sh
echo \$\$ >> "$pidfile"
"$TEST_TMPDIR/mid.sh" &
wait
EOF
  chmod +x "$TEST_TMPDIR/mid.sh" "$TEST_TMPDIR/root.sh"

  # A pid is gone when ps knows nothing about it, or still lists it as a
  # zombie nobody has reaped yet.
  _gone() {
    local st
    st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
    [ -z "$st" ] || [ "${st#Z}" != "$st" ]
  }

  "$TEST_TMPDIR/root.sh" &
  root=$!

  # Wait for the whole chain to report in. Bounded poll, never a fixed sleep.
  for _ in $(seq 1 50); do
    [ "$(cat "$pidfile" 2>/dev/null | wc -l | tr -d ' ')" -ge 3 ] && break
    sleep 0.1
  done
  pids="$(cat "$pidfile" 2>/dev/null | tr -d ' ')"
  [ "$(echo "$pids" | wc -l | tr -d ' ')" -eq 3 ]
  # root.sh's own $$ must be the pid we are about to kill, or the tree we
  # built is not the tree we are testing.
  [ "$(echo "$pids" | head -1)" = "$root" ]

  kill_process_tree "$root" TERM

  for pid in $pids; do
    for _ in $(seq 1 50); do
      _gone "$pid" && break
      sleep 0.1
    done
  done

  survivors=""
  for pid in $pids; do
    if ! _gone "$pid"; then
      survivors="$survivors $pid"
      kill -KILL "$pid" 2>/dev/null || true   # never leak a 30s sleep into the suite
    fi
  done
  if [ -n "$survivors" ]; then
    echo "kill_process_tree left these alive:$survivors" >&2
    return 1
  fi
}

# ── _marker_lines (ISSUE_DONE / ISSUE_PROGRESS separator normalization) ──────
# Regression cover for the 2026-07-28 LIFT-783 duplicate-build incident: the
# prompt asks for `ISSUE_DONE:LIFT-N|summary` but the agent has only ever
# emitted the colon form, so every pipe-only parser silently no-opped and the
# issue was never flipped to state:started while its PR was open.

# bats test_tags=fast
@test "builder: _marker_lines parses the colon form the agent actually emits" {
  export ISSUE_PREFIX=LIFT
  echo 'ISSUE_DONE:LIFT-783:Synced plateCountMode via a new column' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "$status" -eq 0 ]
  [ "$output" = "ISSUE_DONE:LIFT-783|Synced plateCountMode via a new column" ]
}

# bats test_tags=fast
@test "builder: _marker_lines still parses the documented pipe form" {
  export ISSUE_PREFIX=LIFT
  echo 'ISSUE_DONE:LIFT-42|Did the thing' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "$output" = "ISSUE_DONE:LIFT-42|Did the thing" ]
}

# bats test_tags=fast
@test "builder: _marker_lines parses the em-dash form" {
  export ISSUE_PREFIX=LIFT
  echo 'ISSUE_DONE:LIFT-7 — Did the thing' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "$output" = "ISSUE_DONE:LIFT-7|Did the thing" ]
}

# bats test_tags=fast
@test "builder: _marker_lines emits a bare marker with an empty summary" {
  export ISSUE_PREFIX=LIFT
  echo 'ISSUE_DONE:LIFT-9' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "$output" = "ISSUE_DONE:LIFT-9|" ]
}

# bats test_tags=fast
@test "builder: _marker_lines splits id from summary under IFS=|" {
  export ISSUE_PREFIX=LIFT
  echo 'ISSUE_DONE:LIFT-783:Synced plateCountMode' > "$TEST_TMPDIR/run.md"
  _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md" | while IFS='|' read -r marker summary; do
    [ "$marker" = "ISSUE_DONE:LIFT-783" ]
    [ "$summary" = "Synced plateCountMode" ]
  done
}

# bats test_tags=fast
@test "builder: _marker_lines keeps ISSUE_PROGRESS separate from ISSUE_DONE" {
  export ISSUE_PREFIX=LIFT
  printf 'ISSUE_DONE:LIFT-1:done thing\nISSUE_PROGRESS:LIFT-2:progress thing\n' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_PROGRESS "$TEST_TMPDIR/run.md"
  [ "$output" = "ISSUE_PROGRESS:LIFT-2|progress thing" ]
}

# bats test_tags=fast
@test "builder: _marker_lines returns nothing when no markers are present" {
  export ISSUE_PREFIX=LIFT
  echo 'no markers here' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=fast
@test "builder: _marker_lines preserves file order for the head -1 (PR title) callers" {
  export ISSUE_PREFIX=LIFT
  # Lexicographically LIFT-1000 sorts before LIFT-900, so a sorted
  # implementation would title the PR after the wrong issue.
  printf 'ISSUE_DONE:LIFT-900:first in the log\nISSUE_DONE:LIFT-1000:second in the log\n' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "${lines[0]}" = "ISSUE_DONE:LIFT-900|first in the log" ]
  [ "${lines[1]}" = "ISSUE_DONE:LIFT-1000|second in the log" ]
}

# bats test_tags=fast
@test "builder: _marker_lines does not dedupe (looping callers add their own sort -u)" {
  export ISSUE_PREFIX=LIFT
  printf 'ISSUE_DONE:LIFT-5:same\nISSUE_DONE:LIFT-5:same\n' > "$TEST_TMPDIR/run.md"
  run _marker_lines ISSUE_DONE "$TEST_TMPDIR/run.md"
  [ "${#lines[@]}" -eq 2 ]
}

# ── wip_gate_active ──────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: wip_gate_active gates when open PRs reach the cap" {
  run wip_gate_active 8 8 ""
  [ "$status" -eq 0 ]
  run wip_gate_active 12 8 ""
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "builder: wip_gate_active passes below the cap" {
  run wip_gate_active 7 8 ""
  [ "$status" -eq 1 ]
  run wip_gate_active 0 8 ""
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "builder: wip_gate_active disabled by 0 or non-numeric cap" {
  run wip_gate_active 50 0 ""
  [ "$status" -eq 1 ]
  run wip_gate_active 50 "" ""
  [ "$status" -eq 1 ]
  run wip_gate_active 50 "abc" ""
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "builder: wip_gate_active exempts retry iterations" {
  # RETRY_ISSUES non-empty: those failed PRs were closed at startup, so the
  # retry does not grow the review queue — never gate it.
  run wip_gate_active 12 8 "TEST-101 TEST-102"
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "builder: wip_gate_active tolerates a non-numeric open count (gh unavailable)" {
  run wip_gate_active "not-a-number" 8 ""
  [ "$status" -eq 1 ]
}

# ── extract_pr_url (honest PR-creation failure — ports pilot PR #8's live fragment) ──

# bats test_tags=fast
@test "builder: extract_pr_url returns the anchored PR URL" {
  out=$(extract_pr_url "https://github.com/aschung212/Lift/pull/1234")
  [ "$out" = "https://github.com/aschung212/Lift/pull/1234" ]
  # embedded in surrounding gh output
  out=$(extract_pr_url "Creating pull request...
https://github.com/aschung212/Lift/pull/99")
  [ "$out" = "https://github.com/aschung212/Lift/pull/99" ]
}

# bats test_tags=fast
@test "builder: extract_pr_url rejects compare URLs and failure text" {
  # pull/new/<branch> is GitHub's COMPARE page, not a PR — matching it is how
  # the 2026-05-11 incident reported 12 "PRs" to Slack when only 3 existed.
  out=$(extract_pr_url "https://github.com/aschung212/Lift/pull/new/enhance/run3-2026-05-11")
  [ -z "$out" ]
  # failure text that still mentions github.com must not produce a URL
  out=$(extract_pr_url "GraphQL: something failed for https://github.com/aschung212/Lift (createPullRequest)")
  [ -z "$out" ]
  out=$(extract_pr_url "")
  [ -z "$out" ]
}

# ── PR body carries the closing keyword (script-controlled) ──────────────────
# builder.sh used to tell the coding agent to write `Closes #N` into a commit
# body and leave closing to GitHub's merge mechanism. The agent never once did,
# so from the GitHub migration until 2026-08-30 nothing closed an issue when
# its PR merged. The keyword now lives in the PR body the script itself writes,
# so it does not depend on agent compliance.

# bats test_tags=fast
@test "builder: PR body emits Closes #N for the primary issue, and nothing when there is none" {
  # Extract the real heredoc from builder.sh rather than restating it, so this
  # test cannot drift away from the body the script actually sends.
  BODY_TMPL=$(awk '/<<PRBODY$/{f=1;next} f && /^PRBODY$/{exit} f' "$PILOT_DIR/scripts/builder.sh")
  [ -n "$BODY_TMPL" ]
  [[ "$BODY_TMPL" == *"## Summary"* ]] || return 1

  render() {
    PRIMARY_ISSUE="$1" ISSUE_URL="http://x/$1" PLAN="the plan" \
      bash -c 'PRIMARY_ISSUE_NUM="${PRIMARY_ISSUE##*-}"
               [ -z "$PRIMARY_ISSUE" ] && PRIMARY_ISSUE_NUM=""
               cat <<PRBODY
'"$BODY_TMPL"'
PRBODY'
  }

  OUT=$(render "TEST-1238")
  [[ "$OUT" == *"Closes #1238"* ]] || return 1
  [[ "$OUT" == *"**Issue:** [TEST-1238]"* ]] || return 1
  # Bare number only — GitHub's parser does not understand the TEST-/LIFT- prefix
  [[ "$OUT" != *"Closes #TEST-1238"* ]] || return 1

  # A chore/manual PR with no issue must not emit a dangling `Closes #`
  OUT=$(render "")
  [[ "$OUT" != *"Closes #"* ]] || return 1
}

# bats test_tags=fast
@test "builder: derives the bare issue number from PRIMARY_ISSUE for the PR body" {
  grep -q 'PRIMARY_ISSUE_NUM="${PRIMARY_ISSUE##\*-}"' "$PILOT_DIR/scripts/builder.sh"
  grep -q 'Closes #\$PRIMARY_ISSUE_NUM' "$PILOT_DIR/scripts/builder.sh"
}
