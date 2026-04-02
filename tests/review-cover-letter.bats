#!/usr/bin/env bats
# Tests for scripts/review-cover-letter.sh

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
@test "review-cover-letter: runs with valid file" {
  LETTER="$TEST_TMPDIR/letter.md"
  echo "Dear Hiring Manager, I am writing to express interest." > "$LETTER"
  run bash "$SCRIPT" "$LETTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gemini Review"* ]]
}
