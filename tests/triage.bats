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
  [[ "$guidance" == "RESCOPE is available" ]] || return 1

  # Large backlog — prefer enhance
  BACKLOG_COUNT=25
  if [ "$BACKLOG_COUNT" -gt 20 ]; then
    guidance="Prefer ENHANCE"
  else
    guidance="RESCOPE is available"
  fi
  [[ "$guidance" == "Prefer ENHANCE" ]] || return 1
}

# bats test_tags=fast
# ── Unparseable verdict => defer, never FLAG ─────────────────────────────────
# Regression guard for 2026-08-29. triage.sh used to end verdict parsing with
# `VERDICT=${VERDICT:-FLAG}`, so a model error and a genuine product question
# were indistinguishable: Gemini 503'd on 7 of 23 issues, Sonnet then hit
# "Error: Reached max turns (6)" on 4 of them, and LIFT-1223/1179/1098/1096 were
# each given a content-free NEEDS INPUT comment and parked on state:needs-input —
# a label that BOTH `list triageable` and `list pickable` exclude. A transient
# API blip therefore removed four issues from the pipeline until a human
# noticed. The issue must now be left completely untouched instead.
#
# This drives the real script rather than re-implementing its parsing inline
# (see CLAUDE.md, "Tests that re-implement the logic they test").
@test "triage: an unparseable model reply defers the issue instead of flagging it" {
  export _PILOT_TEST_MODE=1
  export ISSUE_PREFIX="TEST"
  export GITHUB_ISSUES_REPO="test/repo"
  export GEMINI_API_KEY="test-key"
  export TRIAGE_RETRY_DELAY=0
  # Disable both pre-steps: this test asserts that the issue *under triage* is
  # left untouched, and a pre-step's own `gh issue edit` lands in the same mock
  # call log, which would mask (or fake) that assertion.
  export PR_RECONCILE_ENABLED=0
  export MANUAL_CLAIM_ENABLED=0

  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/mock_calls"
  cat > "$TEST_TMPDIR/bin/gh" <<SCRIPT
#!/bin/bash
echo "\$@" >> "$TEST_TMPDIR/mock_calls/gh"
case "\$*" in
  *"-q length"*)  echo 1 ;;
  *"issue list"*) echo "TEST-42 A broken thing" ;;
  *"pr list"*)    ;;
  *"issue view"*) echo "# TEST-42: A broken thing" ;;
  *)              ;;
esac
SCRIPT
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Gemini 503s on the first call AND the retry; Sonnet then hits its turn cap.
  export MOCK_CURL_OUTPUT='{"error":{"code":503,"message":"high demand"}}'
  export MOCK_CURL_HTTP_CODE=503
  export MOCK_CLAUDE_OUTPUT='Error: Reached max turns (12)'

  run bash "$TRIAGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEFERRED"* ]] || return 1
  [[ "$output" == *"Deferred (no verdict): 1"* ]] || return 1
  [[ "$output" == *"TEST-42"* ]] || return 1

  # The whole point: the issue is left untouched. No comment, no state label,
  # no priority — nothing that would gate it behind a human or hide it from
  # the next run's `list triageable`.
  ! grep -q "issue comment" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q "issue edit" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "triage: a transient Gemini failure is retried before the Sonnet fallback" {
  run grep -B6 -A4 'no verdict from Gemini — retrying once' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  # The retry must re-call the adapter, and must sit before the Sonnet fallback.
  [[ "$output" == *'AI_RESEARCH" prompt'* ]] || return 1
  run grep -n 'retrying once\|falling back to Claude Sonnet' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | head -1)" == *"retrying once"* ]] || return 1
}

