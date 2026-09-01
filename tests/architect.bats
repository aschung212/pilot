#!/usr/bin/env bats
# Tests for scripts/architect.sh and lib/architect-utils.sh

load test_helper

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"

  # Fake project.env values
  export PROJECT_NAME="TestProject"
  export REPO_PATH="$TEST_TMPDIR/repo"
  export GITHUB_REPO="test/repo"
  export ISSUE_PREFIX="TEST"
  export LINEAR_TEAM="TEST"
  export LINEAR_PROJECT="TestProject"
  export LINEAR_ORG="testorg"
  export SLACK_BOT_TOKEN=""
  export SLACK_WEBHOOK_URL=""

  # Suppress env sourcing in scripts
  export _PILOT_TEST_MODE=1

  mkdir -p "$REPO_PATH"

  # Put repo mocks on PATH (gh, linear, claude are already mocked there)
  export PATH="$PILOT_DIR/tests/mocks:$PATH"

  # Source the utils under test
  source "$PILOT_DIR/lib/architect-utils.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ── lib/architect-utils.sh: axis list ────────────────────────────────────────

# bats test_tags=fast
@test "architect: ARCHITECT_AXES has exactly 8 entries" {
  [ "${#ARCHITECT_AXES[@]}" -eq 8 ]
}

# bats test_tags=fast
@test "architect: all expected axes are present" {
  local expected=("store-coherence" "composable-quality" "component-boundaries"
                  "type-safety" "error-resilience" "pwa-offline"
                  "theme-invariants" "supabase-rls")
  for ax in "${expected[@]}"; do
    local found=0
    for a in "${ARCHITECT_AXES[@]}"; do
      [ "$a" = "$ax" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || { echo "Missing axis: $ax" >&2; false; }
  done
}

# ── axis_is_valid ─────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: axis_is_valid returns 0 for known axis" {
  run axis_is_valid "store-coherence"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "architect: axis_is_valid returns 1 for unknown axis" {
  run axis_is_valid "purple-elephants"
  [ "$status" -eq 1 ]
}

# ── axis_display_name ─────────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: axis_display_name returns human name for store-coherence" {
  result=$(axis_display_name "store-coherence")
  [[ "$result" == *"Store"* ]] || return 1
}

# bats test_tags=fast
@test "architect: axis_display_name returns human name for type-safety" {
  result=$(axis_display_name "type-safety")
  [[ "$result" == *"Type"* ]] || return 1
}

# bats test_tags=fast
@test "architect: axis_display_name falls through to slug for unknown" {
  result=$(axis_display_name "unknown-axis-xyz")
  [ "$result" = "unknown-axis-xyz" ]
}

# ── select_axis ───────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: select_axis returns first axis when history is empty" {
  QUEUE_FILE="$TEST_TMPDIR/arch-history.csv"
  echo "date,axis,files_scanned,findings,issues_filed,top_finding_summary" > "$QUEUE_FILE"
  result=$(select_axis "$QUEUE_FILE")
  [ "$result" = "store-coherence" ]
}

# bats test_tags=fast
@test "architect: select_axis returns first axis when history file missing" {
  result=$(select_axis "$TEST_TMPDIR/nonexistent.csv")
  [ "$result" = "store-coherence" ]
}

# bats test_tags=fast
@test "architect: select_axis picks least-run axis" {
  HIST="$TEST_TMPDIR/arch-history.csv"
  echo "date,axis,files_scanned,findings,issues_filed,top_finding_summary" > "$HIST"
  # Add store-coherence twice, composable-quality once — composable-quality should NOT win
  # because store-coherence (2) > composable-quality (1): composable-quality is least run...
  # Wait — least run wins. composable-quality(1) < store-coherence(2) → composable-quality wins
  echo "2026-04-01,store-coherence,20,4,4,some finding" >> "$HIST"
  echo "2026-04-08,store-coherence,22,3,3,other finding" >> "$HIST"
  echo "2026-04-15,composable-quality,18,5,5,yet another" >> "$HIST"
  result=$(select_axis "$HIST")
  # composable-quality has 1 run, store-coherence has 2, all others have 0
  # 0 < 1 < 2, so result should be one of the axes with 0 runs
  # The first axis with 0 runs is "component-boundaries" (index 2)
  [ "$result" = "component-boundaries" ]
}

