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
CLOSED_LIST=""

# ── Step 1: Close completed and canceled issues ──────────────────────────
for state in completed canceled; do
  RAW_OUTPUT=$(bash "$TRACKER" list "$state" || true)
  IDS=$(echo "$RAW_OUTPUT" | grep -oE "${ISSUE_PREFIX}-[0-9]+" || true)

  for issue_id in $IDS; do
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

# ── Step 2: Deduplicate issues (same title, close newer ones) ────────────
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
CLEANUP_METRICS_CSV="$OUTPUT_DIR/lift-cleanup-metrics.csv"
if [ ! -f "$CLEANUP_METRICS_CSV" ]; then
  echo "date,closed,deduped" > "$CLEANUP_METRICS_CSV"
fi

if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$CLOSED,$DEDUPED" >> "$CLEANUP_METRICS_CSV"
  log_info "Cleanup: $CLOSED closed, $DEDUPED deduped"
  echo "  ✅ Cleanup: $CLOSED closed, $DEDUPED deduped"
  if [ -n "$CLOSED_LIST" ]; then
    echo "  Closed issues:"
    echo -e "$CLOSED_LIST"
  fi
else
  echo "  [dry-run] Cleanup preview complete."
fi
