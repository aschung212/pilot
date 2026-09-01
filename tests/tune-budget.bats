#!/usr/bin/env bats
# Tests for scripts/tune-budget.sh — budget auto-tuning logic

load test_helper

# bats test_tags=slow
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
  [[ "$output" == *"2/3 nights"* ]] || [[ "$output" == *"Skipping tuning"* ]] || return 1
}

# bats test_tags=fast
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

# bats test_tags=fast
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

# bats test_tags=fast
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

# bats test_tags=fast
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

# ── End-to-end regressions (2026-08-28) ─────────────────────────────────────
# The tuner shipped with five passing tests and had never adjusted a value in
# its life: every test above re-implements the Python in the test file, so none
# of them ever executed the real script. Two bugs hid behind that:
#
#   1. The heredoc's positional args sat on the line AFTER the PYEOF terminator,
#      so python3 ran with an empty argv (every path defaulted to "", so it read
#      no data and always returned skip:True) and bash then tried to EXECUTE the
#      CSV path — "Permission denied", exit 126.
#   2. With argv restored, `int(row.get('commits', 0))` hit None on short rows
#      (csv.DictReader fills missing columns with None, so the default never
#      applies) and crashed on the 30 ragged rows in lift-metrics.csv.
#
# These drive the REAL script.

_seed_csvs() {  # $1 = dir; writes enough data for the tuner to act
  cat > "$1/lift-usage-tracking.csv" <<'EOF'
date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec
2026-04-01,1,1000,20000,0,0,20000,600
2026-04-02,1,1000,20000,0,0,20000,600
2026-04-03,1,1000,20000,0,0,20000,600
2026-04-04,1,1000,20000,0,0,20000,600
EOF
  cat > "$1/lift-metrics.csv" <<'EOF'
date,run,start,end,duration_sec,commits,tests_before,tests_after,added,fixed,skipped,failed,stalled,notes,success
2026-04-01,1,00:00:00,00:10:00,600,3,10,12,1,0,0,0,0,,true
2026-04-02,1,00:00:00,00:10:00,600,3,10,12,1,0,0,0,0,,true
2026-04-03,1,00:00:00,00:10:00,600,3,10,12,1,0,0,0,0,,true
2026-04-04,1,00:00:00,00:10:00,600,3,10,12,1,0,0,0,0,,true
EOF
}

# bats test_tags=fast
@test "tune-budget: the heredoc actually passes argv to python (it analyses real CSVs)" {
  _seed_csvs "$OUTPUT_DIR"
  run bash "$PILOT_DIR/scripts/tune-budget.sh" --dry-run
  [ "$status" -eq 0 ]
  # With an empty argv the tuner reads nothing and reports 0 nights. Seeing the
  # seeded nights proves the arguments reached python.
  [[ "$output" == *"nights=4"* ]] || return 1
  # And it must never try to execute a CSV as a command.
  [[ "$output" != *"Permission denied"* ]] || return 1
}

# bats test_tags=fast
@test "tune-budget: short rows in metrics.csv do not crash the analysis" {
  _seed_csvs "$OUTPUT_DIR"
  # A ragged row: fewer fields than the header, so DictReader yields None values.
  echo "2026-04-05,1,00:00:00" >> "$OUTPUT_DIR/lift-metrics.csv"
  run bash "$PILOT_DIR/scripts/tune-budget.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"TypeError"* ]] || return 1
  [[ "$output" != *"Traceback"* ]] || return 1
}

# bats test_tags=fast
@test "tune-budget: --dry-run writes neither budget.conf nor the tune log" {
  _seed_csvs "$OUTPUT_DIR"
  cp "$PILOT_DIR/config/budget.conf" "$TEST_TMPDIR/conf.before"
  run bash "$PILOT_DIR/scripts/tune-budget.sh" --dry-run
  [ "$status" -eq 0 ]
  diff -q "$PILOT_DIR/config/budget.conf" "$TEST_TMPDIR/conf.before"
  [ ! -f "$OUTPUT_DIR/lift-tune-log.csv" ]
}

# bats test_tags=fast
@test "tune-budget: --dry-run reports the change it would apply" {
  _seed_csvs "$OUTPUT_DIR"
  run bash "$PILOT_DIR/scripts/tune-budget.sh" --dry-run
  [[ "$output" == *"[dry-run] Would apply:"* ]] || return 1
  [[ "$output" == *"MAX_OUTPUT_TOKENS_PER_NIGHT"* ]] || return 1
}

# bats test_tags=fast
@test "tune-budget: rejects an unknown argument" {
  run bash "$PILOT_DIR/scripts/tune-budget.sh" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]] || return 1
}