# ── metrics CSV schema ───────────────────────────────────────────────────────
# The header is only written when the file does not exist, so it froze at the
# original 7 columns while the row format grew twice (`rescoped` in 97c06d5,
# `failed` on 2026-08-29). The live file had a 7-column header over 8-column
# rows: csv.DictReader buckets the overflow under the None key and
# `row["model"]` returns the flagged count. The migration must normalise both.
@test "triage: metrics CSV migration normalises the header and every legacy row" {
  csv="$TEST_TMPDIR/lift-triage-metrics.csv"
  # Exactly the shape found in production on 2026-08-29.
  cat > "$csv" <<'CSV'
date,total,approved,enhanced,skipped,flagged,model
2026-04-02,27,7,1,0,2,gemini-2.5-flash
2026-04-05,45,6,0,0,0,4,gemini-2.5-flash
2026-08-29,23,11,1,0,6,5,claude-sonnet
CSV

  # Run the migration exactly as triage.sh does.
  schema=$(grep -m1 '^_CSV_SCHEMA=' "$PILOT_DIR/scripts/triage.sh" | sed 's/^_CSV_SCHEMA="//; s/"$//')
  [ "$schema" = "date,total,approved,enhanced,rescoped,skipped,flagged,model,failed" ]
  awk -F, -v schema="$schema" '
    NR==1        { print schema; next }
    NF==0        { next }
    NF==7        { print $1","$2","$3","$4",0,"$5","$6","$7",0"; next }
    NF==8        { print $0 ",0"; next }
                 { print }
  ' "$csv" > "$csv.tmp" && mv "$csv.tmp" "$csv"

  # Every line must now carry exactly 9 fields — header included.
  run awk -F, '{print NF}' "$csv"
  [ "$status" -eq 0 ]
  for n in $output; do [ "$n" -eq 9 ]; done

  # The pre-RESCOPE row gets rescoped=0 inserted in the right place: its model
  # must still read as a model, not as a stray count.
  run awk -F, 'NR==2 {print $5"|"$8"|"$9}' "$csv"
  [ "$output" = "0|gemini-2.5-flash|0" ]
  # The 8-column row keeps its own rescoped value and gains failed=0.
  run awk -F, 'NR==3 {print $5"|"$8"|"$9}' "$csv"
  [ "$output" = "0|gemini-2.5-flash|0" ]

  # Idempotent: a second pass changes nothing.
  cp "$csv" "$csv.before"
  awk -F, -v schema="$schema" '
    NR==1        { print schema; next }
    NF==0        { next }
    NF==7        { print $1","$2","$3","$4",0,"$5","$6","$7",0"; next }
    NF==8        { print $0 ",0"; next }
                 { print }
  ' "$csv" > "$csv.tmp" && mv "$csv.tmp" "$csv"
  run diff "$csv.before" "$csv"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "triage: metrics row and header have the same column count" {
  # The two must be written from the same schema or the file goes ragged again.
  header=$(grep -m1 '^_CSV_SCHEMA=' "$PILOT_DIR/scripts/triage.sh" | sed 's/^_CSV_SCHEMA="//; s/"$//')
  row=$(grep -m1 'echo "\$DATE,\$UNTRIAGED_COUNT' "$PILOT_DIR/scripts/triage.sh")
  h=$(echo "$header" | awk -F, '{print NF}')
  r=$(echo "$row" | sed 's/.*echo "//; s/".*//' | awk -F, '{print NF}')
  [ "$h" -eq "$r" ]
}

# bats test_tags=fast
@test "triage: verdict parsing has no FLAG fallback default" {
  # `VERDICT=${VERDICT:-FLAG}` is the exact line that manufactured four false
  # human gates on 2026-08-29. It must not come back.
  #
  # Anchored to a statement at line start so the prose in triage.sh that
  # documents the old line does not match. grep exit 1 == no match; -c is
  # avoided because it emits trailing whitespace that breaks `[ ]` compares.
  run grep -nE '^[[:space:]]*VERDICT=\$\{VERDICT:-FLAG\}' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 1 ]
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
  [[ "$flag_q" == "Should the negative-delta arrow keep red"* ]] || return 1
  [[ "$rec" == "Option 1 —"* ]] || return 1
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
  [[ "$output" == *"re-triage sweep"* ]] || return 1
  if [ -f "$TEST_TMPDIR/mock_calls/linear" ]; then
    ! grep -q "comment add" "$TEST_TMPDIR/mock_calls/linear"
  fi
}

# ── In-flight deferral (issues that already have an open PR) ─────────────────
# Regression cover for the 2026-07-28 LIFT-783 → LIFT-1039 duplicate build.
# Triage was the only stage that never consulted pull requests, so an issue
# whose PR was open but whose state label still read state:unstarted looked
# like fresh backlog — and a RESCOPE verdict forked live work into a new issue
# number that every issue-identity-keyed dedupe then waved through.
#
# These pin the matching idiom used in triage.sh (same style as the verdict
# parsing tests above): PR titles → issue refs → whole-line match. The two
# failure modes they guard are (a) dropping the `#N` → `LIFT-N` normalization,
# which would miss manually-titled PRs, and (b) losing the whole-line anchor,
# which would make LIFT-96 match LIFT-966.

_refs_from_titles() {
  grep -oE "(${ISSUE_PREFIX}-|#)[0-9]+" | sed -E "s/^#/${ISSUE_PREFIX}-/" | sort -u
}

# bats test_tags=fast
@test "triage: in-flight refs extracted from both LIFT-N and #N PR titles" {
  export ISSUE_PREFIX=LIFT
  run _refs_from_titles <<< "$(printf '%s\n' \
    'feat(LIFT-1039): sync plateCountMode' \
    'feat: add superset grouping for exercises (#616)' \
    'test: unrelated cleanup with no ref')"
  [ "${lines[0]}" = "LIFT-1039" ]
  [ "${lines[1]}" = "LIFT-616" ]
  [ "${#lines[@]}" -eq 2 ]
}

