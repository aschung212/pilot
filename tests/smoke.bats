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

# ── launchd plists ──────────────────────────────────────────────────────────
# A malformed or mis-pointed plist fails SILENTLY: launchd refuses to load it
# and the service simply never runs. That is the same invisible-failure family
# as the 2026-08-28 marker-format and list-truncation bugs, so it gets a guard.
#
# Plists carry absolute paths tied to Aaron's machine (/Users/aaron/...), which
# do not exist in CI. The path check therefore rebases any `.../pilot/scripts/X.sh`
# argument onto this checkout's own scripts/ directory — that catches typos,
# renames, and deletions without depending on where the repo lives.

# bats test_tags=fast
@test "smoke: every launchd plist is valid and well-formed" {
  bad=""
  for plist in "$PILOT_DIR"/launchd/*.plist; do
    plutil -lint "$plist" >/dev/null 2>&1 || bad+="  $(basename "$plist") — malformed\n"
  done
  if [ -n "$bad" ]; then echo -e "$bad" >&2; false; fi
}

# bats test_tags=fast
@test "smoke: every launchd plist points at a script this repo actually has" {
  run python3 - "$PILOT_DIR" <<'PYEOF'
import sys, os, glob, plistlib
root = sys.argv[1]
bad = []
for f in sorted(glob.glob(os.path.join(root, "launchd", "*.plist"))):
    with open(f, "rb") as fh:
        d = plistlib.load(fh)
    for arg in d.get("ProgramArguments", []):
        if not isinstance(arg, str) or not arg.endswith(".sh"):
            continue
        marker = "/pilot/scripts/"
        if marker in arg:
            local = os.path.join(root, "scripts", arg.split(marker, 1)[1])
            if not os.path.exists(local):
                bad.append(f"{os.path.basename(f)} -> {arg} (no {local})")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PYEOF
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

# bats test_tags=fast
@test "smoke: every launchd plist declares a Label and a schedule" {
  bad=""
  for plist in "$PILOT_DIR"/launchd/*.plist; do
    plutil -extract Label raw -o - "$plist" >/dev/null 2>&1 \
      || bad+="  $(basename "$plist") — no Label\n"
    if ! plutil -extract StartCalendarInterval raw -o - "$plist" >/dev/null 2>&1 \
       && ! plutil -extract StartInterval raw -o - "$plist" >/dev/null 2>&1; then
      bad+="  $(basename "$plist") — no StartCalendarInterval/StartInterval\n"
    fi
  done
  if [ -n "$bad" ]; then echo -e "$bad" >&2; false; fi
}
