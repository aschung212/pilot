#!/usr/bin/env bats
# Tests for scripts/pr-close-reconcile.sh
#
# This script CLOSES ISSUES, so the tests are weighted toward proving it
# refuses to act on weak evidence. The trust model exists because real PR
# metadata in the Lift repo is unreliable: PR #1065 is titled "superset
# grouping (#616)" while its body says "Issue: LIFT-1064" (an unrelated
# manifest issue). Trusting either source alone closes the wrong issue.

load test_helper

RECONCILE="$PILOT_DIR/scripts/pr-close-reconcile.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME" "$TEST_TMPDIR/bin"
  export _PILOT_TEST_MODE=1
  export PILOT_DIR="$PILOT_DIR"
  export GITHUB_ISSUES_REPO="test/repo"
  export SLACK_BOT_TOKEN="" SLACK_WEBHOOK_URL=""

  export PR_FIXTURE="$TEST_TMPDIR/prs.json"
  export ACTION_LOG="$TEST_TMPDIR/actions.log"
  : > "$ACTION_LOG"

  # gh shim: serves the fixture for `pr list`, reports every issue OPEN with
  # no prior marker comment, and records mutations instead of performing them.
  cat > "$TEST_TMPDIR/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "pr list")     cat "$PR_FIXTURE" ;;
  "issue view")  if printf '%s\n' "$@" | grep -q "state"; then echo "OPEN"; else echo ""; fi ;;
  "issue close") echo "CLOSE $3" >> "$ACTION_LOG" ;;
  "issue edit")  echo "EDIT $3" >> "$ACTION_LOG" ;;
  "issue comment") echo "COMMENT $3" >> "$ACTION_LOG" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Recent enough to always fall inside the default lookback window.
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

@test "closes the issue when title and body links agree and a verdict is present" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":900,"title":"feat(LIFT-500): a thing","body":"**Issue:** [LIFT-500](url)","mergedAt":null,"closedAt":"$(_now)",
  "comments":[{"author":{"login":"aschung212"},"body":"not wanted or needed"}]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"close #500"* ]]
  grep -q "CLOSE 500" "$ACTION_LOG"
}

@test "refuses to close when title and body links disagree (the PR #1065 case)" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":1065,"title":"feat: add superset/circuit grouping for exercises (#616)",
  "body":"**Issue:** [LIFT-1064](url)","mergedAt":null,"closedAt":"$(_now)",
  "comments":[{"author":{"login":"aschung212"},"body":"not wanted at this time"}]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"conflicting issue links"* ]]
  [[ "$output" == *"title=616"* ]]
  [[ "$output" == *"body=1064"* ]]
  # Nothing at all may be mutated on a conflicted link.
  [ ! -s "$ACTION_LOG" ]
}

@test "a single-source link resets to triage but never closes" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":1070,"title":"fix: prevent month overflow in calendar navigation",
  "body":"**Issue:** [LIFT-1064](url)","mergedAt":null,"closedAt":"$(_now)",
  "comments":[{"author":{"login":"aschung212"},"body":"not wanted or needed"}]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"triage #1064"* ]]
  [[ "$output" == *"too weak to close"* ]]
  grep -q "EDIT 1064" "$ACTION_LOG"
  ! grep -q "CLOSE" "$ACTION_LOG"
}

@test "an empty verdict does not collapse the title into the verdict field" {
  # Regression: with IFS=\$'\t', bash collapses consecutive tabs (tab is
  # whitespace), so an empty verdict shifted the PR title into VERDICT and the
  # issue was reported as rejected. The extractor uses \x1f for this reason.
  cat > "$PR_FIXTURE" <<JSON
[{"number":901,"title":"feat(LIFT-501): silent close","body":"**Issue:** [LIFT-501](url)",
  "mergedAt":null,"closedAt":"$(_now)","comments":[]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"triage #501"* ]]
  [[ "$output" == *"no stated verdict"* ]]
  ! grep -q "CLOSE" "$ACTION_LOG"
}

@test "merged PRs are ignored entirely" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":902,"title":"feat(LIFT-502): shipped","body":"**Issue:** [LIFT-502](url)",
  "mergedAt":"$(_now)","closedAt":"$(_now)",
  "comments":[{"author":{"login":"aschung212"},"body":"not wanted"}]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  [ ! -s "$ACTION_LOG" ]
}

@test "bot comments never count as a human verdict" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":903,"title":"feat(LIFT-503): a thing","body":"**Issue:** [LIFT-503](url)",
  "mergedAt":null,"closedAt":"$(_now)",
  "comments":[{"author":{"login":"github-actions"},"body":"stale build cache duplicate"}]}]
JSON
  run bash "$RECONCILE" --apply
  [ "$status" -eq 0 ]
  ! grep -q "CLOSE" "$ACTION_LOG"
}

@test "default invocation is a dry run and mutates nothing" {
  cat > "$PR_FIXTURE" <<JSON
[{"number":904,"title":"feat(LIFT-504): a thing","body":"**Issue:** [LIFT-504](url)",
  "mergedAt":null,"closedAt":"$(_now)",
  "comments":[{"author":{"login":"aschung212"},"body":"not wanted or needed"}]}]
JSON
  run bash "$RECONCILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ ! -s "$ACTION_LOG" ]
}

@test "rejects a non-numeric --since" {
  run bash "$RECONCILE" --since abc
  [ "$status" -ne 0 ]
}
