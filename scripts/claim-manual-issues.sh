#!/bin/bash
# Claim Manual Issues — promotes issues Aaron files by hand to the front of the queue.
#
# THE RULE THIS IMPLEMENTS
#
# Aaron, 2026-08-30: "any issues i manually create myself (not automated via
# pilot) should still be picked up with top priority, even with the ongoing GA
# readiness policy. as a rule, if i take the time to file a ticket myself, I
# want it addressed asap."
#
# WHY A HAND-FILED ISSUE OTHERWISE GOES NOWHERE
#
# Three independent gates buried LIFT-1271 and LIFT-1272 on 2026-08-30:
#
#   1. triage.sh's GA-readiness policy SKIPs any net-new feature as "deferred
#      until post-GA", which stamps priority:4-low.
#   2. builder.sh's pre-pick sorts "anything feature-shaped last".
#   3. The builder only runs Mon-Fri 23:00, so a weekend filing waits anyway.
#
# Net effect: an issue Aaron wrote by hand was demoted within hours of filing
# and never picked. This script closes that gap BEFORE triage can demote it.
#
# HOW A MANUAL ISSUE IS IDENTIFIED
#
# Every issue Pilot creates routes through tracker.sh's gh_create, which always
# attaches a state:* label (adapters/tracker.sh, "Build label string"). That is
# true for all three producers — discover.sh, architect.sh, and builder.sh's
# ISSUE_DISCOVER/ISSUE_CREATE markers. An issue filed through the GitHub UI has
# no state:* label until something in the pipeline gives it one.
#
# So: open + authored by MANUAL_ISSUE_AUTHOR + no state:* label == hand-filed.
#
# Verified on 2026-08-30: 0 of 109 open issues lacked a state:* label, so this
# predicate had no false positives across the entire live backlog and needed no
# backfill. If that ever stops holding, this script over-promotes rather than
# under-promotes — noisy, not destructive, and visible in the report.
#
# WHY THE AUTHOR CHECK MATTERS — do not remove it
#
# aschung212/Lift is a PUBLIC repo. Without the author gate, the first bug
# report from a stranger would promote itself to priority:1-urgent and jump
# ahead of Aaron's entire backlog. Every one of the first 300 issues was
# authored by aschung212, but that is a fact about today, not a guarantee.
# External issues fall through untouched and triage normally.
#
# WHAT IT DOES
#
# For each hand-filed issue:
#   * label origin:aaron        — durable marker; survives triage and re-triage
#   * label priority:1-urgent   — "drop everything"; nothing else in the backlog
#                                 carries P1, so this alone wins the pre-pick
#   * label state:unstarted     — puts it in the builder's pickable pool
#   * leave a marker comment explaining the promotion
#
# It deliberately does NOT carry the "Triaged by" marker that triage.sh greps
# for. A promoted issue SHOULD still be triaged — triage's ENHANCE path adds
# implementation guidance worth having. The GA-policy carve-out in triage.sh
# keyed on origin:aaron is what stops it being SKIPped, not an idempotency
# dodge. (The manual 2026-08-30 exemption on LIFT-1271/1272 did use the
# "Triaged by" dodge, because Aaron chose to force-build those two directly.)
#
# Idempotent: the origin:aaron label is the marker. An issue already carrying
# it is skipped, and the state:unstarted this script adds also removes the
# issue from its own selection predicate on later runs.
#
# HOW IT RUNS
#
# Invoked automatically by triage.sh (before its `list triageable` query) and
# by builder.sh (before it fetches the backlog for the pre-pick), so an issue
# filed at any point in the day is promoted by whichever stage next wakes up.
# Both callers pass --apply and treat a failure here as non-fatal.
# MANUAL_CLAIM_ENABLED=0 disables it.
#
# Usage (manual runs still work):
#   ./claim-manual-issues.sh                  # DRY RUN (default)
#   ./claim-manual-issues.sh --apply
#   ./claim-manual-issues.sh --apply --notify
#   ./claim-manual-issues.sh --apply --author someoneelse

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="claim-manual-issues"

DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
REPORT="$OUTPUT_DIR/lift-claim-manual-$DATE.md"
MARKER="<!-- pilot:claim-manual -->"

# Default is DRY RUN. This script rewrites priority on live issues; a bare
# invocation must never mutate the tracker.
APPLY=""
DO_NOTIFY=""
AUTHOR_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) APPLY="" ;;
    --apply)   APPLY="1" ;;
    --notify)  DO_NOTIFY="1" ;;
    --author)  shift; AUTHOR_OVERRIDE="${1:?--author needs a GitHub login}" ;;
    *) echo "Unknown argument: $1 (valid: --dry-run, --apply, --notify, --author LOGIN)" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$OUTPUT_DIR"
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found" >&2; exit 1; }
: "${GITHUB_ISSUES_REPO:?GITHUB_ISSUES_REPO not set — run init.sh}"

# Defaults to the repo owner, which is who files issues by hand here. Kept
# overridable so this is not hardcoded to one GitHub login.
MANUAL_ISSUE_AUTHOR="${AUTHOR_OVERRIDE:-${MANUAL_ISSUE_AUTHOR:-${GITHUB_ISSUES_REPO%%/*}}}"
MANUAL_CLAIM_PRIORITY_LABEL="${MANUAL_CLAIM_PRIORITY_LABEL:-priority:1-urgent}"
ORIGIN_LABEL="origin:aaron"

if [ "${MANUAL_CLAIM_ENABLED:-1}" = "0" ]; then
  echo "🙋 Claim Manual Issues — disabled via MANUAL_CLAIM_ENABLED=0, skipping."
  exit 0
fi

