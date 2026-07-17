#!/usr/bin/env bats
# Tests for adapters/ai-research.sh (Gemini REST API — Flash + grounding)

load test_helper

AI_RESEARCH="$PILOT_DIR/adapters/ai-research.sh"

# bats test_tags=fast
@test "ai-research: unknown command exits with error" {
  run bash "$AI_RESEARCH" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown ai-research command"* ]]
}

# bats test_tags=fast
@test "ai-research: prompt calls the Gemini API via curl" {
  run bash "$AI_RESEARCH" prompt "Search for Vue best practices"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
  grep -q "generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: prompt respects --model override" {
  run bash "$AI_RESEARCH" prompt "test" --model gemini-3.5-flash
  [ "$status" -eq 0 ]
  grep -q "models/gemini-3.5-flash:generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: default model is gemini-2.5-flash" {
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  grep -q "models/gemini-2.5-flash:generateContent" "$TEST_TMPDIR/mock_calls/curl"
}

# bats test_tags=fast
@test "ai-research: prompt with --output writes to file" {
  local out_file="$TEST_TMPDIR/research.txt"
  run bash "$AI_RESEARCH" prompt "test" --output "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  [ -s "$out_file" ]
}

# bats test_tags=fast
@test "ai-research: missing GEMINI_API_KEY fails loud (exit 3)" {
  export GEMINI_API_KEY=""
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 3 ]
  [[ "$output" == *"GEMINI_API_KEY not set"* ]]
}

# bats test_tags=fast
@test "ai-research: empty prompt fails loud (exit 2)" {
  run bash "$AI_RESEARCH" prompt ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty prompt"* ]]
}

# bats test_tags=fast
@test "ai-research: HTTP error from the API fails loud (non-zero)" {
  export MOCK_CURL_OUTPUT='{"error":{"code":429,"message":"RESOURCE_EXHAUSTED"}}'
  export MOCK_CURL_HTTP_CODE="429"
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

# bats test_tags=fast
@test "ai-research: empty API result fails loud (non-zero)" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":""}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "ai-research: parses candidate text on success" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"finding one"}]}}]}'
  run bash "$AI_RESEARCH" prompt "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding one"* ]]
}
