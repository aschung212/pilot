#!/usr/bin/env python3
"""Mechanical doc-vs-repo drift checks for Pilot.

Reporter only — never edits. Every finding needs a human call about which side
is wrong. Reads REPO_ROOT (and optionally PRODUCT_DECISIONS_FILE /
PRODUCT_FEATURES_FILE) from the environment; prints a report and a trailing
TOTALCOUNT=<n> line for the shell wrapper.
"""
import os, re, sys, glob, plistlib

ROOT = os.environ.get("REPO_ROOT") or os.getcwd()
P = lambda *a: os.path.join(ROOT, *a)

findings = []            # (section, message)
def add(section, msg): findings.append((section, msg))

def read(path):
    try:
        with open(path, encoding="utf-8") as fh: return fh.read()
    except OSError:
        return ""

def live(text):
    """Everything before the Changelog. History is meant to describe the past,
    so staleness checks must never fire on it."""
    i = text.find("\n## Changelog")
    return text if i < 0 else text[:i]

# Docs that make claims about the current system.
DOCS = {
    "README.md":                    live(read(P("README.md"))),
    "CLAUDE.md":                    live(read(P("CLAUDE.md"))),
    "docs/pilot-architecture.md":   live(read(P("docs", "pilot-architecture.md"))),
    "docs/pilot-responsibilities.md": live(read(P("docs", "pilot-responsibilities.md"))),
}
ALL_LIVE = "\n".join(DOCS.values())

scripts  = sorted(os.path.basename(f) for f in glob.glob(P("scripts", "*.sh")))
adapters = sorted(os.path.basename(f) for f in glob.glob(P("adapters", "*.sh")))
libs     = sorted(os.path.basename(f) for f in glob.glob(P("lib", "*.sh")))
existing = set(scripts) | set(adapters) | set(libs)

# ── 1. Scripts nobody documented ────────────────────────────────────────────
doc_surface = DOCS["README.md"] + DOCS["docs/pilot-architecture.md"]
for s in scripts:
    if s not in doc_surface:
        add("Undocumented scripts", f"{s} — not mentioned in README.md or docs/pilot-architecture.md")

# ── 2. Dead references: a *.sh the docs name that no longer exists ──────────
# Skip generic/aliased names and the ~/Documents/Scripts symlink aliases, which
# legitimately differ from the repo filename.
IGNORE_SH = {"init.sh", "pre-commit", "run-tests.sh", "review-router.sh",
             "your-script.sh", "script.sh"}
# Docs deliberately keep tombstones ("the old X.sh was deleted 2026-07-17").
# Those are the docs doing their job, not drift, so a line that announces the
# removal suppresses the finding.
TOMBSTONE = re.compile(r'\b(delet|remov|retir|decommission|deprecat|no longer|used to|was replaced|replaced by)',
                       re.I)
for doc, text in DOCS.items():
    for line in text.splitlines():
        for m in set(re.findall(r'([a-z0-9][a-z0-9._-]*\.sh)', line)):
            if m in existing or m in IGNORE_SH or m.startswith("lift-") or m.startswith("linear-"):
                continue
            if TOMBSTONE.search(line):
                continue
            # A script referenced by an absolute path outside the repo (e.g.
            # ~/Documents/Scripts/set-claude-token.sh) is checked at that path.
            ext = re.search(r'(~|/Users/[^\s`|]+)?/[^\s`|]*' + re.escape(m), line)
            if ext:
                cand = os.path.expanduser(ext.group(0))
                if os.path.exists(cand):
                    continue
            add("Dead references", f"{doc} names {m}, which does not exist in scripts/, adapters/ or lib/")

