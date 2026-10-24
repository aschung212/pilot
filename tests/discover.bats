#!/usr/bin/env bats
# Tests for scripts/discover.sh — focus area rotation and issue creation

load test_helper

# Pull a function definition out of the real script, so these tests exercise
# discover.sh itself rather than a pasted copy that can drift from it.
_load_discover_fn() {
  local def
  def=$(sed -n '/^'"$1"'() {$/,/^}$/p' "$PILOT_DIR/scripts/discover.sh")
  [ -n "$def" ] || { echo "function $1 not found in discover.sh" >&2; return 1; }
  eval "$def"
}

# bats test_tags=fast
@test "discover: queue refill produces the code-cleanup rotation" {
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  : > "$QUEUE_FILE"
  _load_discover_fn refill_queue
  refill_queue

  # dead-code leads the rotation
  [ "$(head -1 "$QUEUE_FILE")" = "dead-code" ]
  [ "$(wc -l < "$QUEUE_FILE" | tr -d ' ')" -eq 12 ]
  [ "$(grep -cx dead-code "$QUEUE_FILE")" -eq 3 ]
  [ "$(grep -cx duplication "$QUEUE_FILE")" -eq 3 ]
  [ "$(grep -cx complexity "$QUEUE_FILE")" -eq 2 ]
  [ "$(grep -cx consistency "$QUEUE_FILE")" -eq 2 ]
  [ "$(grep -cx type-safety "$QUEUE_FILE")" -eq 1 ]
  [ "$(grep -cx dependency-pruning "$QUEUE_FILE")" -eq 1 ]

  # GA-era and feature-hunting focuses are out of the rotation entirely
  ! grep -qE "bug-hunt|ux-polish|performance|accessibility|pwa-reliability|security-deps|competitors|monetization|marketing|growth|testing" "$QUEUE_FILE"
}

# bats test_tags=fast
@test "discover: every rotation focus has a case branch and maps to type:refactor" {
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  : > "$QUEUE_FILE"
  _load_discover_fn refill_queue
  _load_discover_fn focus_to_label
  refill_queue
  for focus in $(sort -u "$QUEUE_FILE"); do
    grep -qE "^  ${focus}\)" "$PILOT_DIR/scripts/discover.sh" \
      || { echo "no SEARCH_PROMPT branch for $focus" >&2; false; }
    [ "$(focus_to_label "$focus")" = "type:refactor" ] \
      || { echo "$focus does not map to type:refactor" >&2; false; }
  done
}

# bats test_tags=fast
@test "discover: stale queue version triggers regeneration" {
  # Mirror the version-guard logic from discover.sh
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  QUEUE_VERSION_FILE="$TEST_TMPDIR/queue.version"
  QUEUE_VERSION="2026-10-23-cleanup"

  # Simulate a live queue left over from an older rotation (no version file)
  printf 'testing\nmonetization\n' > "$QUEUE_FILE"

  if [ "$(cat "$QUEUE_VERSION_FILE" 2>/dev/null)" != "$QUEUE_VERSION" ]; then
    : > "$QUEUE_FILE"
    echo "$QUEUE_VERSION" > "$QUEUE_VERSION_FILE"
  fi

  # Stale entries were discarded and the version stamped
  [ ! -s "$QUEUE_FILE" ]
  [ "$(cat "$QUEUE_VERSION_FILE")" = "$QUEUE_VERSION" ]

  # A second run with a matching version leaves the queue alone
  printf 'dead-code\n' > "$QUEUE_FILE"
  if [ "$(cat "$QUEUE_VERSION_FILE" 2>/dev/null)" != "$QUEUE_VERSION" ]; then
    : > "$QUEUE_FILE"
  fi
  [ "$(head -1 "$QUEUE_FILE")" = "dead-code" ]
}

# bats test_tags=fast
@test "discover: focus_to_label maps correctly" {
  _load_discover_fn focus_to_label

  [ "$(focus_to_label dead-code)" = "type:refactor" ]
  [ "$(focus_to_label bug-hunt)" = "bug" ]
  [ "$(focus_to_label ux-polish)" = "UI/UX" ]
  [ "$(focus_to_label pwa-reliability)" = "PWA" ]
  [ "$(focus_to_label performance)" = "Performance" ]
  [ "$(focus_to_label accessibility)" = "Accessibility" ]
  [ "$(focus_to_label competitors)" = "Improvement" ]
  [ "$(focus_to_label seo-aso)" = "Growth" ]
  [ "$(focus_to_label unknown)" = "" ]
}

# bats test_tags=fast
@test "discover: ISSUE_DISCOVER line parsing" {
  # Test the regex that parses discovery output
  RUN_LOG="$TEST_TMPDIR/run.md"
  cat > "$RUN_LOG" <<'LOG'
## Discoveries
ISSUE_DISCOVER:2:Add haptic feedback|Strong and Hevy both use haptic feedback
ISSUE_DISCOVER:3:Add streak counter|Duolingo-style streak tracking
ISSUE_DISCOVER:1:Fix XSS in input field|User input not sanitized
LOG

  COUNT=$(grep -oE 'ISSUE_DISCOVER:[1-4]:' "$RUN_LOG" | wc -l | tr -d ' ')
  [ "$COUNT" -eq 3 ]

  # Parse priorities
  PRIORITIES=$(grep -oE 'ISSUE_DISCOVER:[1-4]:' "$RUN_LOG" | grep -oE '[1-4]' | sort | tr '\n' '/')
  [[ "$PRIORITIES" == *"1"* ]] || return 1
  [[ "$PRIORITIES" == *"2"* ]] || return 1
  [[ "$PRIORITIES" == *"3"* ]] || return 1
}

