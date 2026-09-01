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
  [[ "$output" == *"Unknown argument"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: --biweekly no-ops on an odd ISO week" {
  week=$(date +%V | sed 's/^0*//')
  run bash "$AUDIT" --biweekly
  [ "$status" -eq 0 ]
  if [ $((week % 2)) -ne 0 ]; then
    [[ "$output" == *"skipped"* ]] || return 1
  else
    [[ "$output" != *"skipped"* ]] || return 1
  fi
}

# ── it finds real drift ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "doc-drift-audit: flags a script no doc mentions" {
  echo '#!/bin/bash' > "$FIXTURE/scripts/undocumented.sh"
  run _check
  [[ "$output" == *"undocumented.sh"* ]] || return 1
  [[ "$output" == *"Undocumented scripts"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: flags a doc naming a script that no longer exists" {
  echo 'Run `ghost.sh` nightly to do the thing.' >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  [[ "$output" == *"Dead references"* ]] || return 1
  [[ "$output" == *"ghost.sh"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: flags a plist with no row in the schedule table" {
  _plist "com.test.orphan" "alpha.sh"
  run _check
  [[ "$output" == *"Unscheduled in docs"* ]] || return 1
  [[ "$output" == *"com.test.orphan"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: flags a plist pointing at a missing script" {
  _plist "com.test.broken" "nonexistent.sh"
  echo 'com.test.broken runs at 8:15 AM' >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  [[ "$output" == *"Broken plists"* ]] || return 1
  [[ "$output" == *"nonexistent.sh"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: flags an adapter missing from CLAUDE.md" {
  echo '#!/bin/bash' > "$FIXTURE/adapters/notify.sh"
  run _check
  [[ "$output" == *"Undocumented adapters"* ]] || return 1
  [[ "$output" == *"notify.sh"* ]] || return 1
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
  [[ "$output" != *"ai-review.sh"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: a script living outside the repo is not a dead reference" {
  helper="$TEST_TMPDIR/external-helper.sh"
  echo '#!/bin/bash' > "$helper"
  echo "Run $helper to set the token." >> "$FIXTURE/docs/pilot-responsibilities.md"
  run _check
  [[ "$output" != *"external-helper.sh"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: changelog sections are exempt from staleness checks" {
  cat >> "$FIXTURE/docs/pilot-architecture.md" <<'EOF'

## Changelog

### 2026-01-01 — old news
We used to run `ancient.sh` here, and it claimed 999 tests.
EOF
  run _check
  [[ "$output" != *"ancient.sh"* ]] || return 1
}

# bats test_tags=fast
@test "doc-drift-audit: a clean fixture reports no drift" {
  run _check
  [[ "$output" == *"No drift detected"* ]] || return 1
  [[ "$output" == *"TOTALCOUNT=0"* ]] || return 1
}

# ── test counts: read from the files, never by running the suite ────────────
#
# The old check shelled out to `run-tests.sh --tap` with a 900s timeout. The
# suite outgrew it, so on 2026-08-31 the audit's only test-count finding was
# its own breakage: "could not count the suite (… timed out after 900 seconds)".
# These pin the replacement — the numbers come from parsing tests/*.bats, and
# they are what bats itself would report.
#
# Assertion style: bats does NOT abort a test on a failing bare `[[ ]]` unless
# it happens to be the last line (a conditional expression is exempt from the
# errexit that catches `false`). Non-final assertions below therefore go
# through _has/_lacks, which are simple commands and do abort.

_has()   { grep -qF -- "$1" <<<"$output"; }
_lacks() { ! grep -qF -- "$1" <<<"$output"; }

# tests/fixtures/bats-count/ is a real directory, not a heredoc: bats rewrites
# every line matching its @test pattern even inside a heredoc body, so a
# fixture suite written inline lands on disk mangled. See that dir's README for
# its shape (3 files, 7 tests, 4 of them fast) and why each file is there.
_fixture_suite() {
  cp "$FIXTURES_DIR"/bats-count/*.bats "$FIXTURE/tests/"
  cp "$FIXTURES_DIR"/bats-count/run-tests.sh "$FIXTURE/tests/"
}

# A claim no real suite can match, so the checker has to report what it counted.
_claim_wrong_counts() {
  echo 'The suite has 9999 tests across 88 test files.' >> "$FIXTURE/docs/pilot-architecture.md"
}

# bats test_tags=fast
@test "doc-drift-audit: counts tests, files and the fast tier statically" {
  _fixture_suite
  _claim_wrong_counts
  run _check
  _has "claims 9999 tests; the suite has 7 (fast tier 4)"
  _has "claims 88 test files; there are 3"
}

# bats test_tags=fast
@test "doc-drift-audit: counting never executes the test suite" {
  _fixture_suite
  _claim_wrong_counts
  run _check
  # The fixture runner touches this the moment it is executed. The checker is
  # only allowed to read it.
  [ ! -e "$FIXTURE/tests/suite-was-run" ]
  _has "the suite has 7 (fast tier 4)"
  _lacks "could not count the suite"
}

# bats test_tags=fast
@test "doc-drift-audit: the fast tier is a tag filter, not total minus slow" {
  _fixture_suite
  _claim_wrong_counts
  run _check
  # 7 tests: 4 fast, 2 slow, 1 untagged. The untagged one runs in neither tier,
  # so anyone deriving fast from 7 - 2 would say 5 and be wrong.
  _has "the suite has 7 (fast tier 4)"
  _lacks "fast tier 5"
}

# bats test_tags=fast
@test "doc-drift-audit: a doc quoting either tier is not drift" {
  _fixture_suite
  echo 'Full tier: 77 tests. Fast tier: 44 tests. Spread over 33 test files.' \
    >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  _has "Test counts"          # the wrong numbers above are flagged...
  _lacks "the suite has 77"
  # ...and now the right ones, either tier, are not.
  : > "$FIXTURE/docs/pilot-architecture.md"
  echo 'Full tier: 7 tests. Fast tier: 4 tests. Across 3 test files.' \
    >> "$FIXTURE/docs/pilot-architecture.md"
  run _check
  _lacks "Test counts"
}

# bats test_tags=fast
@test "doc-drift-audit: the fast tier follows the tag run-tests.sh filters on" {
  _fixture_suite
  # Rename the tier tag in the runner and retag one test to match. The count
  # must follow the runner rather than a hardcoded "fast".
  cat > "$FIXTURE/tests/run-tests.sh" <<'RUNNER'
#!/bin/bash
case "$1" in
  --fast) FILTER="--filter-tags quick" ;;
esac
RUNNER
  sed -i.bak 's/test_tags=slow/test_tags=quick/' "$FIXTURE/tests/alpha.bats"
  rm -f "$FIXTURE/tests/alpha.bats.bak"
  _claim_wrong_counts
  run _check
  _has "the suite has 7 (fast tier 1)"
}

# bats test_tags=fast
@test "doc-drift-audit: flags a runner that no longer maps --fast to a tag" {
  _fixture_suite
  cat > "$FIXTURE/tests/run-tests.sh" <<'RUNNER'
#!/bin/bash
case "$1" in
  --fast) FILTER="--some-new-flag" ;;
esac
RUNNER
  run _check
  _has "no longer maps --fast to a --filter-tags tag"
}

# bats test_tags=fast
@test "doc-drift-audit: a repo with no test files claims nothing about counts" {
  _claim_wrong_counts
  run _check
  _lacks "Test counts"
}

# The fixture above pins the parsing rules; this pins the parser against bats
# itself, on the suite whose numbers the docs actually quote. It is the only
# thing that would catch a divergence the fixture does not model — a new tag
# syntax, or an @test line inside a heredoc (bats never registers those; this
# counter would count one). Slow tier: `bats --count` over 26 files costs ~30s,
# which is worth paying in CI and not on every commit.
# bats test_tags=slow
@test "doc-drift-audit: the static count agrees with bats on the real suite" {
  command -v bats >/dev/null || skip "bats not installed"
  real="$TEST_TMPDIR/realrepo"
  mkdir -p "$real/docs"
  ln -s "$PILOT_DIR/tests" "$real/tests"
  : > "$real/README.md"; : > "$real/CLAUDE.md"; : > "$real/project.env.example"
  : > "$real/docs/pilot-responsibilities.md"
  echo 'The suite has 9999 tests across 8888 test files.' > "$real/docs/pilot-architecture.md"

  full=$(bats --count "$PILOT_DIR"/tests/*.bats)
  fast=$(bats --count --filter-tags fast "$PILOT_DIR"/tests/*.bats)
  files=$(ls "$PILOT_DIR"/tests/*.bats | wc -l | tr -d ' ')

  run env REPO_ROOT="$real" PRODUCT_DECISIONS_FILE="" PRODUCT_FEATURES_FILE="" \
    python3 "$PILOT_DIR/lib/doc-drift-check.py"
  _has "the suite has $full (fast tier $fast)"
  _has "claims 8888 test files; there are $files"
}
