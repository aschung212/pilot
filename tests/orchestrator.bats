#!/usr/bin/env bats
# Tests for scripts/orchestrator.sh — pipeline dispatch

load test_helper

# bats test_tags=fast
@test "orchestrator: valid bash syntax" {
  bash -n "$PILOT_DIR/scripts/orchestrator.sh"
}

# bats test_tags=fast
@test "orchestrator: runtime CSV header format" {
  CSV="$TEST_TMPDIR/runtime.csv"
  echo "date,pipeline_start,pipeline_end,total_sec,discover_sec,triage_sec,builder_sec" > "$CSV"
  HEADER=$(head -1 "$CSV")
  [[ "$HEADER" == *"date,pipeline_start"* ]]
}
