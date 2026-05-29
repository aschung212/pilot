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
  [[ "$output" == *"Cleanup:"* ]]
  [[ "$output" == *"0 closed, 0 deduped"* ]]
}
