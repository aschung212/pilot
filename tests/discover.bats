#!/usr/bin/env bats
# Tests for scripts/discover.sh — focus area rotation and issue creation

load test_helper

# bats test_tags=fast
@test "discover: queue refill produces correct GA focus areas" {
  # Mirror the GA-readiness refill queue from discover.sh (2026-08-21)
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  cat > "$QUEUE_FILE" <<'QUEUE'
bug-hunt
performance
ux-polish
accessibility
bug-hunt
pwa-reliability
ux-polish
performance
bug-hunt
security-deps
ux-polish
accessibility
bug-hunt
performance
pwa-reliability
ux-polish
bug-hunt
accessibility
performance
security-deps
QUEUE

  # Pop first item — bug-hunt leads the GA rotation
  FOCUS=$(head -1 "$QUEUE_FILE")
  [ "$FOCUS" = "bug-hunt" ]

  # Count total items
  COUNT=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
  [ "$COUNT" -eq 20 ]

  # bug-hunt appears 5 times (highest weight)
  BUG_COUNT=$(grep -c "bug-hunt" "$QUEUE_FILE")
  [ "$BUG_COUNT" -eq 5 ]

  # ux-polish appears 4 times
  UX_COUNT=$(grep -c "ux-polish" "$QUEUE_FILE")
  [ "$UX_COUNT" -eq 4 ]

  # security-deps appears twice (lowest weight)
  SEC_COUNT=$(grep -c "security-deps" "$QUEUE_FILE")
  [ "$SEC_COUNT" -eq 2 ]

  # Feature-hunting focuses are retired from the rotation entirely
  ! grep -qE "competitors|monetization|marketing|growth|testing|ui-trends|onboarding|data-viz|seo-aso|dx-cicd" "$QUEUE_FILE"
}

# bats test_tags=fast
@test "discover: stale queue version triggers regeneration" {
  # Mirror the version-guard logic from discover.sh
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  QUEUE_VERSION_FILE="$TEST_TMPDIR/queue.version"
  QUEUE_VERSION="2026-08-21-ga"

  # Simulate a live queue left over from the pre-GA rotation (no version file)
  printf 'testing\nmonetization\n' > "$QUEUE_FILE"

  if [ "$(cat "$QUEUE_VERSION_FILE" 2>/dev/null)" != "$QUEUE_VERSION" ]; then
    : > "$QUEUE_FILE"
    echo "$QUEUE_VERSION" > "$QUEUE_VERSION_FILE"
  fi

  # Stale entries were discarded and the version stamped
  [ ! -s "$QUEUE_FILE" ]
  [ "$(cat "$QUEUE_VERSION_FILE")" = "$QUEUE_VERSION" ]

  # A second run with a matching version leaves the queue alone
  printf 'bug-hunt\n' > "$QUEUE_FILE"
  if [ "$(cat "$QUEUE_VERSION_FILE" 2>/dev/null)" != "$QUEUE_VERSION" ]; then
    : > "$QUEUE_FILE"
  fi
  [ "$(head -1 "$QUEUE_FILE")" = "bug-hunt" ]
}

# bats test_tags=fast
@test "discover: focus_to_label maps correctly" {
  # Test the label mapping function from discover.sh
  focus_to_label() {
    case "$1" in
      bug-hunt)        echo "bug" ;;
      ux-polish)       echo "UI/UX" ;;
      pwa-reliability) echo "PWA" ;;
      performance)     echo "Performance" ;;
      accessibility)   echo "Accessibility" ;;
      ui-trends)       echo "UI/UX" ;;
      testing)         echo "Testing" ;;
      security-deps)   echo "Security" ;;
      pwa-patterns)    echo "PWA" ;;
      competitors)     echo "Improvement" ;;
      data-viz)        echo "UI/UX" ;;
      onboarding)      echo "UI/UX" ;;
      dx-cicd)         echo "Infrastructure" ;;
      seo-aso)         echo "Growth" ;;
      monetization)    echo "Growth" ;;
      marketing)       echo "Marketing" ;;
      growth)          echo "Growth" ;;
      *)               echo "" ;;
    esac
  }

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
  [[ "$PRIORITIES" == *"1"* ]]
  [[ "$PRIORITIES" == *"2"* ]]
  [[ "$PRIORITIES" == *"3"* ]]
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
  [[ "$output" == *"WebSearch"* ]]
  [[ "$output" == *"WebFetch"* ]]

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
  [[ "$output" != *"--no-grounding"* ]]
}
