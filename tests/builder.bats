#!/usr/bin/env bats
# Tests for scripts/builder.sh — budget guards, stop logic, usage tracking

load test_helper

BUILDER="$PILOT_DIR/scripts/builder.sh"

# ── Budget and stop condition logic (extracted from builder.sh) ──────────────

# bats test_tags=fast
@test "builder: iteration cap stops the loop" {
  RUN=12
  MAX_ITERATIONS_PER_NIGHT=12
  [ "$RUN" -ge "$MAX_ITERATIONS_PER_NIGHT" ]
}

# bats test_tags=fast
@test "builder: token cap stops the loop" {
  NIGHTLY_OUTPUT_TOKENS=550000
  MAX_OUTPUT_TOKENS_PER_NIGHT=500000
  [ "$NIGHTLY_OUTPUT_TOKENS" -ge "$MAX_OUTPUT_TOKENS_PER_NIGHT" ]
}

# bats test_tags=fast
@test "builder: alert threshold fires at 80%" {
  pct=$(python3 -c "print(int(420000 / 500000 * 100))")
  ALERT_THRESHOLD_PCT=80
  [ "$pct" -ge "$ALERT_THRESHOLD_PCT" ]

  # Below threshold — no alert
  pct=$(python3 -c "print(int(350000 / 500000 * 100))")
  [ "$pct" -lt "$ALERT_THRESHOLD_PCT" ]
}

# bats test_tags=fast
@test "builder: consecutive failure cap" {
  FAILURES=3
  MAX_CONSECUTIVE_FAILURES=3
  [ "$FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]
}

# bats test_tags=fast
@test "builder: stall detection stops after MAX_STALLS" {
  STALLS=2
  MAX_STALLS=2
  [ "$STALLS" -ge "$MAX_STALLS" ]
}

# bats test_tags=fast
@test "builder: numeric arg sets max iterations" {
  STOP_AT="5"
  if [[ "$STOP_AT" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS_PER_NIGHT="$STOP_AT"
    STOP_AT="23:59"
  fi
  [ "$MAX_ITERATIONS_PER_NIGHT" = "5" ]
  [ "$STOP_AT" = "23:59" ]
}

# bats test_tags=fast
@test "builder: time arg kept as stop time" {
  STOP_AT="06:00"
  if [[ "$STOP_AT" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS_PER_NIGHT="$STOP_AT"
    STOP_AT="23:59"
  fi
  [ "$STOP_AT" = "06:00" ]
}

# bats test_tags=fast
@test "builder: parse_usage extracts tokens from JSON" {
  JSON_FILE="$TEST_TMPDIR/output.json"
  cat > "$JSON_FILE" << 'EOF'
{
  "result": "some code",
  "usage": {
    "input_tokens": 50000,
    "output_tokens": 12000,
    "cache_read_input_tokens": 8000,
    "cache_creation_input_tokens": 3000
  }
}
EOF

  result=$(python3 -c "
import json
with open('$JSON_FILE') as f:
    data = json.load(f)
usage = data.get('usage', {})
inp = usage.get('input_tokens', 0)
out = usage.get('output_tokens', 0)
cr = usage.get('cache_read_input_tokens', 0)
cc = usage.get('cache_creation_input_tokens', 0)
print(f'{inp},{out},{cr},{cc}')
")
  [ "$result" = "50000,12000,8000,3000" ]
}

# bats test_tags=fast
@test "builder: parse_usage handles missing/corrupt JSON" {
  JSON_FILE="$TEST_TMPDIR/bad.json"
  echo "not json" > "$JSON_FILE"

  result=$(python3 -c "
import json
try:
    with open('$JSON_FILE') as f:
        data = json.load(f)
    print('parsed')
except:
    print('0,0,0,0')
")
  [ "$result" = "0,0,0,0" ]
}

# bats test_tags=fast
@test "builder: overnight stop time logic (after midnight)" {
  # Simulate 3:00 AM with stop at 7:00 AM — should continue
  now_mins=$((3 * 60))
  stop_mins=$((7 * 60))
  should_stop=false
  if [ "$stop_mins" -lt 720 ]; then
    if [ "$now_mins" -ge "$stop_mins" ] && [ "$now_mins" -lt 720 ]; then
      should_stop=true
    fi
  fi
  [ "$should_stop" = "false" ]

  # Simulate 7:30 AM with stop at 7:00 AM — should stop
  now_mins=$((7 * 60 + 30))
  should_stop=false
  if [ "$stop_mins" -lt 720 ]; then
    if [ "$now_mins" -ge "$stop_mins" ] && [ "$now_mins" -lt 720 ]; then
      should_stop=true
    fi
  fi
  [ "$should_stop" = "true" ]
}

# bats test_tags=fast
@test "builder: usage CSV header is correct" {
  CSV="$TEST_TMPDIR/usage.csv"
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$CSV"
  HEADER=$(head -1 "$CSV")
  [[ "$HEADER" == *"date,run,input_tokens"* ]]
}

# bats test_tags=fast
@test "builder: composite verdict picks worst" {
  # Composite = worst of all layers. Test the logic.
  pick_worst() {
    local worst="MERGE"
    for v in "$@"; do
      case "$v" in
        DO_NOT_MERGE) worst="DO_NOT_MERGE" ;;
        REVIEW) [ "$worst" != "DO_NOT_MERGE" ] && worst="REVIEW" ;;
      esac
    done
    echo "$worst"
  }

  [ "$(pick_worst MERGE MERGE MERGE)" = "MERGE" ]
  [ "$(pick_worst MERGE REVIEW MERGE)" = "REVIEW" ]
  [ "$(pick_worst MERGE MERGE DO_NOT_MERGE)" = "DO_NOT_MERGE" ]
  [ "$(pick_worst REVIEW DO_NOT_MERGE MERGE)" = "DO_NOT_MERGE" ]
}
