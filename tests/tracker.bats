#!/usr/bin/env bats
# Tests for adapters/tracker.sh

load test_helper

TRACKER="$PILOT_DIR/adapters/tracker.sh"

@test "tracker: list passes states to linear CLI" {
  run bash "$TRACKER" list backlog unstarted
  [ "$status" -eq 0 ]
  # Verify linear was called with correct args
  grep -q "issue list" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--state backlog" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--state unstarted" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--team TEST" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: list with --project override" {
  run bash "$TRACKER" list --project OtherProject backlog
  [ "$status" -eq 0 ]
  grep -q -- "--project OtherProject" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: view passes issue ID" {
  run bash "$TRACKER" view TEST-100
  [ "$status" -eq 0 ]
  grep -q "issue view TEST-100" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: create passes title, priority, and optional flags" {
  run bash "$TRACKER" create "Fix the bug" 2 --state unstarted --description "A bug fix"
  [ "$status" -eq 0 ]
  grep -q -- '--title Fix the bug' "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--priority 2" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--state unstarted" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--description A bug fix" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: update passes state and priority" {
  run bash "$TRACKER" update TEST-100 --state completed --priority 1
  [ "$status" -eq 0 ]
  grep -q "issue update TEST-100" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--state completed" "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--priority 1" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: comment-add passes issue ID and body" {
  run bash "$TRACKER" comment-add TEST-100 "This is a comment"
  [ "$status" -eq 0 ]
  grep -q "issue comment add TEST-100" "$TEST_TMPDIR/mock_calls/linear"
}

@test "tracker: issue-url returns correct URL" {
  run bash "$TRACKER" issue-url TEST-100
  [ "$status" -eq 0 ]
  [ "$output" = "https://linear.app/testorg/issue/TEST-100" ]
}

@test "tracker: board-url returns correct URL" {
  run bash "$TRACKER" board-url
  [ "$status" -eq 0 ]
  [ "$output" = "https://linear.app/testorg" ]
}

@test "tracker: unknown command exits with error" {
  run bash "$TRACKER" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown tracker command"* ]]
}
