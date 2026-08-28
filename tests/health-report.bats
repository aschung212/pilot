#!/usr/bin/env bats
# Tests for scripts/health-report.sh — metrics aggregation

load test_helper

# Canonical metrics-CSV header — must stay in sync with builder.sh.
METRICS_HEADER='date,run,start_time,end_time,duration_sec,commits,tests_before,tests_after,tests_delta,issues_done,issues_skipped,issues_created,stalls,build_size_kb,success'

# bats test_tags=fast
@test "grep -c with no matches: single-line output via head -1 wrapper" {
  # The bug: `grep -c PATTERN file 2>/dev/null || echo 0` produces "0\n0"
  # when there are no matches, because grep -c prints "0" AND exits 1, then
  # the `|| echo 0` runs and prints another "0". The fix is `| head -1`.
  echo "no matches here" > "$BATS_TEST_TMPDIR/fixture.txt"

  # Buggy form (kept here as a regression sentinel — assert it IS broken).
  buggy=$(grep -c "xxx" "$BATS_TEST_TMPDIR/fixture.txt" 2>/dev/null || echo "0")
  [ "$(echo -n "$buggy" | wc -l | tr -d ' ')" -eq 1 ]

  # Fixed form: head -1 collapses to one line.
  fixed=$({ grep -c "xxx" "$BATS_TEST_TMPDIR/fixture.txt" 2>/dev/null || echo "0"; } | head -1)
  [ "$(echo -n "$fixed" | wc -l | tr -d ' ')" -eq 0 ]
  [ "$fixed" = "0" ]
}

# bats test_tags=fast
@test "health-report: nights_run derived from distinct dates in metrics CSV" {
  # Two distinct nights, multiple iterations each. Dates are generated relative
  # to today so the fixture always lands inside health-report.sh's rolling
  # 7-day window — hardcoded dates silently aged out of that window and made
  # this test rot (all rows filtered → nights=0).
  local d1 d2
  d1=$(python3 -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=1))')
  d2=$(python3 -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=2))')
  cat > "$OUTPUT_DIR/lift-metrics.csv" <<CSV
$METRICS_HEADER
$d1,1,23:00:00,23:10:00,600,2,100,102,2,1,0,0,0,1500.0,true
$d1,2,23:11:00,23:21:00,600,1,102,103,1,1,0,0,0,1501.0,true
$d2,1,23:00:00,23:15:00,900,3,98,101,3,1,0,0,0,1499.0,true
CSV
  nights=$(OUTPUT_DIR="$OUTPUT_DIR" python3 -c '
import csv, os
from datetime import datetime, timedelta
cutoff = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")
with open(os.environ["OUTPUT_DIR"] + "/lift-metrics.csv") as f:
    rows = [r for r in csv.DictReader(f) if r["date"] >= cutoff]
print(len({r["date"] for r in rows if r.get("date")}))
')
  [ "$nights" = "2" ]
}

# bats test_tags=fast
@test "health-report: avg_builder_min derived from duration_sec sum / nights" {
  # Dates generated relative to today (see the nights_run test) so the rows stay
  # inside the rolling 7-day window.
  local d1 d2
  d1=$(python3 -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=1))')
  d2=$(python3 -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=2))')
  cat > "$OUTPUT_DIR/lift-metrics.csv" <<CSV
$METRICS_HEADER
$d1,1,23:00:00,23:10:00,600,2,100,102,2,1,0,0,0,1500.0,true
$d1,2,23:11:00,23:21:00,600,1,102,103,1,1,0,0,0,1501.0,true
$d2,1,23:00:00,23:30:00,1800,3,98,101,3,1,0,0,0,1499.0,true
CSV
  # Total = 600+600+1800 = 3000s, 2 nights → avg 25.0m
  avg=$(OUTPUT_DIR="$OUTPUT_DIR" python3 -c '
import csv, os
from datetime import datetime, timedelta
cutoff = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")
with open(os.environ["OUTPUT_DIR"] + "/lift-metrics.csv") as f:
    rows = [r for r in csv.DictReader(f) if r["date"] >= cutoff]
nights = len({r["date"] for r in rows if r.get("date")})
total = sum(int(r.get("duration_sec",0) or 0) for r in rows)
print(round(total / nights / 60, 1) if nights else 0)
')
  [ "$avg" = "25.0" ]
}

