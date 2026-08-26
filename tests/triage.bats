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

# ── FLAG verdict structured-output parsing ───────────────────────────────────
# These mirror the parsing logic in the FLAG case of triage.sh. A blank
# "NEEDS INPUT" comment with no options/recommendation is the regression we
# saw on #550 → PR #556: pin the parsing here so any future refactor that
# drops these fields fails loudly.

# bats test_tags=fast
@test "triage: FLAG_QUESTION and RECOMMENDATION extracted from FLAG output" {
  result="VERDICT: FLAG
CONFIDENCE: 6
REASON: Color-only delta indicator has multiple reasonable fixes
FLAG_QUESTION: Should the negative-delta arrow keep red, or pair color with an icon for color-blind users?
OPTION_1_TITLE: Add a directional icon next to the value
OPTION_1_PROS: works without color | matches WCAG 1.4.1
OPTION_1_CONS: extra DOM | slightly noisier UI
OPTION_2_TITLE: Switch to a neutral monochrome treatment
OPTION_2_PROS: lowest visual noise
OPTION_2_CONS: loses scannable signal | regression for sighted users
RECOMMENDATION: Option 1 — icon + color is the standard a11y pattern and keeps existing scannability."
  flag_q=$(echo "$result" | grep -oE 'FLAG_QUESTION: .*' | head -1 | sed 's/FLAG_QUESTION: //')
  rec=$(echo "$result" | grep -oE 'RECOMMENDATION: .*' | head -1 | sed 's/RECOMMENDATION: //')
  [[ "$flag_q" == "Should the negative-delta arrow keep red"* ]]
  [[ "$rec" == "Option 1 —"* ]]
}

# bats test_tags=fast
@test "triage: OPTION_N fields counted across the parsing loop" {
  result="OPTION_1_TITLE: A
OPTION_1_PROS: pro a
OPTION_1_CONS: con a
OPTION_2_TITLE: B
OPTION_2_PROS: pro b1 | pro b2
OPTION_2_CONS: con b
OPTION_3_TITLE: C
OPTION_3_PROS: pro c
OPTION_3_CONS: con c"
  count=0
  for i in 1 2 3 4; do
    t=$(echo "$result" | grep -oE "OPTION_${i}_TITLE: .*" | head -1 | sed "s/OPTION_${i}_TITLE: //")
    [ -z "$t" ] && continue
    count=$((count + 1))
  done
  [ "$count" -eq 3 ]
}

# bats test_tags=fast
@test "triage: pros pipe-split into bullets when rendering FLAG comment" {
  # Single-pipe-separated pros list should split into 3 lines, each prefixed
  # with "  - ". This matches the FLAG case's bullet rendering.
  pros="works without color | matches WCAG 1.4.1 | reuses existing icon set"
  bullets=$(echo "$pros" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/  - /')
  [ "$(echo "$bullets" | wc -l | tr -d ' ')" -eq 3 ]
  echo "$bullets" | grep -q "^  - works without color$"
  echo "$bullets" | grep -q "^  - matches WCAG 1.4.1$"
  echo "$bullets" | grep -q "^  - reuses existing icon set$"
}

# ── Dry run integration test ─────────────────────────────────────────────────

# bats test_tags=fast
@test "triage: dry-run does not create issues or post to Slack" {
  # Triage now reasons via the ai-research adapter (Gemini REST API → curl).
  # Feed the verdict back through the mocked API response.
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"VERDICT: APPROVE\nCONFIDENCE: 8\nREASON: Good issue\nIMPLEMENTATION_PLAN: Fix the thing\nCOMPLEXITY: small\nSUGGESTED_PRIORITY: 2"}]}}]}'
  run bash "$TRIAGE" --dry-run
  [ "$status" -eq 0 ]
  # In dry-run mode, tracker comment-add should not be called
  if [ -f "$TEST_TMPDIR/mock_calls/linear" ]; then
    ! grep -q "comment add" "$TEST_TMPDIR/mock_calls/linear"
  fi
}

# ── GA re-triage sweep ───────────────────────────────────────────────────────

# bats test_tags=fast
@test "triage: argument parsing accepts --re-triage and --dry-run, rejects unknown" {
  # Mirror the arg-parse loop from triage.sh
  parse_args() {
    DRY_RUN=""
    RETRIAGE=""
    for arg in "$@"; do
      case "$arg" in
        --dry-run)   DRY_RUN="--dry-run" ;;
        --re-triage) RETRIAGE="1" ;;
        *) return 1 ;;
      esac
    done
    return 0
  }

  parse_args --dry-run
  [ "$DRY_RUN" = "--dry-run" ] && [ -z "$RETRIAGE" ]

  parse_args --re-triage --dry-run
  [ "$DRY_RUN" = "--dry-run" ] && [ "$RETRIAGE" = "1" ]

  run parse_args --bogus
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "triage: re-triage marker satisfies the nightly idempotency grep" {
  # A "Re-triaged by" comment must count as triaged so nightly runs skip it,
  # and re-triage sweeps must be recorded distinctly from first-pass triage.
  COMMENTS="**Re-triaged by gemini-2.5-flash** (2026-08-21) — ⏭️ SKIP deferred until post-GA"
  echo "$COMMENTS" | grep -q "Triaged by\|Re-triaged by"

  COMMENTS="**Triaged by gemini-2.5-flash** (2026-05-01) — ✅ APPROVED"
  echo "$COMMENTS" | grep -q "Triaged by\|Re-triaged by"

  # An untriaged issue matches neither marker
  ! echo "just a human comment" | grep -q "Triaged by\|Re-triaged by"
}

# bats test_tags=fast
@test "triage: re-triage dry-run reviews already-triaged issues without writes" {
  export MOCK_CURL_OUTPUT='{"candidates":[{"content":{"parts":[{"text":"VERDICT: SKIP\nCONFIDENCE: 9\nREASON: deferred until post-GA\nCOMPLEXITY: small\nSUGGESTED_PRIORITY: 4"}]}}]}'
  run bash "$TRIAGE" --re-triage --dry-run
  [ "$status" -eq 0 ]
  # Re-triage sweep header appears
  [[ "$output" == *"re-triage sweep"* ]]
  if [ -f "$TEST_TMPDIR/mock_calls/linear" ]; then
    ! grep -q "comment add" "$TEST_TMPDIR/mock_calls/linear"
  fi
}
