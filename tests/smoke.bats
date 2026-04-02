#!/usr/bin/env bats
# Smoke tests — auto-discover all scripts and verify basic health.
# These tests grow automatically when new scripts are added.

load test_helper

# ── Every script must have a corresponding .bats file ────────────────────────

# bats test_tags=fast
@test "smoke: every script in scripts/ has a test file" {
  missing=""
  for script in "$PILOT_DIR"/scripts/*.sh; do
    name=$(basename "$script" .sh)
    if [ ! -f "$TEST_DIR/${name}.bats" ]; then
      missing+="  $name.sh\n"
    fi
  done
  if [ -n "$missing" ]; then
    echo "Missing test files for:" >&2
    echo -e "$missing" >&2
    false
  fi
}

# bats test_tags=fast
@test "smoke: every adapter in adapters/ has a test file" {
  missing=""
  for script in "$PILOT_DIR"/adapters/*.sh; do
    name=$(basename "$script" .sh)
    if [ ! -f "$TEST_DIR/${name}.bats" ]; then
      missing+="  $name.sh\n"
    fi
  done
  if [ -n "$missing" ]; then
    echo "Missing test files for:" >&2
    echo -e "$missing" >&2
    false
  fi
}

# ── Every script must parse without syntax errors ────────────────────────────

# bats test_tags=fast
@test "smoke: all scripts have valid bash syntax" {
  errors=""
  for script in "$PILOT_DIR"/scripts/*.sh "$PILOT_DIR"/adapters/*.sh "$PILOT_DIR"/lib/*.sh; do
    if ! bash -n "$script" 2>/dev/null; then
      errors+="  $(basename "$script")\n"
    fi
  done
  if [ -n "$errors" ]; then
    echo "Syntax errors in:" >&2
    echo -e "$errors" >&2
    false
  fi
}

# ── Every adapter rejects unknown commands ───────────────────────────────────

# bats test_tags=fast
@test "smoke: all adapters exit 1 on unknown command" {
  failures=""
  for script in "$PILOT_DIR"/adapters/*.sh; do
    name=$(basename "$script" .sh)
    run bash "$script" __nonexistent_command__
    if [ "$status" -ne 1 ]; then
      failures+="  $name (exit $status)\n"
    fi
  done
  if [ -n "$failures" ]; then
    echo "Adapters that don't reject unknown commands:" >&2
    echo -e "$failures" >&2
    false
  fi
}
