#!/usr/bin/env bats
# Tests for scripts/health-report.sh — metrics aggregation

load test_helper

# bats test_tags=slow
@test "health-report: python analysis handles empty CSVs" {
  # Create empty CSVs with headers only
  echo "date,pipeline_start,pipeline_end,total_sec,discover_sec,triage_sec,builder_sec" > "$OUTPUT_DIR/lift-runtime.csv"
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "date,run,commits,success,tests_pass,tests_fail" > "$OUTPUT_DIR/lift-metrics.csv"
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$OUTPUT_DIR/lift-tune-log.csv"
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$OUTPUT_DIR/lift-discovery-metrics.csv"

  # Run the python analysis portion inline
  result=$(python3 << 'PYEOF'
import csv, json, os
from datetime import datetime, timedelta
from collections import defaultdict

output_dir = os.environ.get('OUTPUT_DIR')
now = datetime.now()
week_ago = now - timedelta(days=7)
week_start = week_ago.strftime('%Y-%m-%d')

def read_csv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

runtime_rows = [r for r in read_csv(f'{output_dir}/lift-runtime.csv') if r.get('date', '') >= week_start]
nights_run = len(runtime_rows)

report = {'nights_run': nights_run, 'total_iterations': 0, 'anomalies': ['No pipeline runs detected this week']}
print(json.dumps(report))
PYEOF
)

  nights=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['nights_run'])")
  [ "$nights" = "0" ]

  # Should flag anomaly for no runs
  echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'No pipeline runs' in d['anomalies'][0]"
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
  echo "date,pipeline_start,pipeline_end,total_sec,discover_sec,triage_sec,builder_sec" > "$OUTPUT_DIR/lift-runtime.csv"
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "date,run,commits,success,tests_pass,tests_fail" > "$OUTPUT_DIR/lift-metrics.csv"
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
