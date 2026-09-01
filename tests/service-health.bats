#!/usr/bin/env bats
# Tests for lib/service-health.sh
#
# Nothing watched launchd exit codes until 2026-08-28. tune-budget had reported
# exit 126 since its first run and roadmap-synth exit 1 every week since
# 2026-05-06 — both sat in one line of `launchctl list` that nothing read. The
# old check was hardcoded to three services and only asked whether they were
# loaded, so neither could ever have surfaced.
#
# Half of these assert it FINDS the failures; half assert it stays quiet, since
# a weekly report that cries wolf gets skimmed and then ignored.

load test_helper

setup() {
  export TEST_TMPDIR=$(mktemp -d)
  mkdir -p "$TEST_TMPDIR/plists" "$TEST_TMPDIR/logs"
  export NOW=1787961600   # fixed clock (2026-08-29) so age maths is deterministic
  source "$PILOT_DIR/lib/service-health.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# $1 label, $2 script, $3 weekday ("" = daily)
_plist() {
  local sched="<key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer>"
  [ -n "${3:-}" ] && sched="<key>Weekday</key><integer>$3</integer>$sched"
  cat > "$TEST_TMPDIR/plists/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/tmp/$2</string></array>
<key>StartCalendarInterval</key><dict>$sched</dict>
</dict></plist>
EOF
}

_lc() { printf '%s\n' "$@" > "$TEST_TMPDIR/lc.txt"; }

_run_check() {
  run service_health_check "$TEST_TMPDIR/lc.txt" "$TEST_TMPDIR/plists" "$TEST_TMPDIR/logs" "$NOW"
}

# ── finds real failures ─────────────────────────────────────────────────────

# bats test_tags=fast
@test "service-health: flags a non-zero last exit status" {
  _plist com.aaron.pilot-roadmap roadmap.sh 3
  _lc "-	1	com.aaron.pilot-roadmap"
  _run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"com.aaron.pilot-roadmap last exited 1"* ]] || return 1
}

# bats test_tags=fast
@test "service-health: explains exit 126 as a broken invocation" {
  _plist com.aaron.pilot-tune-budget tune.sh 0
  _lc "-	126	com.aaron.pilot-tune-budget"
  _run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"126"* ]] || return 1
  [[ "$output" == *"not executable"* ]] || return 1
}

# bats test_tags=fast
@test "service-health: explains exit 127 as a bad path" {
  _plist com.aaron.pilot-x x.sh 0
  _lc "-	127	com.aaron.pilot-x"
  _run_check
  [[ "$output" == *"command not found"* ]] || return 1
}

# bats test_tags=fast
@test "service-health: flags a committed plist that is not loaded" {
  _plist com.aaron.pilot-ghost ghost.sh 0
  _lc "-	0	com.aaron.pilot-other"
  _run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT loaded"* ]] || return 1
  [[ "$output" == *"never runs"* ]] || return 1
}

# bats test_tags=fast
@test "service-health: flags an unparseable plist" {
  printf 'not a plist' > "$TEST_TMPDIR/plists/broken.plist"
  _lc "-	0	com.aaron.pilot-other"
  _run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"unparseable"* ]] || return 1
}

# bats test_tags=fast
@test "service-health: flags a loaded service whose log has gone stale" {
  _plist com.aaron.pilot-weekly weekly.sh 0
  _lc "-	0	com.aaron.pilot-weekly"
  # plist is old enough to have fired; log is 30 days stale
  touch -t 202601010000 "$TEST_TMPDIR/plists/com.aaron.pilot-weekly.plist"
  : > "$TEST_TMPDIR/logs/pilot-weekly-launchd.log"
  touch -t 202607010000 "$TEST_TMPDIR/logs/pilot-weekly-launchd.log"
  _run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"loaded but not firing"* ]] || return 1
}

# ── stays quiet when everything is fine ─────────────────────────────────────

# bats test_tags=fast
@test "service-health: silent when every service is loaded and exited 0" {
  _plist com.aaron.pilot-a a.sh 0
  _plist com.aaron.pilot-b b.sh 3
  _lc "-	0	com.aaron.pilot-a" "-	0	com.aaron.pilot-b"
  touch -t 202601010000 "$TEST_TMPDIR/plists"/*.plist
  for n in a b; do
    : > "$TEST_TMPDIR/logs/pilot-$n-launchd.log"
  done
  _run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=fast
@test "service-health: a newly added plist is not yet expected to have fired" {
  # This is the regression that matters most for signal-to-noise: the two
  # plists loaded on 2026-08-28 had no logs yet and must not read as broken.
  _plist com.aaron.pilot-new new.sh 0
  _lc "-	0	com.aaron.pilot-new"
  # plist created "now" — younger than one weekly cadence
  touch -d "@$NOW" "$TEST_TMPDIR/plists/com.aaron.pilot-new.plist" 2>/dev/null || \
    touch -t "$(date -r "$NOW" +%Y%m%d%H%M)" "$TEST_TMPDIR/plists/com.aaron.pilot-new.plist"
  _run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=fast
@test "service-health: ignores non-pilot services in launchctl output" {
  _plist com.aaron.pilot-a a.sh 0
  _lc "-	0	com.aaron.pilot-a" "-	1	com.apple.something" "123	0	com.third.party"
  touch -t 202601010000 "$TEST_TMPDIR/plists"/*.plist
  : > "$TEST_TMPDIR/logs/pilot-a-launchd.log"
  _run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"com.apple"* ]] || return 1
}
