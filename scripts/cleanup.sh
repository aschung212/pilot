#!/bin/bash
# Issue Tracker Cleanup — closes completed/canceled issues and deduplicates backlog.
# Runs at the end of each overnight session to keep the board clean.
#
# What it does:
#   1. Closes all completed and canceled issues (via tracker.sh)
#   2. Recycles abandoned in-progress issues (claimed but no PR ever opened)
#   2b. Snapshots rejected-PR issues for the morning digest and harvests
#       Aaron's closing comments on unmerged PRs into lift-build-learnings.md
#       (the builder feeds these back into its prompt)
#   3. Detects and closes duplicate issues (same title, keeps oldest)
#   4. Expires stale priority-4 backlog issues (untouched > BACKLOG_EXPIRY_DAYS)
#   5. Reports what was cleaned up
#
# Usage:
#   ./cleanup.sh              # run cleanup
#   ./cleanup.sh --dry-run    # preview without changes

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="cleanup"

DRY_RUN="${1:-}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"

CLOSED=0
DEDUPED=0
ALREADY_CLOSED=0
CLOSED_LIST=""

# ── Step 1: Close completed and canceled issues ──────────────────────────
# tracker-state completed/canceled maps directly onto GitHub's closed state, so
# almost every issue listed here was already closed in a prior session. Check
# the live GitHub state and skip the ones already closed — otherwise this fires
# ~100 redundant `gh issue close` writes per run and inflates the reported count
# with re-processed issues instead of real open→closed transitions.
for state in completed canceled; do
  RAW_OUTPUT=$(bash "$TRACKER" list "$state" || true)
  IDS=$(echo "$RAW_OUTPUT" | grep -oE "${ISSUE_PREFIX}-[0-9]+" || true)

  for issue_id in $IDS; do
    if [ "$(bash "$TRACKER" state "$issue_id" 2>/dev/null || true)" = "CLOSED" ]; then
      ALREADY_CLOSED=$((ALREADY_CLOSED + 1))
      continue
    fi
    TITLE=$(bash "$TRACKER" view "$issue_id" 2>/dev/null | head -1 | sed "s/^# *${issue_id}: *//" | sed 's/[[:space:]]*$//')
    [ -z "$TITLE" ] && TITLE="(unknown)"
    if [ "$DRY_RUN" = "--dry-run" ]; then
      echo "  [dry-run] Would close $issue_id ($state): $TITLE"
    else
      REASON="completed"
      [ "$state" = "canceled" ] && REASON="not_planned"
      bash "$TRACKER" close "$issue_id" "$REASON" 2>/dev/null || true
      CLOSED=$((CLOSED + 1))
      CLOSED_LIST+="  • ${issue_id} (${state}): ${TITLE}\n"
    fi
  done
done

# ── Step 2: Recycle abandoned in-progress issues ─────────────────────────
# An issue gets state:started the moment an iteration claims it (pre-pick
# flips it before implementation). If that iteration then dies before opening
# a PR — auth blip, CI failure, context exhaustion, Aaron killing the run —
# nothing ever clears the label. The issue is silently and permanently
# removed from `tracker.sh list pickable`, because "pickable" excludes
# state:started.
#
# This leaks the backlog one issue at a time. By 2026-07-27 it had stranded
# 14 issues and starved the picking pool down to 2, ending both 2026-07-23
# run 3 and the entire 2026-07-24 session after a single iteration with
# NO_IMPROVEMENTS_REMAINING and zero PRs.
#
# Recycle rule — deliberately conservative: reset to state:unstarted ONLY
# when NO pull request of ANY state references the issue. An issue whose PR
# was closed unmerged is left alone and reported instead, because closing a
# PR may have been a deliberate rejection and auto-recycling it would rebuild
# work Aaron already declined. Issues with a merged PR are also left alone —
# those are complete and belong to the close path, not the recycle path.
RECYCLED=0
RECYCLED_LIST=""
DONE_AWAITING_CLOSE=0
IN_FLIGHT=0
REJECTED_PR=0
REJECTED_PR_LIST=""
REJECTED_PR_IDS=""

# Two API calls for every PR title, rather than a per-issue search (~145
# calls). Builder PR titles always embed the issue as `type(LIFT-N): ...`,
# and manual PRs use `#N`, so title matching covers both conventions.
_pr_refs() {
  grep -oE "(${ISSUE_PREFIX}-|#)[0-9]+" | sed -E "s/^#/${ISSUE_PREFIX}-/" | sort -u
}
ALL_PR_REFS=$(gh pr list --repo "$GITHUB_ISSUES_REPO" --state all --limit 500 \
  --json title -q '.[].title' 2>/dev/null | _pr_refs || true)