echo "🙋 Claim Manual Issues — $DATE (author: $MANUAL_ISSUE_AUTHOR)" | tee "$REPORT"
[ -z "$APPLY" ] && echo "   DRY RUN — no mutations. Re-run with --apply to act." | tee -a "$REPORT"

# ── Ensure the marker label exists ──────────────────────────────────────────
# Same bootstrap pattern as architect.sh's "architect:" label. Harmless when it
# already exists; `gh label create` errors and we swallow it.
if [ -n "$APPLY" ] && [ -z "${_PILOT_TEST_MODE:-}" ]; then
  gh label create "$ORIGIN_LABEL" \
    --repo "$GITHUB_ISSUES_REPO" \
    --color "B60205" \
    --description "Filed by hand by Aaron — GA-policy exempt, top priority" \
    2>/dev/null || true
fi

# ── Select hand-filed issues ────────────────────────────────────────────────
# Shares GH_OPEN_LIMIT with tracker.sh's open-issue queries. `gh issue list`
# truncates silently at --limit, so a cap under the real open-issue count would
# hide freshly-filed issues here with no visible symptom (see the truncation
# warnings in adapters/tracker.sh).
CLAIM_LIMIT="${GH_OPEN_LIMIT:-1000}"
CANDIDATES=$(gh issue list --repo "$GITHUB_ISSUES_REPO" --state open --limit "$CLAIM_LIMIT" \
  --json number,title,labels,author \
  --jq ".[]
        | select(.author.login == \"$MANUAL_ISSUE_AUTHOR\")
        | select([.labels[].name] | any(startswith(\"state:\")) | not)
        | select([.labels[].name] | index(\"$ORIGIN_LABEL\") | not)
        | \"\(.number)\t\(.title)\"" 2>/dev/null || true)

# Truncation guard, matching tracker.sh's _warn_if_truncated contract.
_open_total=$(gh issue list --repo "$GITHUB_ISSUES_REPO" --state open \
  --limit "$CLAIM_LIMIT" --json number -q 'length' 2>/dev/null || echo 0)
if [ "${_open_total:-0}" -ge "$CLAIM_LIMIT" ] 2>/dev/null; then
  echo "⚠️  claim-manual-issues: open-issue query returned ${_open_total} rows at the ${CLAIM_LIMIT} cap — list is probably TRUNCATED. Raise GH_OPEN_LIMIT." | tee -a "$REPORT" >&2
fi

if [ -z "$CANDIDATES" ]; then
  echo "  No unclaimed hand-filed issues." | tee -a "$REPORT"
  exit 0
fi

# `grep -c` through a pipe returns padded output that breaks arithmetic tests.
CLAIM_COUNT=$(echo "$CANDIDATES" | grep -c . | tr -d ' \n')
echo "  Found $CLAIM_COUNT hand-filed issue(s) to promote." | tee -a "$REPORT"

CLAIMED=0
CLAIMED_LIST=""
while IFS=$'\t' read -r num title; do
  [ -z "$num" ] && continue
  issue_id="${ISSUE_PREFIX}-${num}"
  issue_url="https://github.com/${GITHUB_ISSUES_REPO}/issues/${num}"

  if [ -z "$APPLY" ]; then
    echo "  ⤴️  would promote $issue_id — $title" | tee -a "$REPORT"
    CLAIMED=$((CLAIMED + 1))
    CLAIMED_LIST+="  • <${issue_url}|${issue_id}>: ${title}\n"
    continue
  fi

  # Labels first: the promotion is what matters, the comment is commentary.
  if gh issue edit "$num" --repo "$GITHUB_ISSUES_REPO" \
       --add-label "$ORIGIN_LABEL" \
       --add-label "$MANUAL_CLAIM_PRIORITY_LABEL" \
       --add-label "state:unstarted" >/dev/null 2>&1; then
    echo "  ⤴️  promoted $issue_id — $title" | tee -a "$REPORT"
    CLAIMED=$((CLAIMED + 1))
    CLAIMED_LIST+="  • <${issue_url}|${issue_id}>: ${title}\n"

    bash "$TRACKER" comment-add "$issue_id" "$MARKER
**Promoted by Pilot** ($DATE) — 🙋 hand-filed by @${MANUAL_ISSUE_AUTHOR}

This issue was filed by hand rather than by a Pilot agent, so it is exempt from
the GA-readiness policy and has been moved to the front of the queue:
\`$MANUAL_CLAIM_PRIORITY_LABEL\` + \`$ORIGIN_LABEL\` + \`state:unstarted\`.

Standing rule (2026-08-30): if Aaron takes the time to file a ticket himself, it
gets addressed ASAP — including net-new features that the GA policy would
otherwise defer until post-GA.

Triage still reviews this issue normally and may add implementation guidance;
what it may **not** do is SKIP it for being feature-shaped.

---
_Automated — to opt an issue out, remove the \`$ORIGIN_LABEL\` label and set the priority you want._" >/dev/null 2>&1 || true
  else
    echo "  ⚠️  failed to promote $issue_id — $title" | tee -a "$REPORT"
  fi
done <<< "$CANDIDATES"

echo "" | tee -a "$REPORT"
echo "Promoted: $CLAIMED" | tee -a "$REPORT"
log_info "Claim-manual complete: $CLAIMED promoted (author $MANUAL_ISSUE_AUTHOR)"

if [ -n "$DO_NOTIFY" ] && [ "$CLAIMED" -gt 0 ] && [ -z "${_PILOT_TEST_MODE:-}" ]; then
  bash "$NOTIFY" send-async automation "🙋 *Hand-filed issues promoted* — $DATE

$(printf '%b' "$CLAIMED_LIST")
_Filed by hand, so exempt from the GA-readiness policy and queued at top priority._" >/dev/null 2>&1 || true
fi

exit 0
