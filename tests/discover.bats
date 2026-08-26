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
