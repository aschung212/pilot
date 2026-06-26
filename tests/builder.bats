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
  [[ "$output" == *"Iteration cap"* ]]
}

# bats test_tags=fast
@test "builder: usage_check stops at token cap" {
  RUN=5; MAX_ITERATIONS_PER_NIGHT=12
  NIGHTLY_OUTPUT_TOKENS=550000; MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  ALERT_SENT=false; ALERT_THRESHOLD_PCT=80
  run usage_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Token cap"* ]]
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
  [[ "$output" == *"consecutive failures"* ]]
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
  [[ "$output" == *"no new commits"* ]]
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
  [[ "$output" != *"4.6"* ]]
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
