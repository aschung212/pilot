#!/usr/bin/env bats
# Tests for scripts/review-cover-letter.sh
# Routes through the Gemini REST adapter (adapters/ai-research.sh) — the retired
# `gemini` CLI is no longer used. curl is mocked (tests/mocks/curl), so no calls
# leave the machine.

load test_helper

SCRIPT="$PILOT_DIR/scripts/review-cover-letter.sh"

# bats test_tags=fast
@test "review-cover-letter: exits with error when no file argument" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "review-cover-letter: exits with error for missing file" {
  run bash "$SCRIPT" "/nonexistent/path.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

# bats test_tags=fast
@test "review-cover-letter: reviews a valid letter via the Gemini REST API, not the retired CLI" {
  LETTER="$TEST_TMPDIR/letter.md"
  echo "Dear Hiring Manager, I am writing to express interest." > "$LETTER"
  run bash "$SCRIPT" "$LETTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gemini Review"* ]]
  # Went through the REST adapter (curl → generateContent) …
  [ -f "$TEST_TMPDIR/mock_calls/curl" ]
  grep -q "generateContent" "$TEST_TMPDIR/mock_calls/curl"
  # … and never shelled out to the retired `gemini` CLI.
  [ ! -f "$TEST_TMPDIR/mock_calls/gemini" ]
}

# bats test_tags=fast
@test "review-cover-letter: accepts an optional job-description argument" {
  LETTER="$TEST_TMPDIR/letter.md"
  JD="$TEST_TMPDIR/jd.md"
  echo "Dear Hiring Manager, I am writing to express interest." > "$LETTER"
  echo "We need a senior engineer with distributed-systems experience." > "$JD"
  run bash "$SCRIPT" "$LETTER" "$JD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gemini Review"* ]]
}

# bats test_tags=fast
@test "review-cover-letter: fails loud when the Gemini API errors on both passes" {
  LETTER="$TEST_TMPDIR/letter.md"
  echo "Dear Hiring Manager, I am writing to express interest." > "$LETTER"
  export MOCK_CURL_OUTPUT='{"error":{"code":429,"message":"RESOURCE_EXHAUSTED"}}'
  export MOCK_CURL_HTTP_CODE="429"
  run bash "$SCRIPT" "$LETTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"review failed"* ]]
}
