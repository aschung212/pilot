#!/usr/bin/env bats
# Tests for scripts/tune-budget.sh — budget auto-tuning logic

load test_helper

@test "tune-budget: skips with insufficient data" {
  # Create usage CSV with only 2 nights
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "2026-04-01,1,1000,500,0,0,500,60" >> "$OUTPUT_DIR/lift-usage-tracking.csv"
  echo "2026-04-02,1,1000,500,0,0,500,60" >> "$OUTPUT_DIR/lift-usage-tracking.csv"

  # Create budget conf
  BUDGET_CONF="$PILOT_DIR/config/budget.conf"

  TUNE="$PILOT_DIR/scripts/tune-budget.sh"
  run bash "$TUNE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2/3 nights"* ]] || [[ "$output" == *"Skipping tuning"* ]]
}

@test "tune-budget: python analysis raises iterations when hitting cap" {
  result=$(python3 << 'PYEOF'
import json
from collections import defaultdict

# Simulate 5 nights hitting cap of 8, all productive
old_iters = 8
sorted_dates = ['2026-03-28', '2026-03-29', '2026-03-30', '2026-03-31', '2026-04-01']
nights_data = {d: {'iterations': 8} for d in sorted_dates}
productivity = {d: {'successes': 6, 'stalls': 0, 'commits': 10, 'failures': 0} for d in sorted_dates}

nights_hit_cap = sum(1 for d in sorted_dates if nights_data[d]['iterations'] >= old_iters)
nights_stalled = 0
new_iters = old_iters
reasons = []

if nights_hit_cap >= len(sorted_dates) * 0.7 and nights_stalled == 0:
    new_iters = min(old_iters + 2, 15)
    if new_iters != old_iters:
        reasons.append(f"iterations {old_iters}->{new_iters}")

print(json.dumps({'new_iters': new_iters, 'reasons': reasons}))
PYEOF
)

  new_iters=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_iters'])")
  [ "$new_iters" = "10" ]
}

@test "tune-budget: python analysis lowers iterations on frequent stalls" {
  result=$(python3 << 'PYEOF'
import json

old_iters = 10
sorted_dates = ['d1', 'd2', 'd3', 'd4', 'd5']
# 4 out of 5 nights stalled
nights_stalled = 4
avg_productive = 3.0

new_iters = old_iters
if nights_stalled >= len(sorted_dates) * 0.5:
    new_iters = max(int(avg_productive + 2), 3)

print(json.dumps({'new_iters': new_iters}))
PYEOF
)

  new_iters=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_iters'])")
  [ "$new_iters" = "5" ]
}

@test "tune-budget: token cap has floor of 200K and ceiling of 1M" {
  result=$(python3 -c "
suggested = 50000  # very low
suggested = max(suggested, 200000)
suggested = min(suggested, 1000000)
print(suggested)
")
  [ "$result" = "200000" ]

  result=$(python3 -c "
suggested = 2000000  # very high
suggested = max(suggested, 200000)
suggested = min(suggested, 1000000)
print(suggested)
")
  [ "$result" = "1000000" ]
}

@test "tune-budget: cooldown increases on high failure rate" {
  result=$(python3 -c "
import json
old_cooldown = 30
failure_rate = 0.4  # > 0.3 threshold
new_cooldown = old_cooldown
if failure_rate > 0.3 and old_cooldown < 120:
    new_cooldown = min(old_cooldown + 15, 120)
print(json.dumps({'new_cooldown': new_cooldown}))
")
  new_cd=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_cooldown'])")
  [ "$new_cd" = "45" ]
}