# bats test_tags=fast
@test "triage: an issue with an open PR is deferred, others stay triageable" {
  export ISSUE_PREFIX=LIFT
  IN_FLIGHT_IDS=$(printf "%s\n" "feat: superset grouping (#616)" "fix(LIFT-751): rest timer" | _refs_from_titles)
  ISSUE_IDS="LIFT-616 LIFT-580 LIFT-66"
  deferred=""; kept=""
  for i in $ISSUE_IDS; do
    if echo "$IN_FLIGHT_IDS" | grep -qx "$i"; then deferred+="$i "; else kept+="$i "; fi
  done
  [ "$(echo "$deferred" | xargs)" = "LIFT-616" ]
  [ "$(echo "$kept" | xargs)" = "LIFT-580 LIFT-66" ]
}

# bats test_tags=fast
@test "triage: deferral anchors whole lines so LIFT-96 does not match LIFT-966" {
  export ISSUE_PREFIX=LIFT
  IN_FLIGHT_IDS=$(printf "%s\n" "feat(LIFT-966): something" | _refs_from_titles)
  run grep -qx "LIFT-96" <<< "LIFT-966"
  [ "$status" -ne 0 ]
  echo "$IN_FLIGHT_IDS" | grep -qx "LIFT-966"
}

# bats test_tags=fast
@test "triage: deferral fails open when no PRs are returned" {
  export ISSUE_PREFIX=LIFT
  IN_FLIGHT_IDS=""
  ISSUE_IDS="LIFT-616 LIFT-580"
  deferred=""; kept=""
  if [ -n "$IN_FLIGHT_IDS" ]; then
    for i in $ISSUE_IDS; do
      if echo "$IN_FLIGHT_IDS" | grep -qx "$i"; then deferred+="$i "; else kept+="$i "; fi
    done
  else
    kept="$ISSUE_IDS"
  fi
  # Nothing deferred: an unavailable PR list must never silently drop issues.
  [ -z "$deferred" ]
  [ "$(echo "$kept" | xargs)" = "LIFT-616 LIFT-580" ]
}

# ── Acceptance criteria (definition of done) ─────────────────────────────────

# bats test_tags=fast
@test "triage: ACCEPTANCE_CRITERIA extracted from triage output" {
  result="VERDICT: APPROVE
CONFIDENCE: 8
IMPLEMENTATION_PLAN: do the thing
ACCEPTANCE_CRITERIA: criterion one | criterion two
COMPLEXITY: small"
  acceptance=$(echo "$result" | grep -oE 'ACCEPTANCE_CRITERIA: .*' | head -1 | sed 's/ACCEPTANCE_CRITERIA: //')
  [ "$acceptance" = "criterion one | criterion two" ]
}

# bats test_tags=fast
@test "triage: acceptance criteria pipe-split into checkbox bullets" {
  acceptance="deleting the last set removes the card | undo toast restores it"
  bullets=$(echo "$acceptance" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/- [ ] /')
  [ "$(echo "$bullets" | wc -l | tr -d ' ')" -eq 2 ]
  echo "$bullets" | grep -q "^- \[ \] deleting the last set removes the card$"
  echo "$bullets" | grep -q "^- \[ \] undo toast restores it$"
}

# bats test_tags=fast
@test "triage: prompt and comments carry the acceptance-criteria contract" {
  TRIAGE_SCRIPT="$PILOT_DIR/scripts/triage.sh"
  # Prompt asks for the field on APPROVE/ENHANCE
  grep -q "ACCEPTANCE_CRITERIA: (if APPROVE/ENHANCE)" "$TRIAGE_SCRIPT"
  # Both comment templates render it as a definition-of-done checklist
  [ "$(grep -c 'Acceptance criteria.*definition of done' "$TRIAGE_SCRIPT")" -ge 2 ]
}

# ── PR-close reconcile pre-step (added 2026-08-28) ───────────────────────────
# Reconcile runs BEFORE `list triageable` so issues it releases from
# state:started are triaged in the same run. It is a pre-step, not a gate:
# a failure must never stop triage.

@test "triage: reconcile runs before the triageable query" {
  run grep -n "pr-close-reconcile.sh\|list triageable" "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  # First match must be the reconcile wiring, not the triageable query.
  first=$(echo "$output" | head -1)
  [[ "$first" == *"pr-close-reconcile"* ]] || return 1
}

@test "triage: reconcile failure does not abort triage" {
  # The invocation must swallow a non-zero exit (|| { ... }) rather than
  # letting set -e / a bare call kill the run.
  run grep -A4 'RECONCILE_OUT=\$(bash "\$RECONCILE"' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"continuing with triage"* ]] || return 1
}

