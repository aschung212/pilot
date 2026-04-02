#!/usr/bin/env bats
# Tests for scripts/digest.sh

load test_helper

DIGEST="$PILOT_DIR/scripts/digest.sh"

# bats test_tags=fast
@test "digest: dry-run prints to stdout without posting" {
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  # Should contain project names
  [[ "$output" == *"Lift"* ]]
  [[ "$output" == *"Linear Digest"* ]]
  # Should NOT have called curl
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "digest: count_lines function counts issue IDs" {
  # Simulate the count_lines function (matches digest.sh's implementation)
  count_lines() {
    local c
    c=$(echo "$1" | grep -c "${LINEAR_TEAM}-" 2>/dev/null) || true
    echo "${c:-0}"
  }
  input="TEST-100  P2  Unstarted  Fix thing
TEST-101  P3  Backlog    Add thing"
  result=$(count_lines "$input")
  [ "$result" = "2" ]

  empty_result=$(count_lines "No issues found")
  [ "$empty_result" = "0" ]
}

# bats test_tags=fast
@test "digest: warns when webhook not set" {
  export SLACK_WEBHOOK_DAILY_REVIEW=""
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not set"* ]]
}