MERGED_PR_REFS=$(gh pr list --repo "$GITHUB_ISSUES_REPO" --state merged --limit 500 \
  --json title -q '.[].title' 2>/dev/null | _pr_refs || true)
OPEN_PR_REFS=$(gh pr list --repo "$GITHUB_ISSUES_REPO" --state open --limit 500 \
  --json title -q '.[].title' 2>/dev/null | _pr_refs || true)

STARTED_IDS=$(bash "$TRACKER" list started 2>/dev/null | grep -oE "${ISSUE_PREFIX}-[0-9]+" | sort -u || true)

for issue_id in $STARTED_IDS; do
  # grep -qx anchors the whole line, so LIFT-96 cannot match LIFT-966.
  if echo "$MERGED_PR_REFS" | grep -qx "$issue_id"; then
    # Work merged but the issue was never closed — belongs to the close path.
    DONE_AWAITING_CLOSE=$((DONE_AWAITING_CLOSE + 1))
    continue
  fi
  if echo "$OPEN_PR_REFS" | grep -qx "$issue_id"; then
    # PR is open and awaiting review — normal in-flight state, no action.
    IN_FLIGHT=$((IN_FLIGHT + 1))
    continue
  fi
  if echo "$ALL_PR_REFS" | grep -qx "$issue_id"; then
    # Every PR for this issue was closed without merging. Could be a
    # deliberate rejection — report, never auto-recycle.
    REJECTED_PR=$((REJECTED_PR + 1))
    REJECTED_PR_LIST+="  • ${issue_id}\n"
    REJECTED_PR_IDS+="${issue_id}
"
    continue
  fi
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "  [dry-run] Would recycle $issue_id (state:started, no PR ever) → state:unstarted"
    RECYCLED=$((RECYCLED + 1))
  else
    bash "$TRACKER" update "$issue_id" --state unstarted >/dev/null 2>&1 || true
    RECYCLED=$((RECYCLED + 1))
    RECYCLED_LIST+="  • ${issue_id}\n"
  fi
done

