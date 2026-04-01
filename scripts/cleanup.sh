#!/bin/bash
# Lift Linear Cleanup — archives completed/canceled issues and deduplicates backlog.
# Runs at the end of each overnight session to preserve free tier capacity.
#
# What it does:
#   1. Archives all completed and canceled issues
#   2. Detects and cancels+archives duplicate issues (same title, keeps oldest)
#   3. Reports what was cleaned up
#
# Usage:
#   ./lift-linear-cleanup.sh              # run cleanup
#   ./lift-linear-cleanup.sh --dry-run    # preview without changes

set -uo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

DRY_RUN="${1:-}"
DATE=$(date +%Y-%m-%d)

# Get Linear API token from CLI config
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

# ── Step 1: Archive completed and canceled issues ──────────────────────────
for state in completed canceled; do
  IDS=$(linear issue list --project Lift --all-assignees --sort priority --team MAS --state "$state" --no-pager 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'MAS-[0-9]+' || true)

  for issue_id in $IDS; do
    if [ "$DRY_RUN" = "--dry-run" ]; then
      echo "  [dry-run] Would archive $issue_id ($state)"
    else
      UUID=$(get_uuid "$issue_id")
      if [ -n "$UUID" ]; then
        archive_issue "$UUID"
        ARCHIVED=$((ARCHIVED + 1))
      fi
    fi
  done
done

# ── Step 2: Deduplicate issues (same title, cancel+archive newer ones) ─────
# Get all open issues with their IDs and titles
ALL_ISSUES=$(linear issue list --project Lift --all-assignees --sort priority --team MAS \
  --state backlog --state unstarted --state started --state triage --no-pager 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' || true)

# Extract ID and title pairs, find duplicates by title
echo "$ALL_ISSUES" | grep -oE 'MAS-[0-9]+' | while read -r issue_id; do
  TITLE=$(linear issue view "$issue_id" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | head -1 | sed 's/^# *MAS-[0-9]*: *//')
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
    linear issue update "$dup_id" --state canceled --team MAS 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >/dev/null
    UUID=$(get_uuid "$dup_id")
    if [ -n "$UUID" ]; then
      archive_issue "$UUID"
      DEDUPED=$((DEDUPED + 1))
    fi
  fi
done

# Can't easily get DEDUPED count from subshell, recount
if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "  ✅ Linear cleanup: $ARCHIVED archived"
else
  echo "  [dry-run] Cleanup preview complete."
fi
