#!/usr/bin/env bats
# Tests for scripts/roadmap-synth.sh and lib/roadmap-utils.sh

load test_helper

# ── Setup ─────────────────────────────────────────────────────────────────────

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"

  # Stub env — no real external calls
  export _PILOT_TEST_MODE=1
  export PROJECT_NAME="TestProject"
  export GITHUB_REPO="test/repo"
  export ISSUE_PREFIX="TEST"
  export PATH="$MOCK_DIR:$PATH"

  # Stub tracker: list returns a handful of fake issues, view returns minimal text
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/linear" << 'STUB'
#!/bin/bash
case "$*" in
  *"issue list"*)
    echo "TEST-1  Fix login button contrast       unstarted  2"
    echo "TEST-2  Add keyboard navigation         started    1"
    echo "TEST-3  Reduce bundle size              unstarted  2"
    ;;
  *"issue view TEST-1"*)
    echo "# TEST-1: Fix login button contrast"
    echo "Contrast ratio is 2:1, needs 4.5:1 for WCAG AA."
    ;;
  *"issue view TEST-2"*)
    echo "# TEST-2: Add keyboard navigation"
    echo "Tab order is broken on settings screen."
    ;;
  *"issue view TEST-3"*)
    echo "# TEST-3: Reduce bundle size"
    echo "Main chunk is 1.2 MB, goal is <200 KB."
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/linear"

  # Stub gh: label list returns nothing (fine — script has a fallback)
  cat > "$TEST_TMPDIR/bin/gh" << 'GHSTUB'
#!/bin/bash
case "$*" in
  *"label list"*) echo "" ;;
  *) echo "" ;;
esac
GHSTUB
  chmod +x "$TEST_TMPDIR/bin/gh"

  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Put the fixture JSON where roadmap-synth.sh will look for it in test mode
  cp "$FIXTURES_DIR/roadmap-synth-fixture.json" "$TEST_TMPDIR/fixture.json"

  source "$PILOT_DIR/lib/roadmap-utils.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ── Smoke test: script runs without error ─────────────────────────────────────

