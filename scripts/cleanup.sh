#!/bin/bash
# Issue Tracker Cleanup — archives completed/canceled issues and deduplicates backlog.
# Runs at the end of each overnight session to preserve free tier capacity.
#
# What it does:
#   1. Archives all completed and canceled issues
#   2. Detects and cancels+archives duplicate issues (same title, keeps oldest)
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

# Get Linear API token from CLI config (needed for archive — not in CLI)
LINEAR_TOKEN=$(grep -v '^default\|^\[' ~/.config/linear/credentials.toml 2>/dev/null | head -1 | sed 's/.*= *"//' | sed 's/"//')
if [ -z "$LINEAR_TOKEN" ]; then
  echo "  ⚠️ No Linear API token found — skipping cleanup."
  exit 0
fi

# Helper: get UUID for an issue ID (e.g., MAS-123)
get_uuid() {
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ issue(id: \\\"$1\\\") { id } }\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['issue']['id'])" 2>/dev/null
}

# Helper: archive an issue by UUID
archive_issue() {
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"mutation { issueArchive(id: \\\"$1\\\") { success } }\"}" >/dev/null 2>&1
}

ARCHIVED=0
DEDUPED=0
ARCHIVED_LIST=""

# ── Step 1: Archive completed and canceled issues ──────────────────────────
for state in completed canceled; do
  RAW_OUTPUT=$(bash "$TRACKER" list "$state" || true)
  IDS=$(echo "$RAW_OUTPUT" | grep -oE "${LINEAR_TEAM}-[0-9]+" || true)

  for issue_id in $IDS; do
    # Get clean title via view command (avoids parsing fixed-width CLI columns)
    TITLE=$(bash "$TRACKER" view "$issue_id" 2>/dev/null | head -1 | sed "s/^# *${issue_id}: *//" | sed 's/[[:space:]]*$//')
    [ -z "$TITLE" ] && TITLE="(unknown)"
    if [ "$DRY_RUN" = "--dry-run" ]; then
      echo "  [dry-run] Would archive $issue_id ($state): $TITLE"
    else
      UUID=$(get_uuid "$issue_id")
      if [ -n "$UUID" ]; then
        archive_issue "$UUID"
        ARCHIVED=$((ARCHIVED + 1))
        ARCHIVED_LIST+="  • ${issue_id} (${state}): ${TITLE}\n"
      fi
    fi
  done
done

# ── Step 2: Deduplicate issues (same title, cancel+archive newer ones) ─────
ALL_ISSUES=$(bash "$TRACKER" list backlog unstarted started triage || true)

# Extract ID and title pairs, find duplicates by title
echo "$ALL_ISSUES" | grep -oE "${LINEAR_TEAM}-[0-9]+" | while read -r issue_id; do
  TITLE=$(bash "$TRACKER" view "$issue_id" | head -1 | sed "s/^# *${LINEAR_TEAM}-[0-9]*: *//")
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
    echo "  [dry-run] Would cancel+archive duplicate $dup_id"
  else
    bash "$TRACKER" update "$dup_id" --state canceled >/dev/null
    UUID=$(get_uuid "$dup_id")
    if [ -n "$UUID" ]; then
      archive_issue "$UUID"
      DEDUPED=$((DEDUPED + 1))
    fi
  fi
done

# Cleanup metrics CSV
CLEANUP_METRICS_CSV="$OUTPUT_DIR/lift-cleanup-metrics.csv"
if [ ! -f "$CLEANUP_METRICS_CSV" ]; then
  echo "date,archived,deduped" > "$CLEANUP_METRICS_CSV"
fi

if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$ARCHIVED,$DEDUPED" >> "$CLEANUP_METRICS_CSV"
  log_info "Cleanup: $ARCHIVED archived, $DEDUPED deduped"
  echo "  ✅ Linear cleanup: $ARCHIVED archived, $DEDUPED deduped"
  if [ -n "$ARCHIVED_LIST" ]; then
    echo "  Archived issues:"
    echo -e "$ARCHIVED_LIST"
  fi
else
  echo "  [dry-run] Cleanup preview complete."
fi
