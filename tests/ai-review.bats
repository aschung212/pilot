#!/usr/bin/env bats
# Tests for adapters/ai-review.sh

load test_helper

REVIEW="$PILOT_DIR/adapters/ai-review.sh"

# Use the standard setup from test_helper, then add our extras
_ai_review_setup() {
  DIFF_FILE="$TEST_TMPDIR/test.diff"
  cp "$FIXTURES_DIR/sample-diff.txt" "$DIFF_FILE"
  OUTPUT_FILE="$TEST_TMPDIR/review-output.txt"
  mkdir -p "$TEST_TMPDIR/bin"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

# bats test_tags=fast
@test "ai-review: unknown command exits with error" {
  run bash "$REVIEW" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown ai-review command"* ]]
}

# bats test_tags=fast
@test "ai-review: layer1 produces verdict on clean review" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="REVIEW_CLEAN
REVIEW_VERDICT:MERGE"
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "REVIEW_VERDICT:MERGE" "$OUTPUT_FILE"
  grep -q "REVIEW_MODEL:" "$OUTPUT_FILE"
}

# bats test_tags=fast
@test "ai-review: layer1 with findings produces DO_NOT_MERGE" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="REVIEW_FIX:critical:src/App.vue:Null pointer
REVIEW_VERDICT:DO_NOT_MERGE"
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "REVIEW_VERDICT:DO_NOT_MERGE" "$OUTPUT_FILE"
  grep -q "REVIEW_FIX:critical" "$OUTPUT_FILE"
}

# bats test_tags=fast
@test "ai-review: layer1 falls back to claude on gemini failure" {
  _ai_review_setup
  # Make gemini fail
  cat > "$TEST_TMPDIR/bin/gemini" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$TEST_TMPDIR/bin/gemini"

  export MOCK_CLAUDE_OUTPUT='{"result": "REVIEW_CLEAN\nREVIEW_VERDICT:MERGE", "is_error": false}'
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback"* ]]
}

# bats test_tags=fast
@test "ai-review: layer1 skips when all models fail" {
  _ai_review_setup
  # Make both fail
  cat > "$TEST_TMPDIR/bin/gemini" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$TEST_TMPDIR/bin/gemini"

  cat > "$TEST_TMPDIR/bin/claude" <<'EOF'
#!/bin/bash
echo '{"result": "", "is_error": true}'
EOF
  chmod +x "$TEST_TMPDIR/bin/claude"

  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "REVIEW_VERDICT:REVIEW" "$OUTPUT_FILE"
  grep -q "REVIEW_MODEL:skipped" "$OUTPUT_FILE"
}

# bats test_tags=fast
@test "ai-review: ensure_verdict adds REVIEW if missing" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="REVIEW_FIX:low:src/foo.ts:Minor issue"
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  grep -q "REVIEW_VERDICT:" "$OUTPUT_FILE"
}

# bats test_tags=fast
@test "ai-review: layer2 accepts --prior-findings" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="REVIEW_CROSSCHECK:confirmed:Null check is real
REVIEW_VERDICT:MERGE"
  PRIOR="$TEST_TMPDIR/prior.txt"
  echo "REVIEW_FIX:high:src/App.vue:Missing null check" > "$PRIOR"
  run bash "$REVIEW" layer2 "$DIFF_FILE" "$OUTPUT_FILE" --prior-findings "$PRIOR"
  [ "$status" -eq 0 ]
  grep -q "REVIEW_VERDICT:MERGE" "$OUTPUT_FILE"
  grep -q "REVIEW_CROSSCHECK:" "$OUTPUT_FILE"
}

# bats test_tags=fast
@test "ai-review: layer1 saves prompt for transparency" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="REVIEW_CLEAN
REVIEW_VERDICT:MERGE"
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  ls "$OUTPUT_DIR"/lift-review-prompt-*-layer1.txt 2>/dev/null
  [ $? -eq 0 ]
}

# bats test_tags=fast
@test "ai-review: gemini rate limit detected as failure" {
  _ai_review_setup
  export MOCK_GEMINI_OUTPUT="exhausted your capacity for model gemini-2.5-flash"
  export MOCK_CLAUDE_OUTPUT='{"result": "REVIEW_CLEAN\nREVIEW_VERDICT:MERGE", "is_error": false}'
  run bash "$REVIEW" layer1 "$DIFF_FILE" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
  # Should have fallen through to fallback or skipped
  grep -q "REVIEW_MODEL:" "$OUTPUT_FILE"
}
