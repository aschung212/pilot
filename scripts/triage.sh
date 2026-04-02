#!/bin/bash
# Issue Triage Agent — AI reviews backlog issues before the overnight builder picks them up.
# Runs between discovery and builder in the overnight chain.
#
# For each unreviewed issue:
#   1. Gathers context (description, codebase state, product decisions, related issues)
#   2. AI reviews and outputs: APPROVE / ENHANCE / SKIP / FLAG
#   3. Approved/Enhanced issues get implementation guidance added as comments
#   4. Flagged issues are marked for manual review
#   5. Issues get labeled as triaged so they're not re-reviewed
#
# Usage:
#   ./triage.sh              # triage all unreviewed backlog issues
#   ./triage.sh --dry-run    # preview without updating tracker

set -uo pipefail
# Note: not using -e (errexit) because individual issue failures should not abort the loop

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="triage"

REPO="${REPO_PATH:-/Users/aaron/development/lift}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
TRIAGE_LOG="$OUTPUT_DIR/lift-triage-$DATE.md"
DRY_RUN="${1:-}"

mkdir -p "$OUTPUT_DIR"

echo "🔍 Triage Agent — $DATE" | tee "$TRIAGE_LOG"

# Start Slack thread for this triage session
THREAD_TS=$(bash "$NOTIFY" thread-start automation "🔍 *Triage — $DATE*")
THREAD_TS=$(echo "$THREAD_TS" | tr -d ' \n')

# Load product decisions for context
DECISIONS_FILE="${PRODUCT_DECISIONS_FILE:-}"
PRODUCT_DECISIONS=$(cat "$DECISIONS_FILE" 2>/dev/null || echo "No product decisions file found")

# Get all backlog/unstarted issues
ALL_ISSUES=$(bash "$TRACKER" list backlog unstarted)
ISSUE_IDS=$(echo "$ALL_ISSUES" | grep -oE "${LINEAR_TEAM}-[0-9]+" || true)

if [ -z "$ISSUE_IDS" ]; then
  echo "  No issues to triage." | tee -a "$TRIAGE_LOG"
  exit 0
fi

# Check which issues have already been triaged (have a "Triaged by" comment)
UNTRIAGED_IDS=""
for issue_id in $ISSUE_IDS; do
  COMMENTS=$(bash "$TRACKER" comment-list "$issue_id" || true)
  if ! echo "$COMMENTS" | grep -q "Triaged by\|Re-triaged by"; then
    UNTRIAGED_IDS+="$issue_id "
  fi
done
UNTRIAGED_IDS=$(echo "$UNTRIAGED_IDS" | xargs)

if [ -z "$UNTRIAGED_IDS" ]; then
  echo "  All issues already triaged." | tee -a "$TRIAGE_LOG"
  exit 0
fi

UNTRIAGED_COUNT=$(echo "$UNTRIAGED_IDS" | wc -w | tr -d ' ')
MAX_PER_RUN=10
echo "  Found $UNTRIAGED_COUNT untriaged issues (processing up to $MAX_PER_RUN)." | tee -a "$TRIAGE_LOG"
# Cap to avoid blocking the builder — remaining issues get triaged next run
UNTRIAGED_IDS=$(echo "$UNTRIAGED_IDS" | tr ' ' '\n' | head -"$MAX_PER_RUN" | xargs)

cd "$REPO"

# Process each untriaged issue
APPROVED=0
ENHANCED=0
SKIPPED=0
FLAGGED=0
RESULTS=""

for issue_id in $UNTRIAGED_IDS; do
  echo "" | tee -a "$TRIAGE_LOG"
  echo "  ── $issue_id ──" | tee -a "$TRIAGE_LOG"

  # Get full issue details
  ISSUE_DETAIL=$(bash "$TRACKER" view "$issue_id" || echo "Could not fetch issue")
  ISSUE_TITLE=$(echo "$ISSUE_DETAIL" | head -1 | sed "s/^# *${LINEAR_TEAM}-[0-9]*: *//" || echo "$issue_id")
  [ -z "$ISSUE_TITLE" ] && ISSUE_TITLE="$issue_id"

  # Load triage learnings (self-improving context from past corrections)
  TRIAGE_LEARNINGS=$(cat "$OUTPUT_DIR/lift-triage-learnings.md" 2>/dev/null | head -40 | tr '\n' ' ' || echo "No learnings yet.")

  # Build a concise triage prompt — keep under shell arg limits
  TRIAGE_PROMPT="Triage this issue for a Vue 3 + TypeScript workout tracker PWA. Product direction: performance/polish over new features, accessibility/WCAG, PWA best practices, iOS-native feel, data visualization. Rejected: workout templates/saved routines.

CRITICAL RULES FROM PAST CORRECTIONS: $TRIAGE_LEARNINGS

Issue: $ISSUE_TITLE
Details: $(echo "$ISSUE_DETAIL" | head -20 | tr '\n' ' ')

