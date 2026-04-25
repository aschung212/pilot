#!/usr/bin/env bats
# Tests for scripts/capture-pr-screenshots.sh
#
# These cover the wrapper's edge-case handling (no routes, no playwright in
# target repo). The actual browser-launch path requires Lift's node_modules
# and a working dev server, so it's exercised end-to-end during overnight
# builder runs rather than in CI.

load test_helper

SCRIPT="$PILOT_DIR/scripts/capture-pr-screenshots.sh"

# bats test_tags=fast
@test "capture-pr-screenshots: missing repo dir arg exits non-zero" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "capture-pr-screenshots: no routes provided exits 0 with skip message" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No routes provided"* ]]
}

# bats test_tags=fast
@test "capture-pr-screenshots: missing playwright in target repo exits 0 with skip message" {
  # Create a fake repo with no node_modules.
  mkdir -p "$BATS_TEST_TMPDIR/fake-repo"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/fake-repo" "$BATS_TEST_TMPDIR/out" "/some/route"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Playwright not installed"* ]]
}
