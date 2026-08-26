#!/bin/bash
# Issue Tracker Cleanup — closes completed/canceled issues and deduplicates backlog.
# Runs at the end of each overnight session to keep the board clean.
#
# What it does:
#   1. Closes all completed and canceled issues (via tracker.sh)
#   2. Detects and closes duplicate issues (same title, keeps oldest)
#   3. Reports what was cleaned up
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

# Cleanup metrics CSV
# `recycled` was appended as a 4th column on 2026-07-27; rows written before
# that date have 3 fields. Anything parsing this file must tolerate both.
CLEANUP_METRICS_CSV="$OUTPUT_DIR/lift-cleanup-metrics.csv"
if [ ! -f "$CLEANUP_METRICS_CSV" ]; then
  echo "date,closed,deduped,recycled" > "$CLEANUP_METRICS_CSV"
fi

if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$CLOSED,$DEDUPED,$RECYCLED" >> "$CLEANUP_METRICS_CSV"
  log_info "Cleanup: $CLOSED closed, $DEDUPED deduped, $RECYCLED recycled ($ALREADY_CLOSED already closed, skipped)"
  echo "  ✅ Cleanup: $CLOSED closed, $DEDUPED deduped, $RECYCLED recycled ($ALREADY_CLOSED already closed, skipped)"
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
