#!/usr/bin/env bats
# Tests for scripts/stale-pr-audit.sh
#
# The audit answers the question no issue-identity dedupe can: "does merging
# this PR still change anything?" These tests build a real fixture git repo
# with real migrations and drive the real script against it, so the detector
# itself is under test rather than a copy of its regex.

load test_helper

AUDIT="$PILOT_DIR/scripts/stale-pr-audit.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  export PILOT_DIR_OVERRIDE="$TEST_TMPDIR"
  mkdir -p "$OUTPUT_DIR" "$HOME" "$TEST_TMPDIR/bin"

  export PROJECT_NAME="TestProject"
  export GITHUB_ISSUES_REPO="testorg/TestRepo"
  export ISSUE_PREFIX="TEST"
  export DEFAULT_BRANCH="master"
  export SLACK_CHANNEL_AUTOMATION="C_TEST_AUTO"
  export SLACK_BOT_TOKEN=""
  export SLACK_WEBHOOK_URL=""
  export PATH="$TEST_TMPDIR/bin:$TEST_DIR/mocks:$PATH"

  # ── Fixture repo: master has one migration; branches add more ────────────
  export REPO_PATH="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_PATH/supabase/migrations"
  git -C "$REPO_PATH" init -q -b master
  git -C "$REPO_PATH" config user.email t@t.t
  git -C "$REPO_PATH" config user.name t
  echo "ALTER TABLE exercises ADD COLUMN IF NOT EXISTS plate_count_mode text;" \
    > "$REPO_PATH/supabase/migrations/20260727000000_add_plate_count_mode.sql"
  git -C "$REPO_PATH" add -A && git -C "$REPO_PATH" commit -qm "base"
  git -C "$REPO_PATH" update-ref refs/remotes/origin/master HEAD
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Write a gh mock returning a fixed open-PR list.
_mock_gh_prs() {
  cat > "$TEST_TMPDIR/bin/gh" <<EOF
#!/bin/bash
mkdir -p "\$TEST_TMPDIR/mock_calls"; echo "\$@" >> "\$TEST_TMPDIR/mock_calls/gh"
echo '$1'
EOF
  chmod +x "$TEST_TMPDIR/bin/gh"
}

# bats test_tags=fast
@test "stale-pr-audit: rejects an unknown argument" {
  run bash "$AUDIT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: fails when REPO_PATH is not a git repo" {
  export REPO_PATH="$TEST_TMPDIR/not-a-repo"
  mkdir -p "$REPO_PATH"
  _mock_gh_prs '[]'
  run bash "$AUDIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repo"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: flags a PR whose migration duplicates a master column" {
  # Branch adds the SAME column master already has — the PR #1041 shape.
  git -C "$REPO_PATH" checkout -qb dup-branch
  echo "alter table exercises add column if not exists plate_count_mode text;" \
    > "$REPO_PATH/supabase/migrations/20260728010000_add_plate_count_mode.sql"
  git -C "$REPO_PATH" add -A && git -C "$REPO_PATH" commit -qm "dup"
  git -C "$REPO_PATH" update-ref refs/remotes/origin/dup-branch HEAD
  git -C "$REPO_PATH" checkout -q master
  _mock_gh_prs '[{"number":1041,"title":"feat(TEST-1039): sync plateCountMode","headRefName":"dup-branch","createdAt":"2026-07-29T06:50:26Z"}]'

  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #1041 adds exercises.plate_count_mode (already in master)"* ]]
  [[ "$output" == *"finding(s)"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: reports clean when a PR adds a genuinely new column" {
  git -C "$REPO_PATH" checkout -qb new-branch
  echo "alter table exercises add column if not exists superset_id uuid;" \
    > "$REPO_PATH/supabase/migrations/20260801000000_add_superset_id.sql"
  git -C "$REPO_PATH" add -A && git -C "$REPO_PATH" commit -qm "new col"
  git -C "$REPO_PATH" update-ref refs/remotes/origin/new-branch HEAD
  git -C "$REPO_PATH" checkout -q master
  _mock_gh_prs '[{"number":2000,"title":"feat(TEST-1): supersets","headRefName":"new-branch","createdAt":"2026-08-01T00:00:00Z"}]'

  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No already-shipped work found"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: flags two open PRs adding the same column" {
  for b in a b; do
    git -C "$REPO_PATH" checkout -q master
    git -C "$REPO_PATH" checkout -qb "branch-$b"
    echo "alter table exercises add column if not exists notes text;" \
      > "$REPO_PATH/supabase/migrations/2026080100000${b}_add_notes.sql"
    git -C "$REPO_PATH" add -A && git -C "$REPO_PATH" commit -qm "notes $b"
    git -C "$REPO_PATH" update-ref "refs/remotes/origin/branch-$b" HEAD
  done
  git -C "$REPO_PATH" checkout -q master
  _mock_gh_prs '[{"number":10,"title":"feat(TEST-1): notes","headRefName":"branch-a","createdAt":"2026-08-01T00:00:00Z"},{"number":11,"title":"feat(TEST-2): notes again","headRefName":"branch-b","createdAt":"2026-08-02T00:00:00Z"}]'

  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exercises.notes added by PRs [10, 11]"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: flags a no-op PR whose merge changes nothing" {
  # Branch whose tip content is identical to master — merging is a no-op.
  git -C "$REPO_PATH" checkout -qb noop-branch
  echo "scratch" > "$REPO_PATH/scratch.txt"
  git -C "$REPO_PATH" add -A && git -C "$REPO_PATH" commit -qm "add scratch"
  git -C "$REPO_PATH" rm -q scratch.txt && git -C "$REPO_PATH" commit -qm "revert scratch"
  git -C "$REPO_PATH" update-ref refs/remotes/origin/noop-branch HEAD
  git -C "$REPO_PATH" checkout -q master
  _mock_gh_prs '[{"number":99,"title":"chore(TEST-9): net-zero change","headRefName":"noop-branch","createdAt":"2026-08-01T00:00:00Z"}]'

  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #99"* ]]
  [[ "$output" == *"No-op PRs"* ]]
}

# bats test_tags=fast
@test "stale-pr-audit: does not post to Slack without --notify" {
  _mock_gh_prs '[]'
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/mock_calls/curl" ]
}
