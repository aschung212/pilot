#!/bin/bash
# PR-Close Reconcile — closes the loop when a PR is closed without merging.
#
# THE LEAK THIS FIXES
#
# An issue flips to state:started when its PR opens. When that PR is closed
# UNMERGED, nothing resets the label — so the issue keeps state:started
# forever. tracker.sh's "triageable" query excludes state:started (it means
# "work in flight, don't interrupt"), so the issue becomes permanently
# invisible to triage.sh. Nothing re-examines it, and the builder keeps
# seeing a backlog entry whose implementation was already rejected.
#
# Measured on 2026-08-28: 74 of 107 open Lift issues carried state:started
# with ZERO open PRs — 69% of the backlog was unreachable by the pipeline's
# own self-cleaning stage. The audit that day closed 149 issues, 41 of which
# were "PR closed, issue left open".
#
# WHAT IT DOES
#
# For each unmerged PR closed inside the lookback window whose linked issue
# is still open:
#   * rejection verdict + confident link -> close the issue "not planned"
#   * otherwise                          -> reset state:started -> state:triage
#   * ambiguous link                     -> report only, mutate nothing
#
# state:triage, not state:unstarted: triageable but NOT pickable (see the jq
# queries in adapters/tracker.sh), so a reconciled issue is re-examined before
# the builder can spend a run on it.
#
# TRUST MODEL — why closing needs two agreeing signals
#
# PR link metadata in this repo is demonstrably unreliable. PR #1065 is
# titled "feat: add superset/circuit grouping for exercises (#616)" while its
# body reads "Issue: LIFT-1064" — a manifest-screenshot issue — because the
# builder reused a body template. Trusting either source alone would have
# closed an unrelated, legitimate issue. So: closing requires the title and
# body links to AGREE; a single-source link may only reset the label; a
# conflicting link is reported for a human and nothing is touched.
#
# RELATIONSHIP TO cleanup.sh — read before changing either
#
# cleanup.sh ALREADY computes this bucket. Its backlog recycler sorts every
# state:started issue four ways and puts "every PR was closed unmerged" into
# a "Needs your call" bucket that it deliberately does NOT act on:
#
#     "A closed-unmerged PR may have been a deliberate rejection, so
#      auto-recycling it would rebuild work Aaron already declined —
#      those are surfaced for a human decision instead."
#
# That rule is sound, and this script does not repeal it. It resolves only the
# subset where the human decision is ALREADY RECORDED — a rejection verdict in
# the PR's closing comment. Everything else still lands in cleanup's bucket for
# a human.
#
# The failure mode being fixed is that nobody ever worked the bucket:
# cleanup.sh wrote it to data/lift-needs-decision.txt nightly and the digest
# rendered it, and it still reached 74 issues.
#
# DIVERGENCE RISK: cleanup.sh independently derives the same bucket and
# harvests the same closing comments (into data/lift-build-learnings.md). Two
# derivations of one fact drift. If you change the bucket rule in either file,
# change it in both — or better, collapse them.
#
# Idempotent: every mutation leaves a marker comment keyed to the PR number,
# and an issue already carrying that marker is skipped on later runs.
#
# Usage:
#   ./pr-close-reconcile.sh                     # DRY RUN (default)
#   ./pr-close-reconcile.sh --apply
#   ./pr-close-reconcile.sh --apply --notify
#   ./pr-close-reconcile.sh --apply --since 30  # lookback in days (default 14)

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="pr-close-reconcile"

DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
REPORT="$OUTPUT_DIR/lift-pr-close-reconcile-$DATE.md"
MARKER="<!-- pilot:pr-close-reconcile -->"

# Default is DRY RUN. This script closes issues; a bare invocation must never
# mutate the tracker.
APPLY=""
DO_NOTIFY=""
SINCE_DAYS="14"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) APPLY="" ;;
    --apply)   APPLY="1" ;;
    --notify)  DO_NOTIFY="1" ;;
    --since)   shift; SINCE_DAYS="${1:?--since needs a day count}" ;;
    *) echo "Unknown argument: $1 (valid: --dry-run, --apply, --notify, --since N)" >&2; exit 1 ;;
  esac
  shift
