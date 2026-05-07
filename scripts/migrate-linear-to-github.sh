#!/bin/bash
# One-time migration: Export Lift issues from Linear to GitHub Issues.
# Creates GitHub issues with matching labels, descriptions, and comments.
# Produces a mapping CSV: linear_id,github_number
#
# Usage:
#   ./migrate-linear-to-github.sh              # run migration
#   ./migrate-linear-to-github.sh --dry-run    # preview without creating issues

set -uo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
DRY_RUN="${1:-}"
MAPPING_FILE="$SCRIPT_DIR/../config/linear-github-mapping.csv"
GITHUB_REPO="${GITHUB_REPO:-aschung212/Lift}"
DATE=$(date +%Y-%m-%d)

mkdir -p "$(dirname "$MAPPING_FILE")"

# Initialize mapping file
if [ ! -f "$MAPPING_FILE" ]; then
  echo "linear_id,github_number" > "$MAPPING_FILE"
fi

# Already-migrated IDs (skip duplicates)
migrated_ids() {
  tail -n +2 "$MAPPING_FILE" 2>/dev/null | cut -d',' -f1
}

# Map Linear state to GitHub labels
state_to_label() {
  case "$1" in
    triage)      echo "state:triage" ;;
    backlog)     echo "state:backlog" ;;
    unstarted)   echo "state:unstarted" ;;
    started)     echo "state:started" ;;
    completed)   echo "" ;;  # just close the issue
    canceled)    echo "state:canceled" ;;
    blocked)     echo "state:blocked" ;;
    *)           echo "state:backlog" ;;
  esac
}

# Map Linear priority (1-4) to GitHub label
priority_to_label() {
  case "$1" in
    1) echo "priority:1-urgent" ;;
    2) echo "priority:2-high" ;;
    3) echo "priority:3-medium" ;;
    4) echo "priority:4-low" ;;
    *) echo "priority:3-medium" ;;
  esac
}

# Extract priority from Linear issue view output
parse_priority() {
  # Linear view shows "Priority: Urgent/High/Medium/Low/None"
  local detail="$1"
  local prio
  prio=$(echo "$detail" | grep -i "priority" | head -1)
  case "$prio" in
    *[Uu]rgent*) echo "1" ;;
    *[Hh]igh*)   echo "2" ;;
    *[Mm]edium*) echo "3" ;;
    *[Ll]ow*)    echo "4" ;;
    *)           echo "3" ;;
  esac
}

# Extract labels from Linear issue view output
parse_labels() {
  local detail="$1"
  # Linear view shows "Labels: Label1, Label2"
  echo "$detail" | grep -i "^labels:" | sed 's/^[Ll]abels: *//' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | while read -r label; do
    [ -n "$label" ] && echo "$label"
  done
}

# Extract description (everything after the header block)
parse_description() {
  local detail="$1"
  # Skip the header lines (title, project, cycle, etc.) and comments section
  echo "$detail" | sed -n '/^$/,/^## Comments/p' | sed '1d;/^## Comments/d' | sed '/^$/d'
}

STRIP_ANSI='sed s/\x1b\[[0-9;]*m//g'
TOTAL=0
CREATED=0
SKIPPED=0

echo "=== Linear → GitHub Migration — $DATE ==="
echo "    Repo: $GITHUB_REPO"
echo "    Mapping: $MAPPING_FILE"
echo ""

