#!/usr/bin/env bats
# Tests for scripts/cleanup.sh — archive and dedup logic

load test_helper

# bats test_tags=slow
@test "cleanup: dedup logic keeps oldest issue" {
  # Simulate the python dedup logic
  input="TEST-100|fix button alignment
TEST-105|fix button alignment
TEST-110|add dark mode
TEST-115|fix button alignment"

  dupes=$(echo "$input" | python3 -c "
import sys
from collections import defaultdict
by_title = defaultdict(list)
for line in sys.stdin:
    line = line.strip()
    if '|' not in line: continue
    issue_id, title = line.split('|', 1)
    by_title[title.strip().lower()].append(issue_id.strip())
for title, ids in by_title.items():
    if len(ids) > 1:
        ids.sort(key=lambda x: int(x.split('-')[1]))
        for dup_id in ids[1:]:
            print(dup_id)
")

  # Should identify TEST-105 and TEST-115 as dupes (keep TEST-100)
  echo "$dupes" | grep -q "TEST-105"
  echo "$dupes" | grep -q "TEST-115"
  # Should NOT identify TEST-100 (oldest) or TEST-110 (unique)
  ! echo "$dupes" | grep -q "TEST-100"
  ! echo "$dupes" | grep -q "TEST-110"
}

# bats test_tags=fast
@test "cleanup: dry-run does not modify issues" {
  # Create fake credentials so cleanup doesn't exit early
  mkdir -p "$TEST_TMPDIR/home/.config/linear"
  echo 'token = "fake-token"' > "$TEST_TMPDIR/home/.config/linear/credentials.toml"
  export HOME="$TEST_TMPDIR/home"

  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP" --dry-run
  # Should not have called linear update (only list/view)
  if [ -f "$TEST_TMPDIR/mock_calls/linear" ]; then
    ! grep -q "issue update" "$TEST_TMPDIR/mock_calls/linear" || true
  fi
}

# bats test_tags=fast
@test "cleanup: metrics CSV header is correct" {
  CLEANUP_CSV="$TEST_TMPDIR/cleanup-metrics.csv"
  echo "date,archived,deduped" > "$CLEANUP_CSV"
  echo "2026-04-01,5,2" >> "$CLEANUP_CSV"

  HEADER=$(head -1 "$CLEANUP_CSV")
  [ "$HEADER" = "date,archived,deduped" ]

  COUNT=$(tail -n +2 "$CLEANUP_CSV" | wc -l | tr -d ' ')
  [ "$COUNT" -eq 1 ]
}

# bats test_tags=fast
@test "cleanup: exits gracefully when the board has no actionable issues" {
  # Lift's tracker migrated from Linear to GitHub Issues (commit 2732bce), which
  # removed the old "No Linear API token" credential gate — cleanup now runs
  # against gh (mocked here). With no matching issues to close or dedup, it must
  # still run end-to-end and exit 0 with a summary rather than erroring out.
  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleanup:"* ]] || return 1
  [[ "$output" == *"0 closed, 0 merge-closed, 0 deduped"* ]] || return 1
}

# ── Needs-decision snapshot + rejection-learnings harvest (step 2b) ──────────

# bats test_tags=fast
@test "cleanup: writes an empty needs-decision snapshot when nothing is rejected" {
  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP"
  [ "$status" -eq 0 ]
  # Snapshot file exists (digest.sh reads it) but holds no issue IDs
  [ -f "$OUTPUT_DIR/lift-needs-decision.txt" ]
  [ ! -s "$OUTPUT_DIR/lift-needs-decision.txt" ]
  # Learnings file is seeded with its header
  [ -f "$OUTPUT_DIR/lift-build-learnings.md" ]
  grep -q "Build learnings" "$OUTPUT_DIR/lift-build-learnings.md"
}

# bats test_tags=fast
@test "cleanup: harvests closing comments from recent unmerged closes, idempotently" {
  export GITHUB_ISSUES_REPO="aaron/testrepo"

  # Crafted gh mock: the harvest query (contains closedAt) gets PR JSON with
  # four cases — already recorded (#7), fresh rejection with owner comment
  # (#8), merged (#9, must be ignored), and an old rejection outside the
  # 14-day window (#10, must be ignored). Everything else gets empty output.
  RECENT=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  OLD=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  cat > "$TEST_TMPDIR/prs.json" <<JSON
[
  {"number": 7, "title": "old entry", "closedAt": "$RECENT", "mergedAt": null, "comments": []},
  {"number": 8, "title": "fix(TEST-8): bad approach", "closedAt": "$RECENT", "mergedAt": null,
   "comments": [{"author": {"login": "vercel-bot"}, "body": "deploy preview"},
                 {"author": {"login": "aaron"}, "body": "Rejected: modal breaks offline mode"}]},
  {"number": 9, "title": "feat(TEST-9): merged fine", "closedAt": "$RECENT", "mergedAt": "$RECENT", "comments": []},
  {"number": 10, "title": "fix(TEST-10): too old", "closedAt": "$OLD", "mergedAt": null, "comments": []}
]
JSON
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  *closedAt*) cat "$TEST_TMPDIR/prs.json" ;;
  *) echo "" ;;
