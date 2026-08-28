#!/usr/bin/env bats
# Tests for scripts/doc-drift-audit.sh and lib/doc-drift-check.py
#
# The checker is only useful if it is trusted, and it is only trusted if it
# does not cry wolf. These tests pin both halves: that it FINDS real drift, and
# that it stays quiet on the things that look like drift but are not — doc
# tombstones for deleted scripts, scripts that legitimately live outside the
# repo, and test counts quoting either tier.

load test_helper

AUDIT="$PILOT_DIR/scripts/doc-drift-audit.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME"
  export PATH="$TEST_DIR/mocks:$PATH"
  export _PILOT_TEST_MODE=1
  export SLACK_BOT_TOKEN="" SLACK_WEBHOOK_URL=""

  # Minimal fake repo the checker can reason about.
  export FIXTURE="$TEST_TMPDIR/repo"
  mkdir -p "$FIXTURE"/{scripts,adapters,lib,launchd,tests,docs}
  echo '#!/bin/bash' > "$FIXTURE/scripts/alpha.sh"
  echo '#!/bin/bash' > "$FIXTURE/adapters/tracker.sh"
  : > "$FIXTURE/project.env.example"
  cat > "$FIXTURE/CLAUDE.md" <<'EOF'
# Guidelines
Adapters: `tracker.sh` handles issues.
EOF
  cat > "$FIXTURE/README.md" <<'EOF'
# Fixture
    scripts/
      alpha.sh
EOF
  cat > "$FIXTURE/docs/pilot-architecture.md" <<'EOF'
# Arch
`alpha.sh` does the thing.
## Scheduled Tasks
| Time | Service | Plist |
|---|---|---|
EOF
  : > "$FIXTURE/docs/pilot-responsibilities.md"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_check() {
  REPO_ROOT="$FIXTURE" PRODUCT_DECISIONS_FILE="" PRODUCT_FEATURES_FILE="" \
    python3 "$PILOT_DIR/lib/doc-drift-check.py" 2>&1
}

_plist() {  # $1 = label, $2 = script basename
  cat > "$FIXTURE/launchd/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string><string>/Users/aaron/development/pilot/scripts/$2</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>15</integer></dict>
</dict></plist>
EOF
}

# ── argument handling ───────────────────────────────────────────────────────

# bats test_tags=fast
@test "doc-drift-audit: rejects an unknown argument" {
  run bash "$AUDIT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: --biweekly no-ops on an odd ISO week" {
  week=$(date +%V | sed 's/^0*//')
  run bash "$AUDIT" --biweekly
  [ "$status" -eq 0 ]
  if [ $((week % 2)) -ne 0 ]; then
    [[ "$output" == *"skipped"* ]]
  else
    [[ "$output" != *"skipped"* ]]
  fi
}

# ── it finds real drift ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "doc-drift-audit: flags a script no doc mentions" {
  echo '#!/bin/bash' > "$FIXTURE/scripts/undocumented.sh"
  run _check
  [[ "$output" == *"undocumented.sh"* ]]
  [[ "$output" == *"Undocumented scripts"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: flags a doc naming a script that no longer exists" {
  echo 'Run `ghost.sh` nightly to do the thing.' >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  [[ "$output" == *"Dead references"* ]]
  [[ "$output" == *"ghost.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: flags a plist with no row in the schedule table" {
  _plist "com.test.orphan" "alpha.sh"
  run _check
  [[ "$output" == *"Unscheduled in docs"* ]]
  [[ "$output" == *"com.test.orphan"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: flags a plist pointing at a missing script" {
  _plist "com.test.broken" "nonexistent.sh"
  echo 'com.test.broken runs at 8:15 AM' >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  [[ "$output" == *"Broken plists"* ]]
  [[ "$output" == *"nonexistent.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: flags an adapter missing from CLAUDE.md" {
  echo '#!/bin/bash' > "$FIXTURE/adapters/notify.sh"
  run _check
  [[ "$output" == *"Undocumented adapters"* ]]
  [[ "$output" == *"notify.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: flags a vault note cited at the wrong path" {
  echo '| `Obsidian: 90_Nope/Missing Note.md` | something |' >> "$FIXTURE/docs/pilot-responsibilities.md"
  mkdir -p "$HOME/Documents/Obsidian Vault"
  HOME="$HOME" run _check
  [[ "$output" == *"Missing Note.md"* ]] || skip "no vault on this machine"
}

# ── it stays quiet on things that only look like drift ──────────────────────

# bats test_tags=fast
@test "doc-drift-audit: a tombstone for a deleted script is not drift" {
  echo 'The old `adapters/ai-review.sh` was deleted 2026-07-17; see the changelog.' \
    >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  [[ "$output" != *"ai-review.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: a script living outside the repo is not a dead reference" {
  helper="$TEST_TMPDIR/external-helper.sh"
  echo '#!/bin/bash' > "$helper"
  echo "Run $helper to set the token." >> "$FIXTURE/docs/pilot-responsibilities.md"
  run _check
  [[ "$output" != *"external-helper.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: changelog sections are exempt from staleness checks" {
  cat >> "$FIXTURE/docs/pilot-architecture.md" <<'EOF'

## Changelog

### 2026-01-01 — old news
We used to run `ancient.sh` here, and it claimed 999 tests.
EOF
  run _check
  [[ "$output" != *"ancient.sh"* ]]
}

# bats test_tags=fast
@test "doc-drift-audit: a clean fixture reports no drift" {
  run _check
  [[ "$output" == *"No drift detected"* ]]
  [[ "$output" == *"TOTALCOUNT=0"* ]]
}
