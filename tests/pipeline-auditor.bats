#!/usr/bin/env bats
# Tests for scripts/pipeline-auditor.sh and lib/auditor-utils.sh

load test_helper

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"

  export _PILOT_TEST_MODE=1
  export PROJECT_NAME="TestProject"
  export GITHUB_REPO="test/repo"
  export ISSUE_PREFIX="TEST"

  # Stub gh: list returns empty, view returns minimal — keeps live calls away.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
case "$*" in
  *"pr list"*)    echo "[]" ;;
  *"issue list"*) echo "[]" ;;
  *"issue view"*) echo "{}" ;;
  *)              echo "" ;;
esac
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Pre-stage fixture PR JSONs so the auditor doesn't try a live gh call.
  echo "[]" > "$OUTPUT_DIR/.pilot-audit-prs-open.json"
  echo "[]" > "$OUTPUT_DIR/.pilot-audit-prs-recent.json"

  # Source lib for unit-testing helpers
  source "$PILOT_DIR/lib/auditor-utils.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ── Smoke tests ───────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: smoke — script parses without syntax errors" {
  run bash -n "$PILOT_DIR/scripts/pipeline-auditor.sh"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "auditor: smoke — lib parses without syntax errors" {
  run bash -n "$PILOT_DIR/lib/auditor-utils.sh"
  [ "$status" -eq 0 ]
}

# ── CLI argument parsing ──────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: --days rejects non-integer value" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --days abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --days value"* ]]
}

# bats test_tags=fast
@test "auditor: --days rejects zero" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --days 0
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "auditor: --days rejects negative" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --days -3
  [ "$status" -ne 0 ]
}

# ── Dry-run mode ──────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: dry-run completes without error on empty data" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --dry-run --days 7
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "auditor: dry-run writes audit report to OUTPUT_DIR" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --dry-run --days 7
  [ "$status" -eq 0 ]
  DATE=$(date +%Y-%m-%d)
  [ -f "$OUTPUT_DIR/pilot-audit-${DATE}.md" ]
}

# bats test_tags=fast
@test "auditor: dry-run initializes audit-history CSV" {
  run bash "$PILOT_DIR/scripts/pipeline-auditor.sh" --dry-run --days 7
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_DIR/pilot-audit-history.csv" ]
  HEADER=$(head -1 "$OUTPUT_DIR/pilot-audit-history.csv")
  [ "$HEADER" = "date,finding_id,severity,metric,metric_value,prior_value,delta,action_taken" ]
}

# ── classify_severity: per-metric thresholds ──────────────────────────────────

# bats test_tags=fast
@test "auditor: classify_severity marker_emission_pct — large drop (30pp) is P1" {
  # Threshold: P1 at >=25 percentage points dropped
  result=$(classify_severity "marker_emission_pct" "30")
  [ "$result" = "P1" ]
}

# bats test_tags=fast
@test "auditor: classify_severity marker_emission_pct — tiny change (5pp) is P3" {
  result=$(classify_severity "marker_emission_pct" "5")
  [ "$result" = "P3" ]
}

# bats test_tags=fast
@test "auditor: classify_severity num_turns_one_pct — strong spike (60%) is P1" {
  # Threshold: P1 at >=50% of runs delegating
  result=$(classify_severity "num_turns_one_pct" "60")
  [ "$result" = "P1" ]
}

# bats test_tags=fast
@test "auditor: classify_severity duplicate_prs — multiple incidents is P1" {
  result=$(classify_severity "duplicate_prs" "5")
  [ "$result" = "P1" ]
}

# bats test_tags=fast
@test "auditor: classify_severity failed_pr_retries — 3+ nights is P1" {
  result=$(classify_severity "failed_pr_retries" "3")
  [ "$result" = "P1" ]
}

# bats test_tags=fast
@test "auditor: classify_severity unknown metric defaults to P3" {
  result=$(classify_severity "made_up_metric" "100")
  [ "$result" = "P3" ]
}

# ── severity_emoji ────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: severity_emoji — P1 maps to siren" {
  result=$(severity_emoji "P1")
  [ "$result" = "🚨" ]
}

# bats test_tags=fast
@test "auditor: severity_emoji — P2 maps to warning" {
  result=$(severity_emoji "P2")
  [ "$result" = "⚠️" ]
}

# bats test_tags=fast
@test "auditor: severity_emoji — P3 maps to info" {
  result=$(severity_emoji "P3")
  [ "$result" = "ℹ️" ]
}

# bats test_tags=fast
@test "auditor: severity_emoji — unknown maps to question" {
  result=$(severity_emoji "garbage")
  [ "$result" = "❓" ]
}

# ── audit_history CSV ─────────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: audit_history_header is the canonical schema" {
  result=$(audit_history_header)
  [ "$result" = "date,finding_id,severity,metric,metric_value,prior_value,delta,action_taken" ]
}