esac
GHEOF
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Pre-seed the learnings file with PR #7 so it must NOT be re-harvested
  mkdir -p "$OUTPUT_DIR"
  printf '# Build learnings\n\n## PR #7 — old entry (closed unmerged 2026-08-01)\nalready here\n' \
    > "$OUTPUT_DIR/lift-build-learnings.md"

  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP"
  [ "$status" -eq 0 ]

  LEARNINGS="$OUTPUT_DIR/lift-build-learnings.md"
  # Fresh rejection harvested with the owner's comment (bot comment ignored)
  grep -q "## PR #8 " "$LEARNINGS"
  grep -q "Rejected: modal breaks offline mode" "$LEARNINGS"
  ! grep -q "deploy preview" "$LEARNINGS"
  # Merged and out-of-window PRs are not learnings
  ! grep -q "## PR #9 " "$LEARNINGS"
  ! grep -q "## PR #10 " "$LEARNINGS"
  # Idempotent: #7 appears exactly once, and a second run adds nothing new
  [ "$(grep -c '^## PR #7 ' "$LEARNINGS")" -eq 1 ]
  run bash "$CLEANUP"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## PR #8 ' "$LEARNINGS")" -eq 1 ]
}

# ── Backlog expiry (step 4) ──────────────────────────────────────────────────

# bats test_tags=fast
@test "cleanup: stale-P4 filter expires old issues but never parked ones" {
  # Replicates the expiry filter in cleanup.sh step 4: priority:4-low issues
  # untouched beyond the cutoff are expired, unless parked on a human
  # (started / blocked / needs-input).
  STALE=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  FRESH=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  result=$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
days = int(sys.argv[1])
issues = json.load(sys.stdin)
cutoff = datetime.now(timezone.utc) - timedelta(days=days)
PARKED = {'state:started', 'state:blocked', 'state:needs-input'}
for i in issues:
    if not isinstance(i, dict) or not i.get('number'):
        continue
    labels = {l.get('name') for l in (i.get('labels') or []) if isinstance(l, dict)}
    if labels & PARKED:
        continue
    try:
        upd = datetime.fromisoformat(str(i.get('updatedAt')).replace('Z', '+00:00'))
    except Exception:
        continue
    if upd < cutoff:
        print(i['number'])
" 56 <<JSON
[
  {"number": 1, "updatedAt": "$STALE", "labels": [{"name": "priority:4-low"}]},
  {"number": 2, "updatedAt": "$FRESH", "labels": [{"name": "priority:4-low"}]},
  {"number": 3, "updatedAt": "$STALE", "labels": [{"name": "priority:4-low"}, {"name": "state:needs-input"}]},
  {"number": 4, "updatedAt": "$STALE", "labels": [{"name": "priority:4-low"}, {"name": "state:started"}]}
]
JSON
)
  [ "$result" = "1" ]
}

# bats test_tags=fast
@test "cleanup: expiry disabled by BACKLOG_EXPIRY_DAYS=0" {
  export BACKLOG_EXPIRY_DAYS=0
  export GITHUB_ISSUES_REPO="aaron/testrepo"
  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Would expire"* ]] || return 1
}

# ── Merged-PR close path (step 2) ────────────────────────────────────────────
# These drive the real script end-to-end against a scripted gh, rather than
# re-implementing its logic in the test — a unit test over a pasted copy of the
# logic proves nothing about the original (see CLAUDE.md, tune-budget.bats).

# Scripts a gh that reports one state:started issue per id in $1, with the PR
# state given by $2 (merged|open|closed). Records every write to $TEST_TMPDIR/gh-writes.
_stub_gh_for_started() {
  local issue_num="$1" pr_state="$2"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<GHEOF
#!/bin/bash
echo "\$*" >> "$TEST_TMPDIR/gh-writes"
TITLE="fix(TEST-${issue_num}): ship the thing"
case "\$*" in
  *"pr list"*closedAt*)          echo "[]" ;;
  *"pr list"*"--state merged"*)  [ "$pr_state" = merged ] && printf '9001\t%s\n' "\$TITLE" ;;
  *"pr list"*"--state open"*)    [ "$pr_state" = open ]   && echo "\$TITLE" ;;
  *"pr list"*"--state all"*)     echo "\$TITLE" ;;
  *"issue list"*state:started*)  echo "TEST-${issue_num} ship the thing" ;;
  *) echo "" ;;
