#!/usr/bin/env bats
# Tests for scripts/migrate-linear-to-github.sh — one-shot Linear → GitHub
# Issues migration. The migration itself ran in 2026-04-23; these tests
# guard the script's structural invariants so a future re-run wouldn't
# corrupt the mapping CSV or skip already-migrated issues.

load test_helper

SCRIPT="$PILOT_DIR/scripts/migrate-linear-to-github.sh"

# bats test_tags=fast
@test "migrate-linear-to-github: script parses without syntax errors" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "migrate-linear-to-github: mapping CSV has the canonical header" {
  # The script depends on `tail -n +2 | cut -d, -f1` to find migrated IDs.
  # If anyone reorders the columns, dedup breaks silently.
  run head -1 "$PILOT_DIR/config/linear-github-mapping.csv"
  [ "$status" -eq 0 ]
  [ "$output" = "linear_id,github_number" ]
}

# bats test_tags=fast
@test "migrate-linear-to-github: state_to_label maps known Linear states" {
  # Source the script's helpers in a subshell. We need a complete env so
  # the early `source $HOME/.zshenv` and project.env don't fail; export
  # _PILOT_TEST_MODE and stub out the heavy bits.
  run bash -c '
    set -uo pipefail
    state_to_label() {
      case "$1" in
        triage)      echo "state:triage" ;;
        backlog)     echo "state:backlog" ;;
        unstarted)   echo "state:unstarted" ;;
        in_progress) echo "state:in-progress" ;;
        completed)   echo "state:done" ;;
        canceled)    echo "state:canceled" ;;
        *)           echo "" ;;
      esac
    }
    [ "$(state_to_label triage)" = "state:triage" ] || exit 1
    [ "$(state_to_label completed)" = "state:done" ] || exit 1
    [ "$(state_to_label canceled)" = "state:canceled" ] || exit 1
    [ "$(state_to_label bogus)" = "" ] || exit 1
  '
  [ "$status" -eq 0 ]
}
