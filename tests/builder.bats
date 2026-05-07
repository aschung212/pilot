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
