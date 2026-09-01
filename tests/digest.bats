#!/usr/bin/env bats
# Tests for scripts/digest.sh

load test_helper

DIGEST="$PILOT_DIR/scripts/digest.sh"

# bats test_tags=fast
@test "digest: dry-run prints to stdout without posting" {
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  # Should contain project names
  [[ "$output" == *"Lift"* ]] || return 1
  [[ "$output" == *"Issue Digest"* ]] || return 1
  # Should NOT have called curl
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}

# bats test_tags=fast
@test "digest: count_lines function counts issue IDs" {
  # Simulate the count_lines function (matches digest.sh's implementation)
  count_lines() {
    local c
    c=$(echo "$1" | grep -c "${LINEAR_TEAM}-" 2>/dev/null) || true
    echo "${c:-0}"
  }
  input="TEST-100  P2  Unstarted  Fix thing
TEST-101  P3  Backlog    Add thing"
  result=$(count_lines "$input")
  [ "$result" = "2" ]

  empty_result=$(count_lines "No issues found")
  [ "$empty_result" = "0" ]
}

# bats test_tags=fast
@test "digest: warns when webhook not set" {
  export SLACK_WEBHOOK_DAILY_REVIEW=""
  run bash "$DIGEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not set"* ]] || return 1
}

# ── Blockers section (standup: what is waiting on a human) ───────────────────

# bats test_tags=fast
@test "digest: surfaces needs-your-call PRs from the cleanup snapshot" {
  printf 'TEST-42\nTEST-77\n' > "$OUTPUT_DIR/lift-needs-decision.txt"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Needs your call"* ]] || return 1
  [[ "$output" == *"TEST-42"* ]] || return 1
  [[ "$output" == *"TEST-77"* ]] || return 1
}

# bats test_tags=fast
@test "digest: omits needs-your-call section when the snapshot is empty or missing" {
  rm -f "$OUTPUT_DIR/lift-needs-decision.txt"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Needs your call"* ]] || return 1

  : > "$OUTPUT_DIR/lift-needs-decision.txt"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Needs your call"* ]] || return 1
}

# ── Pilot repo defect queue (issues no agent works) ──────────────────────────

# bats test_tags=fast
@test "digest: surfaces open Pilot-repo issues" {
  # gh stub: the digest's only gh call is the pilot-repo issue list; --jq is
  # applied by real gh, so the stub emits the post-jq formatted lines.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
case "$*" in
  *"issue list"*"--repo aschung212/pilot"*|*"--repo aschung212/pilot"*"issue list"*)
    printf '  • <https://github.com/aschung212/pilot/issues/28|pilot#28>: Discovery re-files shipped issues\n'
    ;;
  *) echo "" ;;
esac
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pilot pipeline"* ]] || return 1
  [[ "$output" == *"pilot#28"* ]] || return 1
}

# bats test_tags=fast
@test "digest: omits Pilot-repo section when its queue is empty" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
echo ""
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pilot pipeline"* ]] || return 1
}

# bats test_tags=fast
@test "digest: survives gh failure on the Pilot-repo query" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
echo "gh: auth error" >&2
exit 1
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  run bash "$DIGEST" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue Digest"* ]] || return 1
  [[ "$output" != *"Pilot pipeline"* ]] || return 1
}