# bats test_tags=fast
@test "architect: AXIS_OVERRIDE takes priority over round-robin" {
  export AXIS_OVERRIDE="supabase-rls"
  HIST="$TEST_TMPDIR/arch-history.csv"
  echo "date,axis,files_scanned,findings,issues_filed,top_finding_summary" > "$HIST"
  result=$(select_axis "$HIST")
  [ "$result" = "supabase-rls" ]
  unset AXIS_OVERRIDE
}

# ── build_axis_prompt ─────────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: build_axis_prompt contains repo path" {
  result=$(build_axis_prompt "store-coherence" "/fake/repo")
  [[ "$result" == *"/fake/repo"* ]] || return 1
}

# bats test_tags=fast
@test "architect: build_axis_prompt fails on unknown axis" {
  run build_axis_prompt "not-an-axis" "/fake/repo"
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "architect: build_axis_prompt covers all 8 axes without error" {
  for axis in "${ARCHITECT_AXES[@]}"; do
    run build_axis_prompt "$axis" "/fake/repo"
    [ "$status" -eq 0 ] || { echo "Failed for axis: $axis" >&2; false; }
    [ -n "$output" ] || { echo "Empty output for axis: $axis" >&2; false; }
  done
}

# ── build_architect_prompt ────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: build_architect_prompt contains JSON output format" {
  result=$(build_architect_prompt "type-safety" "/fake/repo" "TestProject")
  [[ "$result" == *'"findings"'* ]] || return 1
  [[ "$result" == *'"title"'* ]] || return 1
  [[ "$result" == *'"priority"'* ]] || return 1
}

# bats test_tags=fast
@test "architect: build_architect_prompt embeds axis display name" {
  result=$(build_architect_prompt "type-safety" "/fake/repo" "TestProject")
  [[ "$result" == *"Type-Safety"* ]] || return 1
}

# ── parse_architect_json ──────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: parse_architect_json extracts count and top finding" {
  cat > "$TEST_TMPDIR/arch-output.json" <<'EOF'
{
  "result": "```json\n{\"axis\": \"store-coherence\", \"axis_display\": \"Store Coherence\", \"summary\": \"Found issues.\", \"files_scanned\": 5, \"findings\": [{\"title\": \"Missing error state in workout store\", \"motivation\": \"...\", \"files\": [\"src/stores/workout.ts\"], \"proposed_approach\": \"Add try/catch\", \"priority\": 2, \"sequencing_notes\": \"\"}]}\n```",
  "usage": {"input_tokens": 10000, "output_tokens": 2000}
}
EOF
  result=$(parse_architect_json "$TEST_TMPDIR/arch-output.json")
  # Should be "count,top_title"
  [[ "$result" == *"Missing error state"* ]] || return 1
}

# bats test_tags=fast
@test "architect: parse_architect_json handles missing file" {
  result=$(parse_architect_json "$TEST_TMPDIR/nonexistent.json")
  [[ "$result" == "0,"* ]] || return 1
}

# ── parse_usage_architect ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "architect: parse_usage_architect extracts token counts" {
  cat > "$TEST_TMPDIR/usage.json" <<'EOF'
{"result": "...", "usage": {"input_tokens": 50000, "output_tokens": 8000, "cache_read_input_tokens": 5000, "cache_creation_input_tokens": 1000}}
EOF
  result=$(parse_usage_architect "$TEST_TMPDIR/usage.json")
  [ "$result" = "50000,8000,5000,1000" ]
}

# bats test_tags=fast
@test "architect: parse_usage_architect handles corrupt JSON" {
  echo "not json" > "$TEST_TMPDIR/bad.json"
  result=$(parse_usage_architect "$TEST_TMPDIR/bad.json")
  [ "$result" = "0,0,0,0" ]
}

# ── scripts/architect.sh: smoke ───────────────────────────────────────────────

# bats test_tags=fast
@test "architect: script has valid bash syntax" {
  bash -n "$PILOT_DIR/scripts/architect.sh"
}