# ── 3 & 4. launchd plists vs the schedule tables ────────────────────────────
DAYS = {0: "Sun", 1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat"}
arch = DOCS["docs/pilot-architecture.md"]
for f in sorted(glob.glob(P("launchd", "*.plist"))):
    base = os.path.basename(f)
    try:
        with open(f, "rb") as fh: d = plistlib.load(fh)
    except Exception as e:
        add("Broken plists", f"{base} — cannot parse ({e})"); continue

    label = d.get("Label", "")
    if label and label not in arch:
        add("Unscheduled in docs", f"{label} has a plist but no row in the architecture Scheduled Tasks table")

    # ProgramArguments target must exist in THIS repo (plists carry absolute
    # machine paths, so rebase onto the checkout).
    for arg in d.get("ProgramArguments", []):
        if isinstance(arg, str) and arg.endswith(".sh") and "/pilot/scripts/" in arg:
            local = P("scripts", arg.split("/pilot/scripts/", 1)[1])
            if not os.path.exists(local):
                add("Broken plists", f"{base} → {arg} (no such script in this repo)")

    # Times the plist actually fires, vs what the table claims.
    sched = d.get("StartCalendarInterval")
    if isinstance(sched, dict): sched = [sched]
    for e in (sched or []):
        hh, mm = e.get("Hour", 0), e.get("Minute", 0)
        day = DAYS.get(e.get("Weekday"), "")
        h12 = hh % 12 or 12
        ampm = "AM" if hh < 12 else "PM"
        variants = [f"{hh}:{mm:02d}", f"{hh:02d}:{mm:02d}", f"{h12}:{mm:02d} {ampm}"]
        if mm == 0: variants.append(f"{h12} {ampm}")
        if label and label in arch and not any(v in arch for v in variants):
            when = f"{day} {hh:02d}:{mm:02d}".strip()
            add("Schedule mismatch", f"{label} fires {when}, but no matching time appears in the architecture doc")

# ── 5. Test counts ──────────────────────────────────────────────────────────
# Counted from the test FILES, never by running them. Every number the docs
# quote — total tests, test files, fast-tier tests — is a property of the
# source, so running the suite to learn them bought nothing but wall clock.
# Worse: this check used to shell out to run-tests.sh with a 900s timeout, and
# once the suite outgrew that budget it stopped verifying anything at all and
# reported only its own breakage ("could not count the suite (… timed out …)",
# 2026-08-31). Reading the files is a few milliseconds and cannot time out.
#
# The parsing mirrors bats-core's own preprocessor (libexec/bats-core/
# bats-preprocess): file_tags and test_tags UNION, test_tags reset after each
# @test while file_tags persist.
#
# Known divergence, deliberately left alone: an @test line inside a heredoc
# body counts here but not in bats (bats rewrites it into the body, where it
# never executes and so never registers). Emulating that needs real shell
# lexing — a first attempt tripped over `cat <<PRBODY` inside a single-quoted
# bash -c string in builder.bats, whose terminator line is `PRBODY'`, and
# silently swallowed the rest of the file. Over-counting is a loud, visible
# finding; a heredoc tracker that loses its terminator is a silently wrong
# number, which is the failure this whole rewrite exists to kill. The
# `agrees with bats` test in tests/doc-drift-audit.bats runs `bats --count`
# over the real suite and goes red if the two ever part ways.
BATS_TEST     = re.compile(r'^[ \t]*@test[ \t]+.*[^ \t][ \t]+\{')
BATS_TEST_ALT = re.compile(r'^[ \t]*[^ \t()]+[ \t]*\(?\)?[ \t]+\{[ \t]+#[ \t]*@test[ \t]*$')
BATS_COMMENT  = re.compile(r'^[ \t]*#[ \t]*bats[ \t]+(.*)$')
BATS_TAGS     = re.compile(r'^(file_tags|test_tags)=(.*)$')

def count_bats(tests_dir, tier_tag):
    """(files, total tests, tests carrying tier_tag). Reads; never executes."""
    files = sorted(glob.glob(os.path.join(tests_dir, "*.bats")))
    total = tier = 0
    for f in files:
        file_tags, test_tags = set(), set()
        for line in read(f).splitlines():
            if BATS_TEST.match(line) or BATS_TEST_ALT.match(line):
                total += 1
                if tier_tag in (file_tags | test_tags):
                    tier += 1
                test_tags = set()   # bats resets per test; file tags carry on
                continue
            c = BATS_COMMENT.match(line)
            t = BATS_TAGS.match(c.group(1)) if c else None
            if not t:
                continue
            tags = {x.strip() for x in t.group(2).split(",") if x.strip()}
            if t.group(1) == "file_tags":
                file_tags = tags
            else:
                test_tags = tags
    return len(files), total, tier

# Which tag the pre-commit tier selects is run-tests.sh's decision, so read it
# from there. Hardcoding "fast" would leave this counting a tier that no longer
# exists the day someone renames it, and saying nothing.
runner = read(P("tests", "run-tests.sh"))
tier_m = re.search(r'--fast\)\s*FILTER="--filter-tags[ \t]+([-_:A-Za-z0-9]+)"', runner)
if runner and not tier_m:
    add("Test counts",
        "tests/run-tests.sh no longer maps --fast to a --filter-tags tag; "
        "falling back to 'fast', so the fast-tier count may be wrong")
n_files, n_full, n_fast = count_bats(P("tests"), tier_m.group(1) if tier_m else "fast")

if n_files:
    # The docs legitimately quote either tier, so a number is only drift if it
    # matches neither. Deduped: one finding per (doc, claimed number), not one
    # per occurrence.
    valid = {n_full, n_fast}
    for doc, text in DOCS.items():
        wrong_tests, wrong_files = set(), set()
        for claimed, unit in re.findall(r'\*?\*?(\d{2,4})\*?\*? (tests|test files)', text):
            c = int(claimed)
            if unit == "tests" and c not in valid: wrong_tests.add(c)
            if unit == "test files" and c != n_files: wrong_files.add(c)
        for c in sorted(wrong_tests):
            add("Test counts", f"{doc} claims {c} tests; the suite has {n_full} (fast tier {n_fast})")
        for c in sorted(wrong_files):
            add("Test counts", f"{doc} claims {c} test files; there are {n_files}")

# ── 6. Adapters ─────────────────────────────────────────────────────────────
for a in adapters:
    if a not in DOCS["CLAUDE.md"]:
        add("Undocumented adapters", f"{a} — not listed in CLAUDE.md's adapter section")

# ── 7. Env vars read by scripts but undocumented in project.env.example ─────
# Only Pilot-shaped names; system/derived/internal vars are noise here.
example = read(P("project.env.example"))
IGNORE_VAR = {
    "HOME", "PATH", "USER", "SHELL", "PWD", "TMPDIR", "LANG", "TERM", "EDITOR",
    "PILOT_DIR", "OUTPUT_DIR", "SCRIPT_DIR", "REPO_ROOT", "LOG_COMPONENT",
    "BASH_REMATCH", "PIPESTATUS", "RANDOM", "IFS", "DRY_RUN", "REPORT",
    "_PILOT_TEST_MODE", "GITHUB_TOKEN", "GITHUB_ACTIONS", "CI",
}
seen = set()
for f in glob.glob(P("scripts", "*.sh")) + glob.glob(P("adapters", "*.sh")) + glob.glob(P("lib", "*.sh")):
    for v in re.findall(r'\$\{([A-Z][A-Z0-9_]{3,})(?::[-?=]|\})', read(f)):
        seen.add(v)
# A var counts as documented if it appears in project.env.example OR anywhere
# in the docs — Slack tokens and vault paths live in ~/.zshenv by design and are
# documented in the responsibilities doc's Environment Variables section.
documented = example + ALL_LIVE + read(P("init.sh"))
for v in sorted(seen):
    if v in IGNORE_VAR or v in documented or v.startswith("_") or v.startswith("MOCK_"):
        continue
    # Vars set by the script itself (not read from config) are not config vars.
    defined = any(re.search(rf'(?m)^\s*{v}=', read(f))
                  for f in glob.glob(P("scripts", "*.sh")) + glob.glob(P("adapters", "*.sh")) + glob.glob(P("lib", "*.sh")))
    if not defined:
        add("Undocumented env vars", f"{v} is read by a script but absent from project.env.example")

# ── 8. Obsidian vault paths Pilot depends on ────────────────────────────────
for var in ("PRODUCT_DECISIONS_FILE", "PRODUCT_FEATURES_FILE"):
    path = os.environ.get(var, "")
    if path and not os.path.exists(path):
        add("Vault references", f"{var} points at a file that does not exist: {path}")

# Vault paths cited in the docs, e.g. `Obsidian: 20_Learning/.../X.md`
vault_root = os.path.expanduser("~/Documents/Obsidian Vault")
if os.path.isdir(vault_root):
    for doc, text in DOCS.items():
        for rel in set(re.findall(r'Obsidian:\s*([^`|\n]+\.md)', text)):
            rel = rel.strip()
            if not os.path.exists(os.path.join(vault_root, rel)):
                add("Vault references", f"{doc} cites vault note '{rel}', which is not at that path")

# ── Report ──────────────────────────────────────────────────────────────────
order = ["Broken plists", "Dead references", "Vault references", "Schedule mismatch",
         "Unscheduled in docs", "Test counts", "Undocumented scripts",
         "Undocumented adapters", "Undocumented env vars"]
by = {}
for sec, msg in findings: by.setdefault(sec, []).append(msg)

print(f"\nChecked {len(scripts)} scripts, {len(adapters)} adapters, "
      f"{len(glob.glob(P('launchd','*.plist')))} plists against {len(DOCS)} docs.\n")
for sec in order:
    if sec in by:
        print(f"### {sec}")
        for m in sorted(by[sec]): print(f"  • {m}")
        print()
for sec in by:
    if sec not in order:
        print(f"### {sec}")
        for m in sorted(by[sec]): print(f"  • {m}")
        print()
if not findings:
    print("  No drift detected.\n")
print(f"TOTALCOUNT={len(findings)}")