@test "triage: --dry-run propagates to the reconcile sub-step" {
  run grep -B2 -A2 'RECONCILE_MODE="--dry-run"' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'DRY_RUN" = "--dry-run"'* ]] || return 1
}

@test "triage: reconcile honours the PR_RECONCILE_ENABLED kill switch" {
  run grep -n 'PR_RECONCILE_ENABLED' "$PILOT_DIR/scripts/triage.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *':-1'* ]] || return 1
}

# ── Model label truthfulness ─────────────────────────────────────────────────
# $TRIAGE_MODEL is a reporting label: it lands in every issue comment and in
# the metrics CSV. It must name the model that actually ran. It did not — the
# adapter call omitted --model, so triage silently rode $AI_RESEARCH_MODEL
# (which discovery tunes) while every comment claimed gemini-2.5-flash.
#
# Drives the REAL triage.sh in a copied tree whose adapters are stubs, so the
# assertion is on the argv triage actually hands the adapter.
_triage_tree() {
  # triage.bats overrides test_helper's setup(), so export what triage.sh reads.
  export ISSUE_PREFIX="TEST"
  export GITHUB_ISSUES_REPO="test/repo"
  export GITHUB_REPO="test/repo"
  FAKE="$TEST_TMPDIR/fake"
  mkdir -p "$FAKE/adapters"
  cp -R "$PILOT_DIR/scripts" "$FAKE/scripts"
  cp -R "$PILOT_DIR/lib" "$FAKE/lib"

  # Stubs record their argv ($TEST_TMPDIR is exported by bats).
  cat > "$FAKE/adapters/tracker.sh" << 'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TMPDIR/tracker_argv"
case "${1:-}" in
  list) [ "${2:-}" = "triageable" ] && echo "TEST-1: A sample issue" ;;
  view) echo "# TEST-1: A sample issue"; echo "Body text." ;;
  issue-url) echo "https://github.com/test/repo/issues/1" ;;
  board-url) echo "https://github.com/test/repo/issues" ;;
esac
exit 0
EOF

  cat > "$FAKE/adapters/ai-research.sh" << 'EOF'
#!/bin/bash
echo "$@" >> "$TEST_TMPDIR/ai_research_argv"
printf 'VERDICT: SKIP\nCONFIDENCE: 8\nREASON: stub\n'
EOF

  printf '#!/bin/bash\nexit 0\n' > "$FAKE/adapters/notify.sh"
  chmod +x "$FAKE/adapters/"*.sh
}

# bats test_tags=fast
@test "triage: pins its own model and passes it to the research adapter" {
  _triage_tree
  # Discovery's model is deliberately different — triage must ignore it.
  export AI_RESEARCH_MODEL="gemini-3.6-flash"
  run bash "$FAKE/scripts/triage.sh" --dry-run
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/ai_research_argv" ]
  grep -q -- "--model gemini-2.5-flash" "$TEST_TMPDIR/ai_research_argv"
  ! grep -q -- "gemini-3.6-flash" "$TEST_TMPDIR/ai_research_argv"
  # Grounding stays off — triage reasons over the prompt, not the web.
  grep -q -- "--no-grounding" "$TEST_TMPDIR/ai_research_argv"
}

# bats test_tags=fast
@test "triage: the reported label names the model that actually ran" {
  # A live run (not --dry-run) — the label only reaches its two reporting
  # surfaces, the issue comment and the metrics CSV, outside dry-run. Both must
  # agree with the argv the adapter was called with.
  _triage_tree
  export AI_TRIAGE_MODEL="gemini-3.6-flash"
  export AI_RESEARCH_MODEL="gemini-2.5-flash"
  run bash "$FAKE/scripts/triage.sh"
  [ "$status" -eq 0 ]
  grep -q -- "--model gemini-3.6-flash" "$TEST_TMPDIR/ai_research_argv"
  # The issue comment credits the model that ran…
  grep -q "gemini-3.6-flash" "$TEST_TMPDIR/tracker_argv"
  ! grep -q "gemini-2.5-flash" "$TEST_TMPDIR/tracker_argv"
  # …and so does the model column of the metrics CSV. Locate that column by
  # NAME: this assertion was anchored to end-of-line until 2026-09-01 and broke
  # the moment `failed` was appended after `model` in the schema.
  awk -F, 'NR==1 { for (i=1; i<=NF; i++) if ($i=="model") c=i; next }
           c && $c=="gemini-3.6-flash" { found=1 }
           END { exit !found }' "$OUTPUT_DIR/lift-triage-metrics.csv"
}