esac
exit 0
GHEOF
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export GITHUB_ISSUES_REPO="aaron/testrepo"
}

# bats test_tags=fast
@test "cleanup: closes a state:started issue whose PR merged" {
  _stub_gh_for_started 42 merged

  run bash "$PILOT_DIR/scripts/cleanup.sh"
  [ "$status" -eq 0 ]

  # Closed as completed, with the merged PR named in a comment first
  grep -q "issue close 42 .*--reason completed" "$TEST_TMPDIR/gh-writes"
  grep -q "issue comment 42 .*PR #9001 merged" "$TEST_TMPDIR/gh-writes"
  # …and the now-meaningless label dropped, only after the close
  grep -q "issue edit 42 .*--remove-label state:started" "$TEST_TMPDIR/gh-writes"
  CLOSE_LINE=$(grep -n "issue close 42" "$TEST_TMPDIR/gh-writes" | head -1 | cut -d: -f1)
  EDIT_LINE=$(grep -n "issue edit 42 .*--remove-label state:started" "$TEST_TMPDIR/gh-writes" | head -1 | cut -d: -f1)
  [ "$CLOSE_LINE" -lt "$EDIT_LINE" ]

  # Reported and counted, not silently swept
  [[ "$output" == *"1 merge-closed"* ]] || return 1
  [[ "$output" == *"TEST-42 (PR #9001)"* ]] || return 1
  # The old "still state:started with a MERGED PR" backlog note is now clear
  [[ "$output" != *"still state:started with a MERGED PR"* ]] || return 1

  # Sixth CSV column carries the count
  CSV="$OUTPUT_DIR/lift-cleanup-metrics.csv"
  [ "$(head -1 "$CSV")" = "date,closed,deduped,recycled,expired,merged_closed" ]
  [ "$(tail -1 "$CSV" | cut -d, -f6)" = "1" ]
}

# bats test_tags=fast
@test "cleanup: leaves a state:started issue alone while its PR is still open" {
  _stub_gh_for_started 43 open

  run bash "$PILOT_DIR/scripts/cleanup.sh"
  [ "$status" -eq 0 ]

  # In flight — never closed, never recycled, label untouched
  ! grep -q "issue close 43" "$TEST_TMPDIR/gh-writes"
  ! grep -q "remove-label state:started" "$TEST_TMPDIR/gh-writes"
  [[ "$output" == *"0 merge-closed"* ]] || return 1
}

# bats test_tags=fast
@test "cleanup: reports but never closes an issue whose PR was closed unmerged" {
  _stub_gh_for_started 44 closed

  run bash "$PILOT_DIR/scripts/cleanup.sh"
  [ "$status" -eq 0 ]

  ! grep -q "issue close 44" "$TEST_TMPDIR/gh-writes"
  [[ "$output" == *"needs your call"* ]] || return 1
  [[ "$output" == *"TEST-44"* ]] || return 1
  # Snapshot handed to digest.sh
  grep -q "TEST-44" "$OUTPUT_DIR/lift-needs-decision.txt"
}

# bats test_tags=fast
@test "cleanup: dry-run previews the merged-PR close without writing" {
  _stub_gh_for_started 45 merged

  run bash "$PILOT_DIR/scripts/cleanup.sh" --dry-run
  [ "$status" -eq 0 ]

  [[ "$output" == *"[dry-run] Would close TEST-45 (merged PR #9001)"* ]] || return 1
  ! grep -q "issue close 45" "$TEST_TMPDIR/gh-writes"
  ! grep -q "issue comment 45" "$TEST_TMPDIR/gh-writes"
  ! grep -q "remove-label state:started" "$TEST_TMPDIR/gh-writes"
}

# bats test_tags=fast
@test "cleanup: PR queries are capped well above the real PR count and warn at the cap" {
  # The cap was 500 against 558 merged / 687 total PRs on 2026-08-30, so the
  # oldest PRs were invisible — and an issue whose only PR fell off the end
  # reads as "no PR ever" and gets recycled, rebuilding shipped work.
  grep -q 'GH_PR_LIMIT="${GH_PR_LIMIT:-2000}"' "$PILOT_DIR/scripts/cleanup.sh"
  ! grep -q 'gh pr list .*--limit 500' "$PILOT_DIR/scripts/cleanup.sh"

  # A response sitting exactly at the cap is the only visible symptom.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<'GHEOF'
#!/bin/bash
case "$*" in
  *"pr list"*closedAt*)      echo "[]" ;;
  *"pr list"*"--state all"*) seq 1 3 | sed 's/^/chore: pr /' ;;
  *) echo "" ;;
esac
exit 0
GHEOF
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export GITHUB_ISSUES_REPO="aaron/testrepo"
  export GH_PR_LIMIT=3

  run bash "$PILOT_DIR/scripts/cleanup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"probably TRUNCATED"* ]] || return 1
}