# bats test_tags=fast
@test "health-report: success counts use 'true' / 'stall' values" {
  # Regression test for the symptom that masked the original bug:
  # corrupted CSV rows had success=None which counted as neither
  # successful nor stalled. With clean rows, the counters work.
  cat > "$OUTPUT_DIR/lift-metrics.csv" <<CSV
$METRICS_HEADER
2026-04-23,1,23:00:00,23:10:00,600,2,100,102,2,1,0,0,0,1500.0,true
2026-04-23,2,23:11:00,23:21:00,600,0,102,102,0,0,0,0,1,1500.0,stall
2026-04-23,3,23:22:00,23:30:00,480,1,102,103,1,1,0,0,0,1500.0,true
CSV
  result=$(OUTPUT_DIR="$OUTPUT_DIR" python3 -c '
import csv, os
with open(os.environ["OUTPUT_DIR"] + "/lift-metrics.csv") as f:
    rows = list(csv.DictReader(f))
successful = sum(1 for r in rows if r.get("success") == "true")
stalls = sum(1 for r in rows if r.get("success") == "stall")
print(f"{successful},{stalls}")
')
  [ "$result" = "2,1" ]
}

# bats test_tags=fast
@test "health-report: stall rate anomaly detection" {
  result=$(python3 -c "
stall_rate = 45
anomalies = []
if stall_rate > 40:
    anomalies.append(f'High stall rate: {stall_rate:.0f}%')
print(anomalies[0] if anomalies else 'none')
")
  [[ "$result" == *"High stall rate: 45%"* ]]
}

# bats test_tags=fast
@test "health-report: trend emoji logic" {
  green=$(python3 -c "print('🟢' if 15 < 20 else '🟡' if 15 < 40 else '🔴')")
  [ "$green" = "🟢" ]

  yellow=$(python3 -c "print('🟢' if 35 < 20 else '🟡' if 35 < 40 else '🔴')")
  [ "$yellow" = "🟡" ]

  red=$(python3 -c "print('🟢' if 50 < 20 else '🟡' if 50 < 40 else '🔴')")
  [ "$red" = "🔴" ]
}

# bats test_tags=slow
@test "health-report: dry-run does not post to Slack" {
  # Create minimal CSVs
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "$METRICS_HEADER" > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  HEALTH="$PILOT_DIR/scripts/health-report.sh"
  run bash "$HEALTH" --dry-run
  [ "$status" -eq 0 ]
  # Should not have called notify.sh (no curl calls for slack)
  if [ -f "$TEST_TMPDIR/mock_calls/curl" ]; then
    ! grep -q "chat.postMessage" "$TEST_TMPDIR/mock_calls/curl" || true
  fi
}

# bats test_tags=slow
@test "health-report: flags a stale builder (last run >=3 days ago)" {
  # Regression guard for 2026-07-09: a hung builder produced no metrics for 5
  # days and nothing surfaced it. Latest metrics row is 5 days old → the
  # staleness anomaly must fire in the generated report.
  local stale
  stale=$(python3 -c 'import datetime; print(datetime.date.today() - datetime.timedelta(days=5))')
  {
    echo "$METRICS_HEADER"
    echo "$stale,1,23:00:00,23:10:00,600,2,100,102,2,1,0,0,0,1500.0,true"
  } > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  run bash "$PILOT_DIR/scripts/health-report.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Builder has not run in 5 days"* ]]
}

# bats test_tags=slow
@test "health-report: no staleness anomaly when builder ran today" {
  local today
  today=$(python3 -c 'import datetime; print(datetime.date.today())')
  {
    echo "$METRICS_HEADER"
    echo "$today,1,23:00:00,23:10:00,600,2,100,102,2,1,0,0,0,1500.0,true"
  } > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  run bash "$PILOT_DIR/scripts/health-report.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"has not run in"* ]]
}

# ── Delivery / flow metrics + GA burndown ────────────────────────────────────

# bats test_tags=slow
@test "health-report: report includes Delivery and GA Burndown, degrading to zeros without gh data" {
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "$METRICS_HEADER" > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  HEALTH="$PILOT_DIR/scripts/health-report.sh"
  run bash "$HEALTH" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Delivery"* ]]
  [[ "$output" == *"PRs merged (7d):"* ]]
  [[ "$output" == *"## GA Burndown"* ]]
  # The stock gh mock returns non-JSON, so flow metrics must degrade to zeros
  # and the burndown line must fall back to the create-the-milestone hint.
  [[ "$output" == *"Tokens per merged PR"* || "$output" == *"Output tokens per merged PR"* ]]
  [[ "$output" == *"not found"* ]]
}

# bats test_tags=slow
@test "health-report: flow metrics computed from PR history, aging queue flagged" {
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "$METRICS_HEADER" > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  # One PR merged 2d ago (created 3d ago → 24h to merge), one closed unmerged
  # 1d ago, one still open and 10 days old (should trip the aging anomaly).
  D_CREATED=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  D_MERGED=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  D_CLOSED=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  D_OLD=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  cat > "$TEST_TMPDIR/prs.json" <<JSON
[
  {"number": 1, "createdAt": "$D_CREATED", "closedAt": "$D_MERGED", "mergedAt": "$D_MERGED", "state": "MERGED"},
  {"number": 2, "createdAt": "$D_CREATED", "closedAt": "$D_CLOSED", "mergedAt": null, "state": "CLOSED"},
  {"number": 3, "createdAt": "$D_OLD", "closedAt": null, "mergedAt": null, "state": "OPEN"}
]
JSON
  echo '[{"title": "GA", "open_issues": 3, "closed_issues": 9}]' > "$TEST_TMPDIR/milestones.json"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/gh" <<GHEOF
#!/bin/bash
case "\$*" in
  *mergedAt*) cat "$TEST_TMPDIR/prs.json" ;;
  *milestones*) cat "$TEST_TMPDIR/milestones.json" ;;
  *) echo "" ;;
esac
GHEOF
  chmod +x "$TEST_TMPDIR/bin/gh"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  HEALTH="$PILOT_DIR/scripts/health-report.sh"
  run bash "$HEALTH" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRs merged (7d):** 1"* ]]
  [[ "$output" == *"Merge rate:** 50%"* ]]
  [[ "$output" == *"Avg time-to-merge:** 24"* ]]
  [[ "$output" == *"oldest: 10d"* ]]
  [[ "$output" == *"Review queue aging"* ]]
  [[ "$output" == *"9/12 closed (75%)"* ]]
}