# bats test_tags=fast
@test "architect: lib/architect-utils.sh has valid bash syntax" {
  bash -n "$PILOT_DIR/lib/architect-utils.sh"
}

# bats test_tags=fast
@test "architect: script rejects unknown --axis value" {
  export _PILOT_TEST_MODE=1
  export REPO_PATH="$TEST_TMPDIR/repo"
  export PILOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  mkdir -p "$REPO_PATH" "$OUTPUT_DIR"

  run bash "$PILOT_DIR/scripts/architect.sh" --axis "totally-made-up-axis"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown axis"* ]] || return 1
}

# bats test_tags=fast
@test "architect: script runs in test mode without crashing" {
  export _PILOT_TEST_MODE=1
  export REPO_PATH="$TEST_TMPDIR/repo"
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export PILOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
  mkdir -p "$REPO_PATH" "$OUTPUT_DIR"

  # Mock claude to return a canned Architect JSON response
  MOCK_CLAUDE_OUTPUT='{"result": "```json\n{\"axis\": \"store-coherence\", \"axis_display\": \"Store / State-Management Coherence\", \"summary\": \"Test summary.\", \"files_scanned\": 3, \"findings\": [{\"title\": \"Missing error handling in workout store\", \"motivation\": \"Actions lack try/catch.\", \"files\": [\"src/stores/workout.ts\"], \"proposed_approach\": \"Wrap async actions in try/catch.\", \"priority\": 2, \"sequencing_notes\": \"Do before adding new actions.\"}]}\n```", "usage": {"input_tokens": 1000, "output_tokens": 500}}'
  export MOCK_CLAUDE_OUTPUT
  export MOCK_CLAUDE_EXIT=0

  run bash "$PILOT_DIR/scripts/architect.sh" --axis "store-coherence"
  # Should exit 0 (or at least not crash hard — Claude mock may skip some paths)
  # In test mode, issue filing is suppressed, Slack is suppressed
  [ "$status" -eq 0 ]
  [[ "$output" == *"Architect run complete"* ]] || return 1
}

# bats test_tags=fast
@test "architect: idempotent — history CSV gets a row appended" {
  export _PILOT_TEST_MODE=1
  export REPO_PATH="$TEST_TMPDIR/repo"
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export PILOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
  mkdir -p "$REPO_PATH" "$OUTPUT_DIR"

  MOCK_CLAUDE_OUTPUT='{"result": "```json\n{\"axis\": \"type-safety\", \"axis_display\": \"Type-Safety Gaps\", \"summary\": \"Found 2 any casts.\", \"files_scanned\": 5, \"findings\": [{\"title\": \"Untyped Supabase query result in workout store\", \"motivation\": \"Cast to any hides runtime errors.\", \"files\": [\"src/stores/workout.ts\"], \"proposed_approach\": \"Generate types from schema.\", \"priority\": 2, \"sequencing_notes\": \"Block before next DB migration.\"}]}\n```", "usage": {"input_tokens": 2000, "output_tokens": 600}}'
  export MOCK_CLAUDE_OUTPUT
  export MOCK_CLAUDE_EXIT=0

  bash "$PILOT_DIR/scripts/architect.sh" --axis "type-safety" > /dev/null 2>&1

  HIST="$OUTPUT_DIR/architect-history.csv"
  [ -f "$HIST" ]
  ROW_COUNT=$(grep -c "type-safety" "$HIST" 2>/dev/null || echo "0")
  [ "$ROW_COUNT" -ge 1 ]
}

# bats test_tags=fast
@test "architect: axis rotation advances after first run" {
  export _PILOT_TEST_MODE=1
  HIST="$TEST_TMPDIR/arch-hist2.csv"
  echo "date,axis,files_scanned,findings,issues_filed,top_finding_summary" > "$HIST"

  # First run: nothing in history → should pick first axis
  first=$(select_axis "$HIST")
  [ "$first" = "store-coherence" ]

  # Simulate that axis was used
  echo "2026-04-29,store-coherence,10,3,3,some finding" >> "$HIST"

  # Second call: store-coherence has 1 run, everything else has 0 → should pick composable-quality
  second=$(select_axis "$HIST")
  [ "$second" = "composable-quality" ]
}
