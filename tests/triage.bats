#!/usr/bin/env bats
# Tests for scripts/triage.sh — verdict parsing and RESCOPE logic

load test_helper

TRIAGE="$PILOT_DIR/scripts/triage.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME" "$TEST_TMPDIR/bin"

  export PROJECT_NAME="TestProject"
  export TECH_STACK="Test Stack"
  export REPO_PATH="$TEST_TMPDIR/repo"
  export LINEAR_TEAM="TEST"
  export LINEAR_PROJECT="TestProject"
  export LINEAR_ORG="testorg"
  export SLACK_CHANNEL_AUTOMATION="C_TEST_AUTO"
  export SLACK_BOT_TOKEN=""
  export SLACK_WEBHOOK_URL=""
  export PRODUCT_DECISIONS_FILE="$TEST_TMPDIR/decisions.md"
  echo "No templates. Focus on polish." > "$PRODUCT_DECISIONS_FILE"

  export PATH="$TEST_DIR/mocks:$TEST_TMPDIR/bin:$PATH"
  mkdir -p "$REPO_PATH"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ── Verdict parsing unit tests ───────────────────────────────────────────────
# These test the regex patterns used in triage.sh without running the full script

# bats test_tags=fast
@test "triage: APPROVE verdict parsed correctly" {
  result="VERDICT: APPROVE
CONFIDENCE: 8
REASON: Clean implementation
IMPLEMENTATION_PLAN: 1. Edit src/foo.ts 2. Add test 3. Update CSS
COMPLEXITY: small
SUGGESTED_PRIORITY: 2"
  verdict=$(echo "$result" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)' | head -1 | sed 's/VERDICT: //')
  [ "$verdict" = "APPROVE" ]
}

# bats test_tags=fast
@test "triage: RESCOPE verdict parsed correctly" {
  result="VERDICT: RESCOPE
CONFIDENCE: 9
REASON: This issue bundles settings redesign and export feature
SUB_ISSUE_1_TITLE: Redesign settings page layout
SUB_ISSUE_1_PRIORITY: 2
SUB_ISSUE_1_DESCRIPTION: Rework the settings page to use tab navigation
SUB_ISSUE_2_TITLE: Add CSV export
SUB_ISSUE_2_PRIORITY: 3
SUB_ISSUE_2_DESCRIPTION: Add data export functionality to settings"
  verdict=$(echo "$result" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)' | head -1 | sed 's/VERDICT: //')
  [ "$verdict" = "RESCOPE" ]
}

# bats test_tags=fast
@test "triage: sub-issue fields parsed from RESCOPE output" {
  result="SUB_ISSUE_1_TITLE: Redesign settings page
SUB_ISSUE_1_PRIORITY: 2
SUB_ISSUE_1_DESCRIPTION: Rework the layout
SUB_ISSUE_2_TITLE: Add CSV export
SUB_ISSUE_2_PRIORITY: 3
SUB_ISSUE_2_DESCRIPTION: Export feature
SUB_ISSUE_3_TITLE: Third thing
SUB_ISSUE_3_PRIORITY: 2
SUB_ISSUE_3_DESCRIPTION: Another task"

  count=0
  for i in 1 2 3 4; do
    title=$(echo "$result" | grep -oE "SUB_ISSUE_${i}_TITLE: .*" | head -1 | sed "s/SUB_ISSUE_${i}_TITLE: //")
    [ -z "$title" ] && continue
    count=$((count + 1))
  done
  [ "$count" -eq 3 ]
}

# bats test_tags=fast
@test "triage: max 4 sub-issues enforced by parsing loop" {
  # Even if 5 are provided, the loop only checks 1-4
  result="SUB_ISSUE_1_TITLE: One
SUB_ISSUE_2_TITLE: Two
SUB_ISSUE_3_TITLE: Three
SUB_ISSUE_4_TITLE: Four
SUB_ISSUE_5_TITLE: Five"

  count=0
  for i in 1 2 3 4; do
    title=$(echo "$result" | grep -oE "SUB_ISSUE_${i}_TITLE: .*" | head -1 | sed "s/SUB_ISSUE_${i}_TITLE: //")
    [ -z "$title" ] && continue
    count=$((count + 1))
  done
  [ "$count" -eq 4 ]
}

# bats test_tags=fast
@test "triage: RESCOPE_GUIDANCE changes with backlog size" {
  # Small backlog — rescope available
  BACKLOG_COUNT=10
  if [ "$BACKLOG_COUNT" -gt 20 ]; then
    guidance="Prefer ENHANCE"
  else
    guidance="RESCOPE is available"
  fi
  [[ "$guidance" == "RESCOPE is available" ]]

  # Large backlog — prefer enhance
  BACKLOG_COUNT=25
  if [ "$BACKLOG_COUNT" -gt 20 ]; then
    guidance="Prefer ENHANCE"
  else
    guidance="RESCOPE is available"
  fi
  [[ "$guidance" == "Prefer ENHANCE" ]]
}

# bats test_tags=fast
@test "triage: FLAG is default when no verdict parsed" {
  result="Some garbage output with no verdict line"
  verdict=$(echo "$result" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)' | head -1 | sed 's/VERDICT: //')
  verdict=${verdict:-FLAG}
  [ "$verdict" = "FLAG" ]
}

# bats test_tags=fast
@test "triage: confidence and complexity parsed" {
  result="VERDICT: APPROVE
CONFIDENCE: 7
REASON: Looks good
IMPLEMENTATION_PLAN: stuff
COMPLEXITY: medium
SUGGESTED_PRIORITY: 2"
  confidence=$(echo "$result" | grep -oE 'CONFIDENCE: [0-9]+' | head -1 | grep -oE '[0-9]+')
  complexity=$(echo "$result" | grep -oE 'COMPLEXITY: [a-z]+' | head -1 | sed 's/COMPLEXITY: //')
  [ "$confidence" = "7" ]
  [ "$complexity" = "medium" ]
}

# ── Dry run integration test ─────────────────────────────────────────────────

# bats test_tags=fast
@test "triage: dry-run does not create issues or post to Slack" {
  export MOCK_GEMINI_OUTPUT="VERDICT: APPROVE
CONFIDENCE: 8
REASON: Good issue
IMPLEMENTATION_PLAN: Fix the thing
COMPLEXITY: small
SUGGESTED_PRIORITY: 2"
  run bash "$TRIAGE" --dry-run
  [ "$status" -eq 0 ]
  # In dry-run mode, tracker comment-add should not be called
  if [ -f "$TEST_TMPDIR/mock_calls/linear" ]; then
    ! grep -q "comment add" "$TEST_TMPDIR/mock_calls/linear"
  fi
}
