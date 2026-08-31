#!/bin/bash
# Doc-Drift Audit — checks the docs against what Pilot actually is.
#
# The documentation mandate says docs ship with the change. Reality: they drift
# anyway, and silently. On 2026-08-28 the responsibilities doc still listed a
# Review Tuner that had been deleted 3.5 months earlier, claimed "6 independent
# services" when there were 9, cited a retired orchestrator plist, and reported
# test counts less than half the real number. None of that was visible without
# reading the docs against the filesystem line by line.
#
# This does that mechanically. It is a REPORTER, never an editor — every finding
# needs a human judgment call about which side is wrong (sometimes the doc is
# right and the code is the bug).
#
# Checks:
#   1. Scripts undocumented in README / architecture doc
#   2. Dead references — a *.sh named in the docs that no longer exists
#   3. launchd plists missing from, or disagreeing with, the schedule tables
#   4. Plist ProgramArguments pointing at a script this repo does not have
#   5. Test counts claimed in docs vs the test files (parsed, never run)
#   6. Adapters undocumented in CLAUDE.md
#   7. Pilot env vars read by scripts but absent from project.env.example
#   8. Obsidian vault paths Pilot depends on that do not resolve
#
# Scope note on the vault: this checks ONLY the vault files Pilot itself reads
# or names (PRODUCT_DECISIONS_FILE, PRODUCT_FEATURES_FILE, and vault paths cited
# in Pilot docs). Aaron's vault workflows are a separate domain and are not
# audited here — a broken path is a Pilot bug because it silently degrades
# discovery and triage.
#
# Changelog sections are excluded from every staleness check: history is
# supposed to describe the past.
#
# Usage:
#   ./doc-drift-audit.sh              # report to stdout
#   ./doc-drift-audit.sh --notify     # also post findings to Slack
#   ./doc-drift-audit.sh --biweekly   # no-op unless this is an even ISO week
#   ./doc-drift-audit.sh --strict     # exit 1 when findings exist (for CI)

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="doc-drift-audit"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
REPORT="$OUTPUT_DIR/lift-doc-drift-$DATE.md"

DO_NOTIFY=""; STRICT=""; BIWEEKLY=""
for arg in "$@"; do
  case "$arg" in
    --notify)   DO_NOTIFY="1" ;;
    --strict)   STRICT="1" ;;
    --biweekly) BIWEEKLY="1" ;;
    --dry-run)  ;;   # read-only already; accepted for symmetry
    *) echo "Unknown argument: $arg (valid: --notify, --strict, --biweekly, --dry-run)" >&2; exit 1 ;;
  esac
done

# launchd cannot express "every two weeks", so the cadence lives here: run
# weekly from the plist, and no-op on odd ISO weeks. Calendar-anchored, so it
# cannot drift the way a 1209600-second StartInterval would.
if [ -n "$BIWEEKLY" ]; then
  WEEK=$(date +%V | sed 's/^0*//')
  if [ $((WEEK % 2)) -ne 0 ]; then
    echo "🗓️  Doc-drift audit skipped — ISO week $WEEK is odd (biweekly cadence runs on even weeks)."
    exit 0
  fi
fi

mkdir -p "$OUTPUT_DIR"

FINDINGS=$(REPO_ROOT="$REPO_ROOT" \
  PRODUCT_DECISIONS_FILE="${PRODUCT_DECISIONS_FILE:-}" \
  PRODUCT_FEATURES_FILE="${PRODUCT_FEATURES_FILE:-}" \
  python3 "$SCRIPT_DIR/../lib/doc-drift-check.py")
RC=$?

# The checker is a pure reporter: a non-zero exit means it crashed, not that it
# found something. Nothing used to read $RC, so a crash left FINDINGS empty,
# TOTAL defaulted to 0, and the audit cheerfully printed "✅ Docs match the
# repo." — reporting a success it never checked.
if [ "$RC" -ne 0 ]; then
  echo "📋 Doc-Drift Audit — $DATE" | tee "$REPORT"
  echo "❌ lib/doc-drift-check.py exited $RC — the docs were NOT checked." | tee -a "$REPORT"
  if [ -n "$DO_NOTIFY" ]; then
    bash "$NOTIFY" send automation \
      "📋 *Doc-drift audit — $DATE*: checker failed (exit $RC) — the docs were not checked." >/dev/null 2>&1 || true
  fi
  exit 1
fi

echo "📋 Doc-Drift Audit — $DATE" | tee "$REPORT"
echo "$FINDINGS" | grep -v '^TOTALCOUNT=' | tee -a "$REPORT"

TOTAL=$(echo "$FINDINGS" | grep -oE '^TOTALCOUNT=[0-9]+' | cut -d= -f2 | tr -d ' \n')
TOTAL="${TOTAL:-0}"

echo "" | tee -a "$REPORT"
if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
  echo "🚨 $TOTAL drift finding(s) — see $REPORT" | tee -a "$REPORT"
else
  echo "✅ Docs match the repo." | tee -a "$REPORT"
fi

if [ -n "$DO_NOTIFY" ]; then
  if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
    bash "$NOTIFY" send automation "📋 *Doc-drift audit — $DATE*: $TOTAL finding(s). The docs disagree with the repo:
\`\`\`
$(echo "$FINDINGS" | grep '  •' | head -25)
\`\`\`
Full report: \`$REPORT\`" >/dev/null 2>&1 || true
  else
    bash "$NOTIFY" send automation "📋 *Doc-drift audit — $DATE*: clean — docs match the repo." >/dev/null 2>&1 || true
  fi
fi

[ -n "$STRICT" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null && exit 1
exit 0