# bats test_tags=fast
@test "discover: SEARCH line parsing for log" {
  RUN_LOG="$TEST_TMPDIR/run.md"
  cat > "$RUN_LOG" <<'LOG'
SEARCH:vue 3 performance optimization 2026
SEARCH:https://reddit.com/r/fitness/top
SEARCH:strong app vs hevy comparison
LOG

  COUNT=$(grep -c "^SEARCH:" "$RUN_LOG")
  [ "$COUNT" -eq 3 ]
}

# bats test_tags=fast
@test "discover: CLI argument overrides focus area" {
  # The script checks: if [ -n "${1:-}" ]; then FOCUS="${1}"
  FOCUS=""
  ARG="security-deps"
  if [ -n "${ARG:-}" ]; then
    FOCUS="$ARG"
  fi
  [ "$FOCUS" = "security-deps" ]
}

# bats test_tags=fast
@test "discover: lost-findings guard fires only without the zero-sentinel" {
  # Mirror the fail-loud check from discover.sh (2026-08-26): zero parsed
  # discoveries + zero inline-created issues is only OK when the final message
  # declares "No discoveries met the bar".
  check_lost() { # $1=run log file, $2=count, $3=created — returns 0 if alert should fire
    [ "$2" -eq 0 ] && [ "${3:-0}" -eq 0 ] \
      && ! grep -qi "No discoveries met the bar" "$1" 2>/dev/null
  }

  RUN_LOG="$TEST_TMPDIR/run.md"

  # Stranded-findings run: prose only, no sentinel → alert
  echo "Six verified bugs filed as discoveries above." > "$RUN_LOG"
  run check_lost "$RUN_LOG" 0 0
  [ "$status" -eq 0 ]

  # Legitimate empty run: sentinel present → no alert
  echo "No discoveries met the bar this run" > "$RUN_LOG"
  run check_lost "$RUN_LOG" 0 0
  [ "$status" -eq 1 ]

  # Findings parsed → no alert regardless of sentinel
  echo "ISSUE_DISCOVER:2:Fix thing|details" > "$RUN_LOG"
  run check_lost "$RUN_LOG" 1 0
  [ "$status" -eq 1 ]

  # Issues created inline (gh URLs) → no alert
  echo "created https://github.com/o/r/issues/12" > "$RUN_LOG"
  run check_lost "$RUN_LOG" 0 1
  [ "$status" -eq 1 ]
}

# bats test_tags=fast
@test "discover: Phase 1 fallback allowlist actually grants Claude web access" {
  # Regression guard for 2026-08-30. The Phase 1 failure path has always told the
  # operator "Claude will self-research", but DISCOVER_ALLOWED_TOOLS carried no web
  # tool, so on every Gemini failure Claude silently degraded to codebase-only
  # introspection. Assert against the SHIPPED script, not a copy of the string.
  run grep -E '^DISCOVER_ALLOWED_TOOLS=' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WebSearch"* ]] || return 1
  [[ "$output" == *"WebFetch"* ]] || return 1

  # The promise and the capability must stay in sync: if the fallback message
  # still claims self-research, the tools above are what make it true.
  run grep -c 'Claude self-researches\|Claude will self-research' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "discover: research adapter is called grounded (grounding is why Gemini is here)" {
  # Discovery's Phase 1 must NOT pass --no-grounding. Ungrounded Flash returns
  # unsourced prose; grounded is the entire reason this call exists. triage.sh is
  # the one caller that legitimately passes --no-grounding.
  run grep -n 'AI_RESEARCH" prompt "\$RESEARCH_PROMPT"' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-grounding"* ]] || return 1
}

# ── Research backend toggle (added 2026-08-30) ───────────────────────────────

# Extract the REAL backend-order case block from the shipped script and eval it.
# Deliberately not a copy: tune-budget.bats had five green tests over pasted logic
# while the script itself had never once worked.
_research_order_for() {
  local backend="$1"
  local block
  block=$(sed -n '/^case "\$DISCOVER_RESEARCH_BACKEND" in/,/^esac/p' "$PILOT_DIR/scripts/discover.sh")
  [ -n "$block" ] || return 1
  # The unknown-backend branch tee's a warning to stdout on purpose, so run the
  # block with stdout discarded and emit RESEARCH_ORDER on fd 3.
  DISCOVER_RESEARCH_BACKEND="$backend" RUN_LOG="$TEST_TMPDIR/run.log" \
    bash -c "{ $block
} >/dev/null 2>&1; printf '%s' \"\$RESEARCH_ORDER\""
}

# bats test_tags=fast
@test "discover: backend toggle picks the named backend first and the other as fallback" {
  [ "$(_research_order_for claude)" = "claude gemini" ]
  [ "$(_research_order_for gemini)" = "gemini claude" ]
}

# bats test_tags=fast
@test "discover: the -only backend forms disable the fallback" {
  [ "$(_research_order_for claude-only)" = "claude" ]
  [ "$(_research_order_for gemini-only)" = "gemini" ]
}

# bats test_tags=fast
@test "discover: an unknown backend value degrades to the default pair, not to nothing" {
  # An empty RESEARCH_ORDER would skip Phase 1 entirely and silently.
  [ "$(_research_order_for wat)" = "claude gemini" ]
}

# bats test_tags=fast
@test "discover: Phase 1 passes --backend to the adapter and tries each in order" {
  run grep -n 'for _backend in \$RESEARCH_ORDER' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
  run grep -n -- '--backend "\$_backend"' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "discover: total research failure still alerts and names every backend tried" {
  run grep -c 'web research FAILED on every backend' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
  run grep -c 'Tried: \$RESEARCH_ORDER' "$PILOT_DIR/scripts/discover.sh"
  [ "$status" -eq 0 ]
}
