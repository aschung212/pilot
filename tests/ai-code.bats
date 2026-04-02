#!/usr/bin/env bats
# Tests for adapters/ai-code.sh

load test_helper

AI_CODE="$PILOT_DIR/adapters/ai-code.sh"

@test "ai-code: unknown command exits with error" {
  run bash "$AI_CODE" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown ai-code command"* ]]
}

@test "ai-code: run passes prompt to claude" {
  run bash "$AI_CODE" run "Write hello world"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/claude" ]
  grep -q "Write hello world" "$TEST_TMPDIR/mock_calls/claude"
}

@test "ai-code: run respects --model override" {
  run bash "$AI_CODE" run "test" --model sonnet
  [ "$status" -eq 0 ]
  grep -q -- "--model sonnet" "$TEST_TMPDIR/mock_calls/claude"
}

@test "ai-code: run respects --max-turns" {
  run bash "$AI_CODE" run "test" --max-turns 5
  [ "$status" -eq 0 ]
  grep -q -- "--max-turns 5" "$TEST_TMPDIR/mock_calls/claude"
}

@test "ai-code: run with --json-output writes to file" {
  local json_out="$TEST_TMPDIR/output.json"
  run bash "$AI_CODE" run "test" --json-output "$json_out"
  [ "$status" -eq 0 ]
  grep -q -- "--output-format json" "$TEST_TMPDIR/mock_calls/claude"
}

@test "ai-code: default model is opus" {
  run bash "$AI_CODE" run "test"
  [ "$status" -eq 0 ]
  grep -q -- "--model opus" "$TEST_TMPDIR/mock_calls/claude"
}
