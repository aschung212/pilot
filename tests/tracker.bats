#!/usr/bin/env bats
# Tests for adapters/tracker.sh (dual-backend: GitHub for Lift, Linear for others)

load test_helper

TRACKER="$PILOT_DIR/adapters/tracker.sh"

# ── GitHub backend (LIFT- prefix) ──────────────────────────────────────────

# bats test_tags=fast
@test "tracker: list routes LIFT issues to gh CLI" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" list backlog unstarted
  [ "$status" -eq 0 ]
  grep -q "issue list" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: list pickable runs an open-state exclusion query" {
  # The "pickable" pseudo-state must hit `gh issue list --state open` (no
  # state:* label filter) and pass the exclusion logic in --jq. If a future
  # refactor regresses to a label-based inclusion query, every architect-
  # created issue (which lacks state:unstarted due to a separate labeling
  # bug) silently drops out of the picking pool. Lock the contract here.
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" list pickable
  [ "$status" -eq 0 ]
  grep -q "issue list" "$TEST_TMPDIR/mock_calls/gh"
  grep -q -- "--state open" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q -- "--label state:unstarted" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q -- "--label state:pickable" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: list triageable runs an open-state exclusion query" {
  # Parallel to "pickable" but the triage scope: every open issue that is not
  # already in flight (state:started), blocked, or canceled. Includes
  # state:triage, state:backlog, state:unstarted, and unlabeled issues. Without
  # this, manually-created issues (no state label) sit forever — #216, #358,
  # and #434 were ignored for 2-3 weeks under the prior `list backlog unstarted`
  # inclusion query. Lock the contract.
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" list triageable
  [ "$status" -eq 0 ]
  grep -q "issue list" "$TEST_TMPDIR/mock_calls/gh"
  grep -q -- "--state open" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q -- "--label state:backlog" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q -- "--label state:unstarted" "$TEST_TMPDIR/mock_calls/gh"
  ! grep -q -- "--label state:triageable" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: view routes LIFT ID to gh CLI" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" view LIFT-100
  [ "$status" -eq 0 ]
  grep -q "issue view" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: create routes to gh when TRACKER_ADAPTER=github" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" create "Fix the bug" 2 --state unstarted --description "A bug fix"
  [ "$status" -eq 0 ]
  grep -q "issue create" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: update routes LIFT ID to gh CLI" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" update LIFT-100 --state completed --priority 1
  [ "$status" -eq 0 ]
  grep -q "issue edit" "$TEST_TMPDIR/mock_calls/gh"
}

# bats test_tags=fast
@test "tracker: issue-url returns GitHub URL for LIFT IDs" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" issue-url LIFT-100
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/test/repo/issues/100"* ]]
}

# bats test_tags=fast
@test "tracker: board-url returns GitHub issues URL" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" board-url
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/test/repo/issues"* ]]
}

# ── Linear backend (non-LIFT prefix) ──────────────────────────────────────

# bats test_tags=fast
@test "tracker: view routes non-LIFT ID to linear CLI" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  run bash "$TRACKER" view MAS-100
  [ "$status" -eq 0 ]
  grep -q "issue view MAS-100" "$TEST_TMPDIR/mock_calls/linear"
}

# bats test_tags=fast
@test "tracker: create routes to linear when TRACKER_ADAPTER=linear" {
  export TRACKER_ADAPTER="linear"
  run bash "$TRACKER" create "Fix the bug" 2 --state unstarted --description "A bug fix"
  [ "$status" -eq 0 ]
  grep -q -- '--title Fix the bug' "$TEST_TMPDIR/mock_calls/linear"
  grep -q -- "--priority 2" "$TEST_TMPDIR/mock_calls/linear"
}

# bats test_tags=fast
@test "tracker: comment-add routes by ID prefix" {
  export TRACKER_ADAPTER="github"
  export GITHUB_ISSUES_REPO="test/repo"
  export ISSUE_PREFIX="LIFT"
  # Non-LIFT ID should route to Linear
  run bash "$TRACKER" comment-add MAS-100 "This is a comment"
  [ "$status" -eq 0 ]
  grep -q "issue comment add MAS-100" "$TEST_TMPDIR/mock_calls/linear"
}

# ── Error handling ─────────────────────────────────────────────────────────

# bats test_tags=fast
@test "tracker: unknown command exits with error" {
  run bash "$TRACKER" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown tracker command"* ]]
}