# Process all states
for state in triage backlog unstarted started completed canceled; do
  echo "── Processing state: $state ──"

  RAW=$(bash "$TRACKER" list --project "Lift" "$state" 2>/dev/null || true)
  IDS=$(echo "$RAW" | grep -oE "${LINEAR_TEAM}-[0-9]+" | sort -t'-' -k2 -n || true)

  if [ -z "$IDS" ]; then
    echo "  (no issues)"
    continue
  fi

  for issue_id in $IDS; do
    TOTAL=$((TOTAL + 1))

    # Skip if already migrated
    if migrated_ids | grep -q "^${issue_id}$"; then
      echo "  ⏭  $issue_id — already migrated"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Fetch full details
    DETAIL=$(bash "$TRACKER" view "$issue_id" 2>/dev/null | $STRIP_ANSI || true)
    TITLE=$(echo "$DETAIL" | head -1 | sed "s/^# *${issue_id}: *//" | sed 's/[[:space:]]*$//')
    [ -z "$TITLE" ] && TITLE="$issue_id (untitled)"

    # Parse metadata
    PRIORITY=$(parse_priority "$DETAIL")
    PRIO_LABEL=$(priority_to_label "$PRIORITY")
    STATE_LABEL=$(state_to_label "$state")
    CATEGORY_LABELS=$(parse_labels "$DETAIL")

    # Build label list
    LABELS="$PRIO_LABEL"
    [ -n "$STATE_LABEL" ] && LABELS="$LABELS,$STATE_LABEL"
    for cat_label in $CATEGORY_LABELS; do
      # Only add labels that exist on GitHub
      if gh label list --json name -q '.[].name' 2>/dev/null | grep -qx "$cat_label"; then
        LABELS="$LABELS,$cat_label"
      fi
    done
    # Remove leading/trailing commas
    LABELS=$(echo "$LABELS" | sed 's/^,//;s/,$//')

    # Build body
    DESC=$(parse_description "$DETAIL")
    BODY="> Migrated from Linear issue ${issue_id} on ${DATE}

${DESC}"

    echo "  📋 $issue_id: $TITLE"
    echo "     State: $state | Priority: P$PRIORITY | Labels: $LABELS"

    if [ "$DRY_RUN" = "--dry-run" ]; then
      continue
    fi

    # Create GitHub issue
    GH_URL=$(gh issue create \
      --repo "$GITHUB_REPO" \
      --title "$TITLE" \
      --body "$BODY" \
      --label "$LABELS" \
      2>&1) || { echo "     ❌ Failed to create: $GH_URL"; continue; }

    # Extract issue number from URL
    GH_NUMBER=$(echo "$GH_URL" | grep -oE '[0-9]+$')

    if [ -z "$GH_NUMBER" ]; then
      echo "     ❌ Could not parse issue number from: $GH_URL"
      continue
    fi

    echo "     ✅ Created #$GH_NUMBER"

    # Migrate comments
    COMMENTS=$(bash "$TRACKER" comment-list "$issue_id" 2>/dev/null | $STRIP_ANSI || true)
    if [ -n "$COMMENTS" ] && ! echo "$COMMENTS" | grep -q "No comments"; then
      # Parse comment blocks — Linear CLI separates with "---" or similar
      COMMENT_COUNT=0
      COMMENT_BODY=""
      while IFS= read -r line; do
        if echo "$line" | grep -qE '^\*\*@|^- \*\*@'; then
          # New comment starts — flush previous
          if [ -n "$COMMENT_BODY" ]; then
            gh issue comment "$GH_NUMBER" --repo "$GITHUB_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1
            COMMENT_COUNT=$((COMMENT_COUNT + 1))
          fi
          COMMENT_BODY="> $line"
        else
          COMMENT_BODY="$COMMENT_BODY
$line"
        fi
      done <<< "$COMMENTS"
      # Flush last comment
      if [ -n "$COMMENT_BODY" ]; then
        gh issue comment "$GH_NUMBER" --repo "$GITHUB_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1
        COMMENT_COUNT=$((COMMENT_COUNT + 1))
      fi
      [ "$COMMENT_COUNT" -gt 0 ] && echo "     💬 Migrated $COMMENT_COUNT comment(s)"
    fi

    # Close if completed or canceled
    if [ "$state" = "completed" ]; then
      gh issue close "$GH_NUMBER" --repo "$GITHUB_REPO" --reason completed >/dev/null 2>&1
      echo "     ✓ Closed (completed)"
    elif [ "$state" = "canceled" ]; then
      gh issue close "$GH_NUMBER" --repo "$GITHUB_REPO" --reason "not planned" >/dev/null 2>&1
      echo "     ✓ Closed (canceled)"
    fi

    # Record mapping
    echo "${issue_id},${GH_NUMBER}" >> "$MAPPING_FILE"
    CREATED=$((CREATED + 1))

    # Small delay to avoid rate limits
    sleep 0.5
  done
done

echo ""
echo "=== Migration Complete ==="
echo "    Total issues: $TOTAL"
echo "    Created: $CREATED"
echo "    Skipped: $SKIPPED"
echo "    Mapping: $MAPPING_FILE"
