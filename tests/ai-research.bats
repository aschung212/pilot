#!/usr/bin/env bats
# Tests for adapters/ai-research.sh

load test_helper

AI_RESEARCH="$PILOT_DIR/adapters/ai-research.sh"

@test "ai-research: unknown command exits with error" {
  run bash "$AI_RESEARCH" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown ai-research command"* ]]
}

@test "ai-research: prompt passes text to gemini" {
  run bash "$AI_RESEARCH" prompt "Search for Vue best practices"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/gemini" ]
}

@test "ai-research: prompt respects --model override" {
  run bash "$AI_RESEARCH" prompt "test" --model gemini-2.5-pro
  [ "$status" -eq 0 ]
  grep -q -- "-m gemini-2.5-pro" "$TEST_TMPDIR/mock_calls/gemini"
}

@test "ai-research: prompt with --output writes to file" {
  local out_file="$TEST_TMPDIR/research.txt"
  run bash "$AI_RESEARCH" prompt "test" --output "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
}

@test "ai-research: default model is gemini-2.5-flash" {
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  grep -q -- "-m gemini-2.5-flash" "$TEST_TMPDIR/mock_calls/gemini"
}