Output EXACTLY this format:
VERDICT: APPROVE or ENHANCE or SKIP or FLAG
CONFIDENCE: 1-10
REASON: 1-2 sentences
IMPLEMENTATION_PLAN: (if APPROVE/ENHANCE) 3 bullet points with specific files and changes
COMPLEXITY: small/medium/large
SUGGESTED_PRIORITY: 1-4"

  # Run Gemini Flash, fall back to Claude Sonnet if Gemini fails
  TRIAGE_MODEL="gemini-2.5-flash"
  TRIAGE_RESULT=$(gemini -p "$TRIAGE_PROMPT" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt" || true)

  # Validate we got a real verdict, not an error
  if ! echo "$TRIAGE_RESULT" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG)'; then
    echo "    (Gemini failed, falling back to Claude Sonnet)" | tee -a "$TRIAGE_LOG"
    TRIAGE_MODEL="claude-sonnet"
    TRIAGE_RESULT=$(claude --dangerously-skip-permissions --model sonnet -p "$TRIAGE_PROMPT" --max-turns 3 2>&1 || true)
  fi

  # Parse verdict
  VERDICT=$(echo "$TRIAGE_RESULT" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG)' | head -1 | sed 's/VERDICT: //')
  VERDICT=${VERDICT:-FLAG}

  echo "  $VERDICT: $ISSUE_TITLE" | tee -a "$TRIAGE_LOG"
  echo "$TRIAGE_RESULT" >> "$TRIAGE_LOG"

  if [ "$DRY_RUN" = "--dry-run" ]; then
    continue
  fi

  ISSUE_URL=$(bash "$TRACKER" issue-url "$issue_id")

  case "$VERDICT" in
    APPROVE)
      APPROVED=$((APPROVED + 1))
      IMPL_PLAN=$(echo "$TRIAGE_RESULT" | sed -n '/IMPLEMENTATION_PLAN:/,/COMPLEXITY:\|SUGGESTED_PRIORITY:\|$/p' | head -10)
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — ✅ APPROVED

$IMPL_PLAN

---
_Automated triage — suggested starting point, not a mandate. Read the codebase and deviate if you find a better approach._" || true
      bash "$TRACKER" update "$issue_id" --state unstarted || true
      RESULTS+="  • ✅ <${ISSUE_URL}|${issue_id}>: $ISSUE_TITLE\n"
      ;;
    ENHANCE)
      ENHANCED=$((ENHANCED + 1))
      ENHANCED_DESC=$(echo "$TRIAGE_RESULT" | sed -n '/ENHANCED_DESCRIPTION:/,/IMPLEMENTATION_PLAN:\|$/p' | head -5 | sed 's/ENHANCED_DESCRIPTION: //')
      IMPL_PLAN=$(echo "$TRIAGE_RESULT" | sed -n '/IMPLEMENTATION_PLAN:/,/COMPLEXITY:\|SUGGESTED_PRIORITY:\|$/p' | head -10)
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — ✨ ENHANCED

**Refined scope:**
$ENHANCED_DESC

$IMPL_PLAN

---
_Automated triage — suggested starting point, not a mandate. Read the codebase and deviate if you find a better approach._" || true
      SUGGESTED_P=$(echo "$TRIAGE_RESULT" | grep -oE 'SUGGESTED_PRIORITY: [1-4]' | grep -oE '[1-4]' || true)
      if [ -n "$SUGGESTED_P" ]; then
        bash "$TRACKER" update "$issue_id" --priority "$SUGGESTED_P" || true
      fi
      bash "$TRACKER" update "$issue_id" --state unstarted || true
      RESULTS+="  • ✨ <${ISSUE_URL}|${issue_id}>: $ISSUE_TITLE (enhanced)\n"
      ;;
    SKIP)
      SKIPPED=$((SKIPPED + 1))
      REASON=$(echo "$TRIAGE_RESULT" | grep -oE 'REASON: .*' | head -1 | sed 's/REASON: //')
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — ⏭️ SKIP

$REASON

---
_Automated triage — can be overridden by moving to Unstarted._" || true
      bash "$TRACKER" update "$issue_id" --priority 4 || true
      RESULTS+="  • ⏭️ <${ISSUE_URL}|${issue_id}>: $ISSUE_TITLE (skip)\n"
      ;;
    FLAG)
      FLAGGED=$((FLAGGED + 1))
      REASON=$(echo "$TRIAGE_RESULT" | grep -oE 'REASON: .*' | head -1 | sed 's/REASON: //')
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — 🚩 NEEDS INPUT

$REASON

---
_Automated triage — this issue needs a human decision before the builder can proceed._" || true
      RESULTS+="  • 🚩 <${ISSUE_URL}|${issue_id}>: $ISSUE_TITLE (needs input)\n"
      ;;
  esac
done

echo "" | tee -a "$TRIAGE_LOG"
echo "━━━ Triage Complete ━━━" | tee -a "$TRIAGE_LOG"
echo "Approved: $APPROVED | Enhanced: $ENHANCED | Skipped: $SKIPPED | Flagged: $FLAGGED" | tee -a "$TRIAGE_LOG"

# Triage metrics CSV
TRIAGE_METRICS_CSV="$OUTPUT_DIR/lift-triage-metrics.csv"
if [ ! -f "$TRIAGE_METRICS_CSV" ]; then
  echo "date,total,approved,enhanced,skipped,flagged,model" > "$TRIAGE_METRICS_CSV"
fi
if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$UNTRIAGED_COUNT,$APPROVED,$ENHANCED,$SKIPPED,$FLAGGED,$TRIAGE_MODEL" >> "$TRIAGE_METRICS_CSV"
fi
log_info "Triage complete: $APPROVED approved, $ENHANCED enhanced, $SKIPPED skipped, $FLAGGED flagged"

# Slack notification
if [ "$DRY_RUN" != "--dry-run" ]; then
  bash "$NOTIFY" thread-reply automation "$THREAD_TS" "*Triage complete* — $UNTRIAGED_COUNT issues reviewed
✅ $APPROVED approved | ✨ $ENHANCED enhanced | ⏭️ $SKIPPED skipped | 🚩 $FLAGGED flagged
$(echo -e "$RESULTS")"
fi

echo ""
echo "📊 Triage log: $TRIAGE_LOG"