# ── Step 2b: Needs-decision snapshot + rejection-learnings harvest ────────
# Two consumers outside this run need the rejected-PR signal:
#   • digest.sh surfaces the "needs your call" list in the morning digest —
#     blockers belong in the daily standup, not buried in an overnight log.
#   • builder.sh reads lift-build-learnings.md (Aaron's closing comments on
#     PRs he closed unmerged) at the top of every night, so future iterations
#     stop repeating rejected approaches. This restores the human-feedback
#     loop that died when the review tuner was removed (2026-05-11) — Aaron's
#     merge/reject decisions were the one signal nothing learned from.
NEEDS_DECISION_FILE="$OUTPUT_DIR/lift-needs-decision.txt"
LEARNINGS_FILE="$OUTPUT_DIR/lift-build-learnings.md"
HARVESTED=0
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "  [dry-run] Would refresh $(basename "$NEEDS_DECISION_FILE") snapshot and harvest rejection learnings"
else
  # Snapshot (overwrite, not append — it mirrors the current rejected set).
  printf '%s' "$REJECTED_PR_IDS" > "$NEEDS_DECISION_FILE"

  if [ ! -f "$LEARNINGS_FILE" ]; then
    printf '# Build learnings — why Aaron rejected builder PRs\n# Harvested nightly by cleanup.sh from closing comments on PRs closed without merging.\n# builder.sh injects the tail of this file into every iteration prompt.\n' > "$LEARNINGS_FILE"
  fi

  # Every PR closed without merging in the last 14 days gets one entry, keyed
  # by "## PR #N " so re-runs are idempotent. The reason is the last human
  # comment on the PR (the repo owner's comment wins over other commenters);
  # a missing comment is recorded too, as a nudge to leave one next time.
  REPO_OWNER="${GITHUB_ISSUES_REPO:-}"
  REPO_OWNER="${REPO_OWNER%%/*}"
  NEW_LEARNINGS=$(gh pr list --repo "${GITHUB_ISSUES_REPO:-}" --state closed --limit 100 \
    --json number,title,closedAt,mergedAt,comments 2>/dev/null \
    | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta

learnings_path, owner = sys.argv[1], sys.argv[2]
try:
    prs = json.load(sys.stdin)
    assert isinstance(prs, list)
except Exception:
    sys.exit(0)   # gh unavailable / non-JSON output — harvest nothing
try:
    with open(learnings_path) as f:
        existing = f.read()
except OSError:
    existing = ''
cutoff = datetime.now(timezone.utc) - timedelta(days=14)

def ts(s):
    try:
        return datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except Exception:
        return None

for pr in prs:
    if not isinstance(pr, dict) or pr.get('mergedAt'):
        continue
    closed = ts(pr.get('closedAt'))
    if not closed or closed < cutoff:
        continue
    num = pr.get('number')
    if not num or f'## PR #{num} ' in existing:
        continue
    reason = ''
    for c in pr.get('comments') or []:
        login = ((c.get('author') or {}).get('login') or '')
        if 'bot' in login.lower() or login == 'github-actions':
            continue
        body = (c.get('body') or '').strip()
        if not body:
            continue
        if owner and login == owner:
            reason = body            # last owner comment wins
        elif not reason:
            reason = body            # any human comment beats nothing
    if not reason:
        reason = '(no close comment — leave one when rejecting so the builder can learn from it)'
    if len(reason) > 600:
        reason = reason[:600] + '…'
    title = (pr.get('title') or '').strip()
    print(f\"\n## PR #{num} — {title} (closed unmerged {closed.strftime('%Y-%m-%d')})\n{reason}\")
" "$LEARNINGS_FILE" "$REPO_OWNER" 2>/dev/null || true)
  if [ -n "$NEW_LEARNINGS" ]; then
    printf '%s\n' "$NEW_LEARNINGS" >> "$LEARNINGS_FILE"
    HARVESTED=$({ printf '%s\n' "$NEW_LEARNINGS" | grep -c '^## PR #' || echo "0"; } | head -1)
  fi
fi

# ── Step 3: Deduplicate issues (same title, close newer ones) ────────────
ALL_ISSUES=$(bash "$TRACKER" list backlog unstarted started triage || true)

# Extract ID and title pairs, find duplicates by title
echo "$ALL_ISSUES" | grep -oE "${ISSUE_PREFIX}-[0-9]+" | while read -r issue_id; do
  TITLE=$(bash "$TRACKER" view "$issue_id" 2>/dev/null | head -1 | sed "s/^# *${ISSUE_PREFIX}-[0-9]*: *//")
  echo "$issue_id|$TITLE"
done | sort -t'|' -k2 | python3 -c "
import sys
from collections import defaultdict

# Group issues by title
by_title = defaultdict(list)
for line in sys.stdin:
    line = line.strip()
    if '|' not in line:
        continue
    issue_id, title = line.split('|', 1)
    title = title.strip().lower()
    if title:
        by_title[title].append(issue_id.strip())

# For duplicate titles, keep the oldest (lowest number), print the rest
for title, ids in by_title.items():
    if len(ids) > 1:
        # Sort by issue number
        ids.sort(key=lambda x: int(x.split('-')[1]))
        for dup_id in ids[1:]:
            print(dup_id)
" | while read -r dup_id; do
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "  [dry-run] Would close duplicate $dup_id"
  else
    bash "$TRACKER" update "$dup_id" --state canceled >/dev/null 2>&1 || true
    bash "$TRACKER" close "$dup_id" "not_planned" 2>/dev/null || true
    DEDUPED=$((DEDUPED + 1))
  fi
done

# ── Step 4: Expire stale priority-4 backlog issues ───────────────────────
# Triage SKIP demotes issues to priority:4-low and nothing ever looked at them
# again — they accumulate forever, inflate every prompt's backlog list, and
# push the adapter toward its silent `--limit 200` truncation cliff. The
# backlog is not a museum: anything P4 and untouched for BACKLOG_EXPIRY_DAYS
# (default 56 ≈ 8 weeks; 0 disables) is closed as not planned with a reopen
# invitation. Parked issues (started/blocked/needs-input) are never expired —
# those are waiting on a human, not forgotten. Filtering is client-side in
# python because gh's date-search qualifier cannot also exclude labels.
BACKLOG_EXPIRY_DAYS="${BACKLOG_EXPIRY_DAYS:-56}"
EXPIRED=0
EXPIRED_LIST=""
if [ "$BACKLOG_EXPIRY_DAYS" -gt 0 ] 2>/dev/null && [ -n "${GITHUB_ISSUES_REPO:-}" ]; then
  STALE_NUMS=$(gh issue list --repo "$GITHUB_ISSUES_REPO" --state open \
    --label "priority:4-low" --limit "${GH_OPEN_LIMIT:-1000}" --json number,updatedAt,labels 2>/dev/null \
    | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
days = int(sys.argv[1])
try:
    issues = json.load(sys.stdin)
    assert isinstance(issues, list)
except Exception:
    sys.exit(0)   # gh unavailable / non-JSON output — expire nothing
cutoff = datetime.now(timezone.utc) - timedelta(days=days)
PARKED = {'state:started', 'state:blocked', 'state:needs-input'}
for i in issues:
    if not isinstance(i, dict) or not i.get('number'):
        continue
    labels = {l.get('name') for l in (i.get('labels') or []) if isinstance(l, dict)}
    if labels & PARKED:
        continue
    try:
        upd = datetime.fromisoformat(str(i.get('updatedAt')).replace('Z', '+00:00'))
    except Exception:
        continue
    if upd < cutoff:
        print(i['number'])
" "$BACKLOG_EXPIRY_DAYS" 2>/dev/null || true)
  for num in $STALE_NUMS; do
    issue_id="${ISSUE_PREFIX}-${num}"
    if [ "$DRY_RUN" = "--dry-run" ]; then
      echo "  [dry-run] Would expire $issue_id (priority:4-low, untouched ≥ ${BACKLOG_EXPIRY_DAYS}d)"
      EXPIRED=$((EXPIRED + 1))
    else
      bash "$TRACKER" comment-add "$issue_id" "Auto-closed as stale: priority 4 and untouched for ${BACKLOG_EXPIRY_DAYS}+ days. The backlog only keeps work still worth doing — reopen (and bump priority) if this is still relevant." 2>/dev/null || true
      bash "$TRACKER" close "$issue_id" "not_planned" 2>/dev/null || true
      EXPIRED=$((EXPIRED + 1))
      EXPIRED_LIST+="  • ${issue_id}\n"
    fi
  done
fi

# Cleanup metrics CSV
# Column history: `recycled` appended as a 4th column 2026-07-27, `expired` as
# a 5th on 2026-08-28. Rows written earlier have 3 or 4 fields — anything
# parsing this file must tolerate all widths.
CLEANUP_METRICS_CSV="$OUTPUT_DIR/lift-cleanup-metrics.csv"
if [ ! -f "$CLEANUP_METRICS_CSV" ]; then
  echo "date,closed,deduped,recycled,expired" > "$CLEANUP_METRICS_CSV"
fi

if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$CLOSED,$DEDUPED,$RECYCLED,$EXPIRED" >> "$CLEANUP_METRICS_CSV"
  log_info "Cleanup: $CLOSED closed, $DEDUPED deduped, $RECYCLED recycled, $EXPIRED expired, $HARVESTED learnings harvested ($ALREADY_CLOSED already closed, skipped)"
  echo "  ✅ Cleanup: $CLOSED closed, $DEDUPED deduped, $RECYCLED recycled, $EXPIRED expired, $HARVESTED learnings harvested ($ALREADY_CLOSED already closed, skipped)"
  if [ "$EXPIRED" -gt 0 ] && [ -n "$EXPIRED_LIST" ]; then
    echo "  🗑  Expired stale P4 issues (reopen if still relevant):"
    echo -e "$EXPIRED_LIST"
  fi
  if [ -n "$CLOSED_LIST" ]; then
    echo "  Closed issues:"
    echo -e "$CLOSED_LIST"
  fi
  if [ -n "$RECYCLED_LIST" ]; then
    echo "  ♻️  Recycled to unstarted (claimed but no PR ever opened):"
    echo -e "$RECYCLED_LIST"
  fi
else
  echo "  [dry-run] Cleanup preview complete ($ALREADY_CLOSED already closed, skipped)."
fi

# Always surface the two categories cleanup deliberately will NOT touch, so a
# growing pile of either is visible instead of silently shrinking the backlog.
if [ "$DONE_AWAITING_CLOSE" -gt 0 ]; then
  echo "  📋 $DONE_AWAITING_CLOSE issue(s) still state:started with a MERGED PR — work is done, issue never closed."
fi
if [ "$REJECTED_PR" -gt 0 ]; then
  echo "  ⚠️  $REJECTED_PR issue(s) stuck at state:started whose PR was closed unmerged — needs your call"
  echo "      (recycle to state:unstarted to rebuild, or close as not planned):"
  echo -e "$REJECTED_PR_LIST"
fi
