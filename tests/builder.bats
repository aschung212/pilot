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

# ── pick_worst_verdict ───────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: pick_worst_verdict returns MERGE when all MERGE" {
  result=$(pick_worst_verdict MERGE MERGE MERGE)
  [ "$result" = "MERGE" ]
}

# bats test_tags=fast
@test "builder: pick_worst_verdict returns REVIEW when any REVIEW" {
  result=$(pick_worst_verdict MERGE REVIEW MERGE)
  [ "$result" = "REVIEW" ]
}

# bats test_tags=fast
@test "builder: pick_worst_verdict returns DO_NOT_MERGE when any DNM" {
  result=$(pick_worst_verdict MERGE MERGE DO_NOT_MERGE)
  [ "$result" = "DO_NOT_MERGE" ]
}

# bats test_tags=fast
@test "builder: pick_worst_verdict DO_NOT_MERGE beats REVIEW" {
  result=$(pick_worst_verdict REVIEW DO_NOT_MERGE MERGE)
  [ "$result" = "DO_NOT_MERGE" ]
}

# ── verdict_emoji ────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: verdict_emoji maps correctly" {
  [ "$(verdict_emoji MERGE)" = "✅" ]
  [ "$(verdict_emoji REVIEW)" = "⚠️" ]
  [ "$(verdict_emoji DO_NOT_MERGE)" = "🚫" ]
  [ "$(verdict_emoji UNKNOWN)" = "❓" ]
}

# ── format_review_findings ───────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: format_review_findings produces markdown" {
  cat > "$TEST_TMPDIR/review.txt" << 'EOF'
REVIEW_FIX:critical:src/App.vue:Missing null check
REVIEW_FIX:medium:src/lib/storage.ts:Hardcoded color
REVIEW_VERDICT:DO_NOT_MERGE
EOF
  result=$(format_review_findings "$TEST_TMPDIR/review.txt")
  [[ "$result" == *"**critical**"* ]]
  [[ "$result" == *"src/App.vue"* ]]
  [[ "$result" == *"**medium**"* ]]
}

# bats test_tags=fast
@test "builder: format_review_findings empty on clean review" {
  cat > "$TEST_TMPDIR/clean.txt" << 'EOF'
REVIEW_CLEAN
REVIEW_VERDICT:MERGE
EOF
  result=$(format_review_findings "$TEST_TMPDIR/clean.txt")
  [ -z "$result" ]
}

# ── format_review_crosschecks ────────────────────────────────────────────────

# bats test_tags=fast
@test "builder: format_review_crosschecks formats all statuses" {
  cat > "$TEST_TMPDIR/review.txt" << 'EOF'
REVIEW_CROSSCHECK:confirmed:Null check is real
REVIEW_CROSSCHECK:disputed:This was a false positive
REVIEW_CROSSCHECK:new:Found additional issue
EOF
  result=$(format_review_crosschecks "$TEST_TMPDIR/review.txt")
  [[ "$result" == *"Confirmed"* ]]
  [[ "$result" == *"Disputed"* ]]
  [[ "$result" == *"New"* ]]
}