done
case "$SINCE_DAYS" in ''|*[!0-9]*) echo "--since must be a positive integer" >&2; exit 1 ;; esac

mkdir -p "$OUTPUT_DIR"
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found" >&2; exit 1; }
: "${GITHUB_ISSUES_REPO:?GITHUB_ISSUES_REPO not set — run init.sh}"

# Rejection verdicts, matched case-insensitively against the LAST human
# comment. Deliberately conservative: an unmatched close resets the label for
# re-triage rather than closing, so a false negative costs one triage cycle
# while a false positive would silently kill live work.
REJECT_RE='not wanted|not needed|dont want|don.t want|wont do|won.t do|not planned|redundant|duplicate|stale|obsolete|superseded|abandon'

CUTOFF=$(date -u -v-"${SINCE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "${SINCE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

echo "🔁 PR-Close Reconcile — $DATE (lookback ${SINCE_DAYS}d, cutoff $CUTOFF)" | tee "$REPORT"
[ -z "$APPLY" ] && echo "   DRY RUN — no mutations. Re-run with --apply to act." | tee -a "$REPORT"

# The payload carries every PR's full comment thread — far too large for the
# environment (ARG_MAX). It goes through a temp file instead.
PR_FILE=$(mktemp "${TMPDIR:-/tmp}/pilot-prclose.XXXXXX")
trap 'rm -f "$PR_FILE"' EXIT
gh pr list --repo "$GITHUB_ISSUES_REPO" --state closed --limit 200 \
  --json number,title,body,mergedAt,closedAt,comments > "$PR_FILE" 2>/dev/null
[ -s "$PR_FILE" ] || { echo "  Could not list PRs." | tee -a "$REPORT"; exit 1; }

CANDIDATES=$(CUTOFF="$CUTOFF" REJECT_RE="$REJECT_RE" PR_FILE="$PR_FILE" python3 <<'PYEOF'
import os, re, json

cutoff = os.environ["CUTOFF"]
rx = re.compile(os.environ["REJECT_RE"], re.I)
BOTS = ("github-actions", "dependabot", "codecov", "vercel", "sonarcloud")
US = "\x1f"   # unit separator: non-whitespace, so bash `read` cannot collapse
              # an empty field into its neighbour (a TAB delimiter does).

BODY_PATS = [r'(?:^|\n)\s*(?:\*\*)?Issue(?:\*\*)?[:\s]+[^\n]*?#(\d+)',
             r'(?:^|\n)\s*(?:\*\*)?Issue(?:\*\*)?[:\s]+[^\n]*?LIFT-(\d+)',
             r'\b(?:closes|fixes|resolves)\s+#(\d+)']

def from_body(text):
    for pat in BODY_PATS:
        m = re.search(pat, text, re.I)
        if m:
            return m.group(1)
    return None

def from_title(title):
    m = re.search(r'LIFT-(\d+)', title) or re.search(r'\(#(\d+)\)\s*$', title)
    return m.group(1) if m else None

with open(os.environ["PR_FILE"]) as fh:
    prs = json.load(fh)

for p in prs:
    if p.get("mergedAt"):
        continue
    if (p.get("closedAt") or "") < cutoff:
        continue

    title = " ".join(p["title"].split())
    b_issue = from_body(p.get("body") or "")
    t_issue = from_title(title)

    if b_issue and t_issue:
        if b_issue == t_issue:
            issue, confidence = b_issue, "confident"
        else:
            print(US.join(["ambiguous", str(p["number"]),
                           "title=%s body=%s" % (t_issue, b_issue), "", title]))
            continue
    elif b_issue or t_issue:
        issue, confidence = (b_issue or t_issue), "weak"
    else:
        continue

    verdict = ""
    for c in reversed(p.get("comments") or []):
        login = ((c.get("author") or {}).get("login") or "").lower()
        if any(bot in login for bot in BOTS):
            continue
        body = (c.get("body") or "").strip()
        if body and rx.search(body):
            verdict = " ".join(body.split())[:300]
        break

    print(US.join([confidence, str(p["number"]), issue, verdict, title]))
PYEOF
)
PY_STATUS=$?
if [ "$PY_STATUS" -ne 0 ]; then
  echo "  ❌ candidate extraction failed (exit $PY_STATUS) — aborting rather than" | tee -a "$REPORT"
  echo "     reporting an empty result set, which would look like a clean run." | tee -a "$REPORT"
  log_error "candidate extraction failed with exit $PY_STATUS"
  exit 1
fi

CLOSED=0; RESET=0; SKIPPED=0; AMBIG=0
if [ -z "$CANDIDATES" ]; then
  echo "  No unmerged PRs closed in the last ${SINCE_DAYS}d with a linked issue." | tee -a "$REPORT"
else
  while IFS=$'\x1f' read -r CONF PR ISSUE VERDICT PRTITLE; do
    [ -z "$CONF" ] && continue

    if [ "$CONF" = "ambiguous" ]; then
      echo "  ？ PR #$PR — conflicting issue links ($ISSUE) — NOT touched — $PRTITLE" | tee -a "$REPORT"
      AMBIG=$((AMBIG+1)); continue
    fi

    STATE=$(gh issue view "$ISSUE" --repo "$GITHUB_ISSUES_REPO" --json state --jq .state 2>/dev/null)
    [ "$STATE" != "OPEN" ] && { SKIPPED=$((SKIPPED+1)); continue; }

    if gh issue view "$ISSUE" --repo "$GITHUB_ISSUES_REPO" --json comments \
         --jq '.comments[].body' 2>/dev/null | grep -qF "$MARKER PR#$PR"; then
      SKIPPED=$((SKIPPED+1)); continue
    fi

    if [ -n "$VERDICT" ] && [ "$CONF" = "confident" ]; then
      echo "  ✖ close #$ISSUE ← PR #$PR — verdict: \"$VERDICT\"" | tee -a "$REPORT"
      if [ -n "$APPLY" ]; then
        gh issue close "$ISSUE" --repo "$GITHUB_ISSUES_REPO" --reason "not planned" \
          --comment "$MARKER PR#$PR
Closing automatically: implementation PR #$PR was closed without merging.

Verdict recorded on that PR:

> $VERDICT

An issue left open after its PR is rejected keeps \`state:started\`, which removes it from triage scope entirely — so nothing re-examines it and the builder keeps re-queueing rejected work. Reopen if this is wrong." >/dev/null 2>&1 || log_warn "close failed for #$ISSUE"
      fi
      CLOSED=$((CLOSED+1))
    else
      WHY="no stated verdict"
      [ "$CONF" = "weak" ] && WHY="single-source issue link (too weak to close)"
      echo "  ↩ triage #$ISSUE ← PR #$PR — $WHY" | tee -a "$REPORT"
      if [ -n "$APPLY" ]; then
        gh issue edit "$ISSUE" --repo "$GITHUB_ISSUES_REPO" \
          --remove-label "state:started" --add-label "state:triage" >/dev/null 2>&1 || true
        gh issue comment "$ISSUE" --repo "$GITHUB_ISSUES_REPO" --body "$MARKER PR#$PR
PR #$PR (\"$PRTITLE\") was closed without merging — $WHY — so this issue is **not** being closed. It has been returned to \`state:triage\` for re-evaluation.

It previously carried \`state:started\`, which excludes it from triage scope; left that way nothing would ever re-examine it." >/dev/null 2>&1 || true
      fi
      RESET=$((RESET+1))
    fi
  done <<< "$CANDIDATES"
fi

echo "" | tee -a "$REPORT"
echo "Closed: $CLOSED   Reset to triage: $RESET   Ambiguous (untouched): $AMBIG   Skipped: $SKIPPED" | tee -a "$REPORT"
[ -z "$APPLY" ] && echo "(dry run — nothing was changed)" | tee -a "$REPORT"

if [ -n "$DO_NOTIFY" ]; then
  bash "$NOTIFY" send automation "🔁 *PR-close reconcile — $DATE*: closed $CLOSED, returned $RESET to triage, $AMBIG ambiguous, $SKIPPED skipped." >/dev/null 2>&1 || true
fi

exit 0
