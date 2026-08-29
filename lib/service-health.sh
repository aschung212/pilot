#!/bin/bash
# Service health — reconciles the committed launchd plists against what launchd
# is actually running.
#
# Nothing in the pipeline watched launchd exit codes until 2026-08-28. That is
# how two agents stayed broken for months in plain sight: `tune-budget` had been
# reporting exit 126 since its first run and `roadmap-synth` exit 1 every week
# since 2026-05-06, both visible in one line of `launchctl list` that nobody
# read. The old check here was hardcoded to three services (discover, triage,
# builder) and only asked whether they were loaded — never how they exited — so
# neither failure could ever have surfaced.
#
# Three questions, in descending order of "how long could this hide":
#   1. Is a committed plist not loaded at all?   → it never runs, silently
#   2. Did a loaded service exit non-zero?       → it runs and fails, silently
#   3. Is its log older than its own cadence?    → it is loaded but not firing
#
# Pure function: takes `launchctl list` output and a plist directory, prints
# findings, returns 1 if any were found. No side effects, so it is testable.

# service_health_check <launchctl_output_file> <plist_dir> [log_dir] [now_epoch]
service_health_check() {
  local lc_out="$1" plist_dir="$2" log_dir="${3:-}" now="${4:-}"
  [ -z "$now" ] && now=$(date +%s)

  LC_OUT="$lc_out" PLIST_DIR="$plist_dir" LOG_DIR="$log_dir" NOW="$now" python3 <<'PY'
import os, sys, glob, plistlib, re

lc_out   = open(os.environ["LC_OUT"]).read() if os.path.exists(os.environ["LC_OUT"]) else ""
plist_dir = os.environ["PLIST_DIR"]
log_dir   = os.environ.get("LOG_DIR") or ""
now       = int(os.environ["NOW"])

# `launchctl list` columns: PID  LastExitStatus  Label
status = {}
for line in lc_out.splitlines():
    parts = line.split("\t") if "\t" in line else line.split()
    if len(parts) >= 3 and parts[2].startswith("com."):
        pid, code, label = parts[0], parts[1], parts[2]
        try:
            status[label] = (pid, int(code))
        except ValueError:
            continue

findings = []
for f in sorted(glob.glob(os.path.join(plist_dir, "*.plist"))):
    try:
        with open(f, "rb") as fh:
            d = plistlib.load(fh)
    except Exception as e:
        findings.append(f"plist {os.path.basename(f)} is unparseable ({e}) — launchd cannot load it")
        continue

    label = d.get("Label")
    if not label:
        findings.append(f"plist {os.path.basename(f)} has no Label")
        continue

    # 1. Committed but not loaded — it will never run, and nothing says so.
    if label not in status:
        findings.append(f"{label} is NOT loaded (plist committed but never `launchctl load`ed) — it never runs")
        continue

    pid, code = status[label]

    # 2. Ran and failed. 126/127 are the loud ones: "cannot execute" / "not
    #    found", which is what a broken invocation looks like.
    if code != 0:
        hint = {126: " (command found but not executable — check the invocation)",
                127: " (command not found — check the path in ProgramArguments)"}.get(code, "")
        findings.append(f"{label} last exited {code}{hint}")

    # 3. Loaded, exit 0, but its log has not been touched in far longer than its
    #    own cadence — the "loaded but never actually firing" case. Generous
    #    threshold (2x + 1 day) so a single skipped run is not noise.
    if not log_dir:
        continue
    sched = d.get("StartCalendarInterval")
    if isinstance(sched, dict):
        sched = [sched]
    if not sched:
        continue
    # Weekday present on every entry => weekly-ish; otherwise it fires daily.
    weekly = all(e.get("Weekday") is not None for e in sched)
    entries = len(sched)
    expected_days = (7.0 / entries) if weekly else 1.0
    limit = expected_days * 2 + 1

    # A service added recently has not had a chance to fire yet, so neither the
    # missing-log nor the stale-log finding applies until it is older than one
    # full cadence. Without this, every newly loaded plist reports as broken.
    plist_age_days = (now - int(os.path.getmtime(f))) / 86400.0
    if plist_age_days < limit:
        continue

    short = label.replace("com.aaron.", "")
    candidates = [os.path.join(log_dir, f"{short}-launchd.log"),
                  os.path.join(log_dir, f"{short}.log")]
    log = next((p for p in candidates if os.path.exists(p)), None)
    if log is None:
        findings.append(f"{label} has been loaded for {plist_age_days:.0f} days "
                        f"(fires about every {expected_days:.0f}d) but has no launchd log — it has never fired")
        continue
    age_days = (now - int(os.path.getmtime(log))) / 86400.0
    if age_days > limit:
        findings.append(
            f"{label} is loaded and last exited 0, but its log is {age_days:.0f} days old "
            f"(fires about every {expected_days:.0f}d) — loaded but not firing")

for f in findings:
    print(f)
sys.exit(1 if findings else 0)
PY
}
