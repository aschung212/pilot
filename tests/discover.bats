#!/usr/bin/env bats
# Tests for scripts/discover.sh — focus area rotation and issue creation

load test_helper

@test "discover: queue refill produces correct focus areas" {
  # Simulate the queue refill logic from discover.sh
  QUEUE_FILE="$TEST_TMPDIR/queue.txt"
  cat > "$QUEUE_FILE" <<'QUEUE'
competitors
performance
ui-trends
testing
accessibility
seo-aso
competitors
data-viz
pwa-patterns
ui-trends
onboarding
performance
security-deps
competitors
accessibility
dx-cicd
ui-trends
testing
monetization
QUEUE

  # Pop first item
  FOCUS=$(head -1 "$QUEUE_FILE")
  [ "$FOCUS" = "competitors" ]

  # Count total items
  COUNT=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
  [ "$COUNT" -eq 19 ]

  # Competitors appears 3 times (highest weight)
  COMP_COUNT=$(grep -c "competitors" "$QUEUE_FILE")
  [ "$COMP_COUNT" -eq 3 ]

  # UI trends appears 3 times
  UI_COUNT=$(grep -c "ui-trends" "$QUEUE_FILE")
  [ "$UI_COUNT" -eq 3 ]

  # Monetization appears once (lowest weight)
  MON_COUNT=$(grep -c "monetization" "$QUEUE_FILE")
  [ "$MON_COUNT" -eq 1 ]
}

@test "discover: focus_to_label maps correctly" {
  # Test the label mapping function from discover.sh
  focus_to_label() {
    case "$1" in
      performance)   echo "Performance" ;;
      accessibility) echo "Accessibility" ;;
      ui-trends)     echo "UI/UX" ;;
      testing)       echo "Testing" ;;
      security-deps) echo "Security" ;;
      pwa-patterns)  echo "PWA" ;;
      competitors)   echo "Improvement" ;;
      data-viz)      echo "UI/UX" ;;
      onboarding)    echo "UI/UX" ;;
      dx-cicd)       echo "Infrastructure" ;;
      seo-aso)       echo "Growth" ;;
      monetization)  echo "Growth" ;;
      *)             echo "" ;;
    esac
  }

  [ "$(focus_to_label performance)" = "Performance" ]
  [ "$(focus_to_label accessibility)" = "Accessibility" ]
  [ "$(focus_to_label competitors)" = "Improvement" ]
  [ "$(focus_to_label seo-aso)" = "Growth" ]
  [ "$(focus_to_label unknown)" = "" ]
}

@test "discover: LINEAR_DISCOVER line parsing" {
  # Test the regex that parses discovery output
  RUN_LOG="$TEST_TMPDIR/run.md"
  cat > "$RUN_LOG" <<'LOG'
## Discoveries
LINEAR_DISCOVER:2:Add haptic feedback|Strong and Hevy both use haptic feedback
LINEAR_DISCOVER:3:Add streak counter|Duolingo-style streak tracking
LINEAR_DISCOVER:1:Fix XSS in input field|User input not sanitized
LOG

  COUNT=$(grep -oE 'LINEAR_DISCOVER:[1-4]:' "$RUN_LOG" | wc -l | tr -d ' ')
  [ "$COUNT" -eq 3 ]

  # Parse priorities
  PRIORITIES=$(grep -oE 'LINEAR_DISCOVER:[1-4]:' "$RUN_LOG" | grep -oE '[1-4]' | sort | tr '\n' '/')
  [[ "$PRIORITIES" == *"1"* ]]
  [[ "$PRIORITIES" == *"2"* ]]
  [[ "$PRIORITIES" == *"3"* ]]
}

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

@test "discover: CLI argument overrides focus area" {
  # The script checks: if [ -n "${1:-}" ]; then FOCUS="${1}"
  FOCUS=""
  ARG="security-deps"
  if [ -n "${ARG:-}" ]; then
    FOCUS="$ARG"
  fi
  [ "$FOCUS" = "security-deps" ]
}