# bats test_tags=fast
@test "auditor: ensure_audit_history creates file with header when missing" {
  csv="$TEST_TMPDIR/audit.csv"
  ensure_audit_history "$csv"
  [ -f "$csv" ]
  HEADER=$(head -1 "$csv")
  [ "$HEADER" = "date,finding_id,severity,metric,metric_value,prior_value,delta,action_taken" ]
}

# bats test_tags=fast
@test "auditor: ensure_audit_history is idempotent — does not wipe existing data" {
  csv="$TEST_TMPDIR/audit.csv"
  ensure_audit_history "$csv"
  append_audit_history "$csv" "2026-04-29" "f1" "P1" "marker_emission_collapse" "0.0" "0.75" "0.75" "drift detected"
  ensure_audit_history "$csv"
  ROW_COUNT=$(tail -n +2 "$csv" | wc -l | tr -d ' ')
  [ "$ROW_COUNT" -eq 1 ]
}

# bats test_tags=fast
@test "auditor: append_audit_history writes a well-formed row" {
  csv="$TEST_TMPDIR/audit.csv"
  append_audit_history "$csv" "2026-04-30" "f42" "P2" "stall_rate" "0.4" "0.2" "0.2" "watch next week"
  ROW=$(tail -1 "$csv")
  [[ "$ROW" == "2026-04-30,f42,P2,stall_rate,0.4,0.2,0.2,\"watch next week\"" ]]
}

# bats test_tags=fast
@test "auditor: append_audit_history quote-escapes embedded commas" {
  csv="$TEST_TMPDIR/audit.csv"
  append_audit_history "$csv" "2026-04-30" "f99" "P1" "duplicate_prs" "5" "0" "5" "found 5 dups, propose dedup fix"
  ROW=$(tail -1 "$csv")
  # The action field must be quoted so the embedded comma doesn't split fields.
  [[ "$ROW" == *'"found 5 dups, propose dedup fix"' ]]
  # And the row must still have exactly 8 logical fields when parsed by Python csv.
  COL_COUNT=$(tail -1 "$csv" | python3 -c "import csv,sys; print(len(next(csv.reader(sys.stdin))))")
  [ "$COL_COUNT" -eq 8 ]
}

# bats test_tags=fast
@test "auditor: append_audit_history doubles embedded double-quotes (CSV convention)" {
  csv="$TEST_TMPDIR/audit.csv"
  append_audit_history "$csv" "2026-04-30" "f7" "P3" "marker_emission_collapse" "0.5" "0.6" "0.1" 'said "this looks bad"'
  COL_COUNT=$(tail -1 "$csv" | python3 -c "import csv,sys; print(len(next(csv.reader(sys.stdin))))")
  [ "$COL_COUNT" -eq 8 ]
  # Recover the action field via csv parser and confirm it round-trips.
  ACTION=$(tail -1 "$csv" | python3 -c "import csv,sys; print(next(csv.reader(sys.stdin))[-1])")
  [ "$ACTION" = 'said "this looks bad"' ]
}

# ── audit_window_dates ────────────────────────────────────────────────────────

# bats test_tags=fast
@test "auditor: audit_window_dates returns N distinct dates" {
  result=$(audit_window_dates 7)
  COUNT=$(echo "$result" | sort -u | wc -l | tr -d ' ')
  [ "$COUNT" -eq 7 ]
}

# bats test_tags=fast
@test "auditor: audit_window_dates dates are YYYY-MM-DD" {
  result=$(audit_window_dates 3)
  echo "$result" | while read -r d; do
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  done
}

# ── csv_safe_field (numeric-field sanitizer for reading old CSVs) ─────────────

# bats test_tags=fast
@test "auditor: csv_safe_field passes integer values through" {
  result=$(csv_safe_field "42")
  [ "$result" = "42" ]
}

# bats test_tags=fast
@test "auditor: csv_safe_field passes float values through" {
  result=$(csv_safe_field "12.5")
  [ "$result" = "12.5" ]
}

# bats test_tags=fast
@test "auditor: csv_safe_field returns default for non-numeric input" {
  result=$(csv_safe_field "hello" "0")
  [ "$result" = "0" ]
}

# bats test_tags=fast
@test "auditor: csv_safe_field returns default for empty input" {
  result=$(csv_safe_field "" "7")
  [ "$result" = "7" ]
}

# bats test_tags=fast
@test "auditor: csv_safe_field default is 0 when omitted" {
  result=$(csv_safe_field "")
  [ "$result" = "0" ]
}

# ── find_existing_audit_issue (with gh stub) ──────────────────────────────────

# bats test_tags=fast
@test "auditor: find_existing_audit_issue returns empty when gh has no matches" {
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
echo "[]"
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  result=$(find_existing_audit_issue "marker_emission")
  [ -z "$result" ]
}

# bats test_tags=fast
@test "auditor: find_existing_audit_issue returns issue number when gh matches" {
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
# Pretend an open issue exists with #42
case "$*" in
  *"issue list"*)
    echo '[{"number":42,"title":"marker_emission_collapse drift"}]'
    ;;
  *) echo "[]" ;;
esac
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  result=$(find_existing_audit_issue "marker_emission")
  [ "$result" = "42" ]
}
