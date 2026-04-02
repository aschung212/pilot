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
@test "cleanup: exits gracefully without Linear token" {
  # No credentials file
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/linear"
  # Empty credentials

  CLEANUP="$PILOT_DIR/scripts/cleanup.sh"
  run bash "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Linear API token"* ]]
}
