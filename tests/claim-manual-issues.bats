#!/usr/bin/env bats
# Tests for scripts/claim-manual-issues.sh
#
# This script REWRITES PRIORITY on live issues, so the tests are weighted
# toward proving it promotes exactly the right set and nothing else. The
# selection predicate is the whole product; if it over-fires, a stranger's
# bug report or the entire 109-issue backlog lands at priority:1-urgent.
#
# Every test drives the REAL script end to end through a `gh` shim. Nothing
# here re-implements the jq predicate — tests/tune-budget.bats had five green
# tests over a pasted copy of logic that had never once worked, and the lesson
# (CLAUDE.md, "Tests that re-implement the logic they test") is that a unit
# test over a copy proves nothing about the original.

load test_helper

CLAIM="$PILOT_DIR/scripts/claim-manual-issues.sh"

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  export OUTPUT_DIR="$TEST_TMPDIR/outputs"
  export HOME="$TEST_TMPDIR/home"
  mkdir -p "$OUTPUT_DIR" "$HOME" "$TEST_TMPDIR/bin"
  export _PILOT_TEST_MODE=1
  export PILOT_DIR="$PILOT_DIR"
  export GITHUB_ISSUES_REPO="aschung212/Lift"
  export ISSUE_PREFIX="LIFT"
  export SLACK_BOT_TOKEN="" SLACK_WEBHOOK_URL=""

  export ISSUE_FIXTURE="$TEST_TMPDIR/issues.json"
  export ACTION_LOG="$TEST_TMPDIR/actions.log"
  : > "$ACTION_LOG"

  # gh shim: `issue list` serves the fixture through the script's own --jq
  # expression (so the real predicate is exercised, not a copy of it), and
  # mutations are recorded rather than performed.
  cat > "$TEST_TMPDIR/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "issue list")
    jqexpr=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--jq" ] && jqexpr="$a"
      prev="$a"
    done
    if [ -z "$jqexpr" ]; then cat "$ISSUE_FIXTURE"; else jq -r "$jqexpr" "$ISSUE_FIXTURE"; fi
    ;;
  "issue edit")    echo "EDIT $3 $*" >> "$ACTION_LOG" ;;
  "issue comment") echo "COMMENT $3" >> "$ACTION_LOG" ;;
  "label create")  echo "LABEL $3" >> "$ACTION_LOG" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_TMPDIR/bin/gh"

  # tracker.sh shim so comment-add is recorded without touching the network.
  mkdir -p "$TEST_TMPDIR/adapters"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Writes an issue-list fixture. Each arg: number|author|comma-labels|title
mkfixture() {
  local json="[" first=1
  for row in "$@"; do
    IFS='|' read -r num author labels title <<< "$row"
    local labjson="["
    if [ -n "$labels" ]; then
      local lfirst=1
      IFS=',' read -ra L <<< "$labels"
      for l in "${L[@]}"; do
        [ $lfirst -eq 0 ] && labjson="$labjson,"
        labjson="$labjson{\"name\":\"$l\"}"; lfirst=0
      done
    fi
    labjson="$labjson]"
    [ $first -eq 0 ] && json="$json,"
    json="$json{\"number\":$num,\"title\":\"$title\",\"labels\":$labjson,\"author\":{\"login\":\"$author\"}}"
    first=0
  done
  echo "$json]" > "$ISSUE_FIXTURE"
}

@test "promotes an issue Aaron filed with no labels at all" {
  mkfixture "1271|aschung212||progressive overload"
  run bash "$CLAIM" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted LIFT-1271"* ]] || return 1
  grep -q "EDIT 1271" "$ACTION_LOG"
}

@test "promotes an issue Aaron filed that carries only a topic label" {
  mkfixture "1272|aschung212|Feature|bulking vs cutting"
  run bash "$CLAIM" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted LIFT-1272"* ]] || return 1
}

@test "adds origin:aaron, priority:1-urgent and state:unstarted" {
  mkfixture "1271|aschung212||progressive overload"
  run bash "$CLAIM" --apply
  grep -q "origin:aaron" "$ACTION_LOG"
  grep -q "priority:1-urgent" "$ACTION_LOG"
  grep -q "state:unstarted" "$ACTION_LOG"
}

# The public-repo guard. Lift is PUBLIC; without the author gate the first
# outside bug report would outrank Aaron's entire backlog.
@test "ignores an issue filed by someone who is not the configured author" {
  mkfixture "9003|randomuser||crash on startup"
  run bash "$CLAIM" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unclaimed hand-filed issues"* ]] || return 1
  [ ! -s "$ACTION_LOG" ]
}

# Pilot's gh_create ALWAYS stamps a state:* label. That is the entire basis of
# the predicate — if this test ever fails, the detector is unsound.
@test "ignores a Pilot-created issue (has a state:* label)" {
  mkfixture "9004|aschung212|state:unstarted,priority:3-medium|[Architect] something"
  run bash "$CLAIM" --apply
  [[ "$output" == *"No unclaimed hand-filed issues"* ]] || return 1
  [ ! -s "$ACTION_LOG" ]
}

@test "is idempotent — skips an issue already carrying origin:aaron" {
  mkfixture "9005|aschung212|origin:aaron,priority:1-urgent|already promoted"
  run bash "$CLAIM" --apply
  [[ "$output" == *"No unclaimed hand-filed issues"* ]] || return 1
  [ ! -s "$ACTION_LOG" ]
}

@test "picks only the hand-filed issues out of a mixed backlog" {
  mkfixture \
    "1271|aschung212||hand filed one" \
    "1272|aschung212|Feature|hand filed two" \
    "9003|randomuser||stranger issue" \
    "9004|aschung212|state:triage,priority:2-high|pilot issue" \
    "9005|aschung212|origin:aaron|already claimed"
  run bash "$CLAIM" --apply
  [[ "$output" == *"Found 2 hand-filed issue(s)"* ]] || return 1
  grep -q "EDIT 1271" "$ACTION_LOG"
  grep -q "EDIT 1272" "$ACTION_LOG"
  ! grep -q "EDIT 9003" "$ACTION_LOG"
  ! grep -q "EDIT 9004" "$ACTION_LOG"
  ! grep -q "EDIT 9005" "$ACTION_LOG"
}

# A bare invocation must never mutate the tracker.
@test "defaults to a dry run and mutates nothing" {
  mkfixture "1271|aschung212||progressive overload"
  run bash "$CLAIM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]] || return 1
  [[ "$output" == *"would promote LIFT-1271"* ]] || return 1
  [ ! -s "$ACTION_LOG" ]
}

@test "MANUAL_CLAIM_ENABLED=0 disables it entirely" {
  mkfixture "1271|aschung212||progressive overload"
  MANUAL_CLAIM_ENABLED=0 run bash "$CLAIM" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]] || return 1
  [ ! -s "$ACTION_LOG" ]
}

@test "--author overrides the configured author" {
  mkfixture "9003|someoneelse||their issue"
  run bash "$CLAIM" --apply --author someoneelse
  [[ "$output" == *"promoted LIFT-9003"* ]] || return 1
}

@test "rejects an unknown argument instead of silently ignoring it" {
  mkfixture "1271|aschung212||progressive overload"
  run bash "$CLAIM" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]] || return 1
}

@test "author defaults to the GITHUB_ISSUES_REPO owner when unset" {
  mkfixture "1271|aschung212||progressive overload"
  unset MANUAL_ISSUE_AUTHOR
  run bash "$CLAIM" --apply
  [[ "$output" == *"author: aschung212"* ]] || return 1
  [[ "$output" == *"promoted LIFT-1271"* ]] || return 1
}