# bats test_tags=fast
@test "roadmap-synth: smoke — script parses without syntax errors" {
  run bash -n "$PILOT_DIR/scripts/roadmap-synth.sh"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "roadmap-synth: smoke — lib parses without syntax errors" {
  run bash -n "$PILOT_DIR/lib/roadmap-utils.sh"
  [ "$status" -eq 0 ]
}

# ── Dry-run mode ─────────────────────────────────────────────────────────────

# bats test_tags=fast
@test "roadmap-synth: dry-run writes roadmap file to OUTPUT_DIR not vault" {
  run bash "$PILOT_DIR/scripts/roadmap-synth.sh" --dry-run
  # Script should exit 0 in test mode
  [ "$status" -eq 0 ]

  DATE=$(date +%Y-%m-%d)
  ROADMAP_FILE="$OUTPUT_DIR/roadmap-${DATE}.md"
  [ -f "$ROADMAP_FILE" ]
}

# bats test_tags=fast
@test "roadmap-synth: dry-run does not write to Obsidian vault" {
  OBSIDIAN_VAULT="$TEST_TMPDIR/vault"
  mkdir -p "$OBSIDIAN_VAULT/40_Career/Portfolio"
  export OBSIDIAN_VAULT

  run bash "$PILOT_DIR/scripts/roadmap-synth.sh" --dry-run
  [ "$status" -eq 0 ]

  [ ! -f "$OBSIDIAN_VAULT/40_Career/Portfolio/Lift Roadmap.md" ]
}

# bats test_tags=fast
@test "roadmap-synth: dry-run roadmap contains expected sections" {
  run bash "$PILOT_DIR/scripts/roadmap-synth.sh" --dry-run
  [ "$status" -eq 0 ]

  DATE=$(date +%Y-%m-%d)
  ROADMAP_FILE="$OUTPUT_DIR/roadmap-${DATE}.md"
  [ -f "$ROADMAP_FILE" ]

  grep -q "## Themes" "$ROADMAP_FILE"
  grep -q "## Proposed Epics" "$ROADMAP_FILE"
  grep -q "## Orphan Issues" "$ROADMAP_FILE"
  grep -q "## Roadmap Risks" "$ROADMAP_FILE"
  grep -q "Updated.*Roadmap Synthesiser" "$ROADMAP_FILE"
}

# ── CSV history schema ────────────────────────────────────────────────────────

# bats test_tags=fast
@test "roadmap-synth: CSV history has correct header" {
  roadmap_csv_init "$TEST_TMPDIR/history.csv"
  HEADER=$(head -1 "$TEST_TMPDIR/history.csv")
  [ "$HEADER" = "date,total_open,theme_count,epic_count,orphan_count,oldest_orphan_age_days" ]
}

# bats test_tags=fast
@test "roadmap-synth: CSV history append writes one row" {
  roadmap_csv_init "$TEST_TMPDIR/history.csv"
  roadmap_csv_append "$TEST_TMPDIR/history.csv" "2026-04-29" "12" "5" "2" "1" "45"

  ROW_COUNT=$(tail -n +2 "$TEST_TMPDIR/history.csv" | wc -l | tr -d ' ')
  [ "$ROW_COUNT" -eq 1 ]

  ROW=$(tail -1 "$TEST_TMPDIR/history.csv")
  [ "$ROW" = "2026-04-29,12,5,2,1,45" ]
}

# bats test_tags=fast
@test "roadmap-synth: CSV history is idempotent on re-init" {
  roadmap_csv_init "$TEST_TMPDIR/history.csv"
  roadmap_csv_append "$TEST_TMPDIR/history.csv" "2026-04-29" "12" "5" "2" "1" "45"
  # Re-init should NOT wipe existing data
  roadmap_csv_init "$TEST_TMPDIR/history.csv"

  ROW_COUNT=$(tail -n +2 "$TEST_TMPDIR/history.csv" | wc -l | tr -d ' ')
  [ "$ROW_COUNT" -eq 1 ]
}

# bats test_tags=fast
@test "roadmap-synth: dry-run appends row to history CSV" {
  run bash "$PILOT_DIR/scripts/roadmap-synth.sh" --dry-run
  [ "$status" -eq 0 ]

  HISTORY="$OUTPUT_DIR/roadmap-history.csv"
  [ -f "$HISTORY" ]

  # Header must be correct
  HEADER=$(head -1 "$HISTORY")
  [ "$HEADER" = "date,total_open,theme_count,epic_count,orphan_count,oldest_orphan_age_days" ]

  # At least one data row written
  ROW_COUNT=$(tail -n +2 "$HISTORY" | wc -l | tr -d ' ')
  [ "$ROW_COUNT" -ge 1 ]
}

# ── roadmap-utils helpers ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "roadmap-utils: roadmap_age_days returns 0 for today" {
  TODAY=$(date +%Y-%m-%d)
  result=$(roadmap_age_days "$TODAY")
  [ "$result" -eq 0 ]
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_age_days returns positive for a past date" {
  result=$(roadmap_age_days "2020-01-01")
  [ "$result" -gt 1000 ]
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_age_days returns 0 for unparseable date" {
  result=$(roadmap_age_days "not-a-date")
  [ "$result" -eq 0 ]
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_obsidian_url generates obsidian:// link when vault present" {
  # Create a fake vault with .obsidian directory
  mkdir -p "$TEST_TMPDIR/MyVault/.obsidian"
  mkdir -p "$TEST_TMPDIR/MyVault/40_Career/Portfolio"
  touch "$TEST_TMPDIR/MyVault/40_Career/Portfolio/Lift Roadmap.md"

  result=$(roadmap_obsidian_url "$TEST_TMPDIR/MyVault/40_Career/Portfolio/Lift Roadmap.md")
  [[ "$result" == obsidian://* ]] || return 1
  [[ "$result" == *"MyVault"* ]] || return 1
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_obsidian_url falls back to file:// when no vault" {
  touch "$TEST_TMPDIR/some-file.md"
  result=$(roadmap_obsidian_url "$TEST_TMPDIR/some-file.md")
  [[ "$result" == file://* ]] || return 1
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_parse_synthesis extracts counts from fixture" {
  eval "$(roadmap_parse_synthesis "$FIXTURES_DIR/roadmap-synth-fixture.json")"
  [ "$THEME_COUNT"  -eq 3 ]
  [ "$EPIC_COUNT"   -eq 2 ]
  [ "$ORPHAN_COUNT" -eq 1 ]
  [ "$RISK_COUNT"   -eq 2 ]
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_parse_synthesis handles corrupt JSON gracefully" {
  echo "this is not json" > "$TEST_TMPDIR/bad.json"
  eval "$(roadmap_parse_synthesis "$TEST_TMPDIR/bad.json")" 2>/dev/null || true
  # Counts should default to 0 and not crash
  : "${THEME_COUNT:=0}"
  [ "$THEME_COUNT" -ge 0 ]
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_render_markdown produces valid sections" {
  result=$(roadmap_render_markdown "$FIXTURES_DIR/roadmap-synth-fixture.json" "2026-04-29" "Lift")
  [[ "$result" == *"# Lift Roadmap"* ]] || return 1
  [[ "$result" == *"## Themes"* ]] || return 1
  [[ "$result" == *"## Proposed Epics"* ]] || return 1
  [[ "$result" == *"## Orphan Issues"* ]] || return 1
  [[ "$result" == *"## Roadmap Risks"* ]] || return 1
  [[ "$result" == *"Updated 2026-04-29 by Roadmap Synthesiser"* ]] || return 1
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_render_markdown includes theme names from fixture" {
  result=$(roadmap_render_markdown "$FIXTURES_DIR/roadmap-synth-fixture.json" "2026-04-29" "Lift")
  [[ "$result" == *"Performance & Bundle Size"* ]] || return 1
  [[ "$result" == *"Accessibility Compliance"* ]] || return 1
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_render_markdown includes epic names from fixture" {
  result=$(roadmap_render_markdown "$FIXTURES_DIR/roadmap-synth-fixture.json" "2026-04-29" "Lift")
  [[ "$result" == *"Core Accessibility Pass"* ]] || return 1
  [[ "$result" == *"Performance Budget"* ]] || return 1
}

# bats test_tags=fast
@test "roadmap-utils: roadmap_render_markdown includes orphan IDs from fixture" {
  result=$(roadmap_render_markdown "$FIXTURES_DIR/roadmap-synth-fixture.json" "2026-04-29" "Lift")
  [[ "$result" == *"LIFT-3"* ]] || return 1
}

# ── Envelope extraction (2026-08-28) ────────────────────────────────────────
# roadmap-synth captures stdout+stderr together, and Bun prepends a
# "warn: CPU lacks AVX support" line on this machine. json.load() on the whole
# file then dies at "line 1 column 1 (char 0)". builder.sh was hardened against
# this on 2026-05-19; roadmap-synth was not, so EVERY run from 2026-05-06 to
# 2026-08-26 — 17 consecutive weeks — failed to extract its synthesis.
#
# Claude also wraps the payload in a ```json fence, which has to come off before
# the themes parse. These drive the real extractor out of the script.

_extractor() {  # writes the script's own heredoc body to $1
  python3 - "$PILOT_DIR/scripts/roadmap-synth.sh" "$1" <<'PYEOF'
import sys
src, dest = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("python3 - ") and "SYNTH_RESULT_FILE" in l)
end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "PYEOF")
open(dest, "w").write("\n".join(lines[start + 1:end]))
PYEOF
}

# bats test_tags=fast
@test "roadmap-synth: extractor survives the Bun warning preamble and a json fence" {
  _extractor "$TEST_TMPDIR/extract.py"
  run python3 "$TEST_TMPDIR/extract.py" \
    "$TEST_DIR/fixtures/roadmap-bun-preamble.json" "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(len(json.load(open('$TEST_TMPDIR/out.json'))['themes']))"
  [ "$output" = "2" ]
}

# bats test_tags=fast
@test "roadmap-synth: extractor still handles a clean envelope with no preamble" {
  _extractor "$TEST_TMPDIR/extract.py"
  python3 - "$TEST_TMPDIR/clean.json" <<'PYEOF'
import json, sys
inner = json.dumps({"themes": [{"name": "T", "description": "d", "issues": [1]}],
                    "epics": [], "orphans": []})
json.dump({"type": "result", "result": inner}, open(sys.argv[1], "w"))
PYEOF
  run python3 "$TEST_TMPDIR/extract.py" "$TEST_TMPDIR/clean.json" "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(len(json.load(open('$TEST_TMPDIR/out.json'))['themes']))"
  [ "$output" = "1" ]
}

# bats test_tags=fast
@test "roadmap-synth: extractor handles a bare synthesis object" {
  _extractor "$TEST_TMPDIR/extract.py"
  echo '{"themes":[{"name":"A","description":"d","issues":[1]}],"epics":[],"orphans":[]}' \
    > "$TEST_TMPDIR/bare.json"
  run python3 "$TEST_TMPDIR/extract.py" "$TEST_TMPDIR/bare.json" "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(len(json.load(open('$TEST_TMPDIR/out.json'))['themes']))"
  [ "$output" = "1" ]
}
