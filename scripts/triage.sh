#!/bin/bash
# Issue Triage Agent — AI reviews backlog issues before the overnight builder picks them up.
# Runs between discovery and builder in the overnight chain.
#
# For each unreviewed issue:
#   1. Gathers context (description, codebase state, product decisions, related issues)
#   2. AI reviews and outputs: APPROVE / ENHANCE / SKIP / FLAG / RESCOPE
#   3. Approved/Enhanced issues get implementation guidance added as comments
#   4. Flagged issues are marked for manual review
#   5. Rescoped issues are split into sub-issues, original is canceled
#   6. Issues get labeled as triaged so they're not re-reviewed
#
# Usage:
#   ./triage.sh              # triage all unreviewed backlog issues
#   ./triage.sh --dry-run    # preview without updating tracker

set -uo pipefail
# Note: not using -e (errexit) because individual issue failures should not abort the loop

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="triage"

REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
TRIAGE_LOG="$OUTPUT_DIR/lift-triage-$DATE.md"
DRY_RUN="${1:-}"

mkdir -p "$OUTPUT_DIR"

echo "🚥 Triage Agent — $DATE" | tee "$TRIAGE_LOG"

# Start Slack thread for this triage session
THREAD_TS=$(bash "$NOTIFY" --as triage thread-start automation "🚥 *Triage — $DATE*")
THREAD_TS=$(echo "$THREAD_TS" | tr -d ' \n')

# Load product decisions for context
DECISIONS_FILE="${PRODUCT_DECISIONS_FILE:-}"
[ -n "$DECISIONS_FILE" ] && [ ! -f "$DECISIONS_FILE" ] && echo "  ⚠️ Product decisions file not found: $DECISIONS_FILE" >&2
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
RESCOPED=0
RESULTS=""

# Check backlog size — if backlog is large, bias toward ENHANCE over RESCOPE
BACKLOG_COUNT=$(echo "$ISSUE_IDS" | wc -w | tr -d ' ')
if [ "$BACKLOG_COUNT" -gt 20 ]; then
  RESCOPE_GUIDANCE="The backlog already has $BACKLOG_COUNT issues. Prefer ENHANCE (tighten scope) over RESCOPE (split) unless the issue truly contains unrelated deliverables. Note in the comment if splitting would help later."
else
  RESCOPE_GUIDANCE="RESCOPE is available if the issue bundles distinct, unrelated deliverables."
fi

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
  TRIAGE_PROMPT="Triage this issue for $PROJECT_NAME ($TECH_STACK).

$PRODUCT_DECISIONS

CRITICAL RULES FROM PAST CORRECTIONS: $TRIAGE_LEARNINGS

Issue: $ISSUE_TITLE
Details: $(echo "$ISSUE_DETAIL" | head -20 | tr '\n' ' ')

$RESCOPE_GUIDANCE

The builder agent (Claude Opus) is highly capable — it handles complex, multi-file changes across the codebase in a single iteration. Do NOT rescope an issue just because it is large or touches many files. Only RESCOPE when an issue bundles genuinely unrelated deliverables that have no dependency on each other (e.g. 'redesign the settings page AND add export functionality' — those are two separate features).

Output EXACTLY this format:
VERDICT: APPROVE or ENHANCE or SKIP or FLAG or RESCOPE
CONFIDENCE: 1-10
REASON: 1-2 sentences
IMPLEMENTATION_PLAN: (if APPROVE/ENHANCE) 3 bullet points with specific files and changes
COMPLEXITY: small/medium/large
SUGGESTED_PRIORITY: 1-4

If RESCOPE, also output (2-4 sub-issues, no more):
SUB_ISSUE_1_TITLE: concise title
SUB_ISSUE_1_PRIORITY: 1-4
SUB_ISSUE_1_DESCRIPTION: 2-3 sentences with specific files and changes
SUB_ISSUE_2_TITLE: ...
SUB_ISSUE_2_PRIORITY: ...
SUB_ISSUE_2_DESCRIPTION: ...
(repeat for each sub-issue, max 4)"

  # Run Gemini Flash, fall back to Claude Sonnet if Gemini fails
  TRIAGE_MODEL="gemini-2.5-flash"
  TRIAGE_RESULT=$(gemini -p "$TRIAGE_PROMPT" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt" || true)

  # Validate we got a real verdict, not an error
  if ! echo "$TRIAGE_RESULT" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'; then
    echo "    (Gemini failed, falling back to Claude Sonnet)" | tee -a "$TRIAGE_LOG"
    TRIAGE_MODEL="claude-sonnet"
    TRIAGE_RESULT=$(claude --dangerously-skip-permissions --model sonnet -p "$TRIAGE_PROMPT" --max-turns 3 2>&1 || true)
  fi

  # Parse verdict
  VERDICT=$(echo "$TRIAGE_RESULT" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)' | head -1 | sed 's/VERDICT: //')
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
      CONFIDENCE=$(echo "$TRIAGE_RESULT" | grep -oE 'CONFIDENCE: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "?")
      COMPLEXITY=$(echo "$TRIAGE_RESULT" | grep -oE 'COMPLEXITY: [a-z]+' | head -1 | sed 's/COMPLEXITY: //' || echo "?")
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — ✅ APPROVED

$IMPL_PLAN

---
_Automated triage — suggested starting point, not a mandate. Read the codebase and deviate if you find a better approach._" || true
      bash "$TRACKER" update "$issue_id" --state unstarted || true
      RESULTS+="  • ✅ <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} _(${COMPLEXITY}, confidence ${CONFIDENCE}/10)_\n"
      ;;
    ENHANCE)
      ENHANCED=$((ENHANCED + 1))
      ENHANCED_DESC=$(echo "$TRIAGE_RESULT" | sed -n '/ENHANCED_DESCRIPTION:/,/IMPLEMENTATION_PLAN:\|$/p' | head -5 | sed 's/ENHANCED_DESCRIPTION: //')
      IMPL_PLAN=$(echo "$TRIAGE_RESULT" | sed -n '/IMPLEMENTATION_PLAN:/,/COMPLEXITY:\|SUGGESTED_PRIORITY:\|$/p' | head -10)
      CONFIDENCE=$(echo "$TRIAGE_RESULT" | grep -oE 'CONFIDENCE: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "?")
      COMPLEXITY=$(echo "$TRIAGE_RESULT" | grep -oE 'COMPLEXITY: [a-z]+' | head -1 | sed 's/COMPLEXITY: //' || echo "?")
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
      RESULTS+="  • ✨ <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} _(enhanced → ${COMPLEXITY}, confidence ${CONFIDENCE}/10)_\n"
      ;;
    SKIP)
      SKIPPED=$((SKIPPED + 1))
      REASON=$(echo "$TRIAGE_RESULT" | grep -oE 'REASON: .*' | head -1 | sed 's/REASON: //')
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — ⏭️ SKIP

$REASON

---
_Automated triage — can be overridden by moving to Unstarted._" || true
      bash "$TRACKER" update "$issue_id" --priority 4 || true
      RESULTS+="  • ⏭️ <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} — _${REASON:-no reason}_\n"
      ;;
    FLAG)
      FLAGGED=$((FLAGGED + 1))
      REASON=$(echo "$TRIAGE_RESULT" | grep -oE 'REASON: .*' | head -1 | sed 's/REASON: //')
      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — 🚩 NEEDS INPUT

$REASON

---
_Automated triage — this issue needs a human decision before the builder can proceed._" || true
      RESULTS+="  • 🚩 <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} — _${REASON:-needs human decision}_\n"
      ;;
    RESCOPE)
      RESCOPED=$((RESCOPED + 1))
      REASON=$(echo "$TRIAGE_RESULT" | grep -oE 'REASON: .*' | head -1 | sed 's/REASON: //')

      # Parse and create sub-issues (max 4)
      SUB_ISSUE_LINKS=""
      SUB_ISSUE_COUNT=0
      for i in 1 2 3 4; do
        SUB_TITLE=$(echo "$TRIAGE_RESULT" | grep -oE "SUB_ISSUE_${i}_TITLE: .*" | head -1 | sed "s/SUB_ISSUE_${i}_TITLE: //")
        SUB_PRIORITY=$(echo "$TRIAGE_RESULT" | grep -oE "SUB_ISSUE_${i}_PRIORITY: [1-4]" | head -1 | grep -oE '[1-4]')
        SUB_DESC=$(echo "$TRIAGE_RESULT" | grep -oE "SUB_ISSUE_${i}_DESCRIPTION: .*" | head -1 | sed "s/SUB_ISSUE_${i}_DESCRIPTION: //")
        [ -z "$SUB_TITLE" ] && continue

        SUB_PRIORITY=${SUB_PRIORITY:-3}
        SUB_DESC="${SUB_DESC:-(no description)} (Split from ${issue_id}: ${ISSUE_TITLE})"

        CREATE_OUTPUT=$(bash "$TRACKER" create "$SUB_TITLE" "$SUB_PRIORITY" --state unstarted --description "$SUB_DESC" || echo "FAILED")
        SUB_ID=$(echo "$CREATE_OUTPUT" | grep -oE "${LINEAR_TEAM}-[0-9]+" | head -1)

        if [ -n "$SUB_ID" ]; then
          SUB_ISSUE_COUNT=$((SUB_ISSUE_COUNT + 1))
          SUB_URL=$(bash "$TRACKER" issue-url "$SUB_ID" 2>/dev/null || echo "")
          SUB_ISSUE_LINKS+="  - ${SUB_ID}: ${SUB_TITLE}\n"
          # Mark sub-issue as triaged so it doesn't get re-triaged
          bash "$TRACKER" comment-add "$SUB_ID" "**Triaged by $TRIAGE_MODEL** ($DATE) — ✅ APPROVED (split from ${issue_id})

**Context:** This was split from ${issue_id} (${ISSUE_TITLE}) because the original issue bundled unrelated deliverables.

**Scope:** ${SUB_DESC}

---
_Automated triage — suggested starting point, not a mandate._" || true
          echo "    Created $SUB_ID: $SUB_TITLE" | tee -a "$TRIAGE_LOG"
        else
          echo "    ⚠️  Failed to create sub-issue: $SUB_TITLE" | tee -a "$TRIAGE_LOG"
        fi
      done

      if [ "$SUB_ISSUE_COUNT" -gt 0 ]; then
        # Comment on original with links to children, then cancel it
        bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — 🔀 RESCOPED

$REASON

**Split into $SUB_ISSUE_COUNT issues:**
$(echo -e "$SUB_ISSUE_LINKS")
---
_Original issue canceled — work continues in the sub-issues above._" || true
        bash "$TRACKER" update "$issue_id" --state canceled || true
        RESULTS+="  • 🔀 <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} → split into ${SUB_ISSUE_COUNT} issues\n"
      else
        # All sub-issue creation failed — flag for manual review instead
        FLAGGED=$((FLAGGED + 1))
        RESCOPED=$((RESCOPED - 1))
        bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — 🚩 RESCOPE FAILED

Attempted to split this issue but sub-issue creation failed. Needs manual rescoping.

$REASON" || true
        RESULTS+="  • 🚩 <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} — _rescope failed, needs manual split_\n"
      fi
      ;;
  esac
done

echo "" | tee -a "$TRIAGE_LOG"
echo "━━━ Triage Complete ━━━" | tee -a "$TRIAGE_LOG"
echo "Approved: $APPROVED | Enhanced: $ENHANCED | Rescoped: $RESCOPED | Skipped: $SKIPPED | Flagged: $FLAGGED" | tee -a "$TRIAGE_LOG"

# Triage metrics CSV
TRIAGE_METRICS_CSV="$OUTPUT_DIR/lift-triage-metrics.csv"
if [ ! -f "$TRIAGE_METRICS_CSV" ]; then
  echo "date,total,approved,enhanced,rescoped,skipped,flagged,model" > "$TRIAGE_METRICS_CSV"
fi
if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$UNTRIAGED_COUNT,$APPROVED,$ENHANCED,$RESCOPED,$SKIPPED,$FLAGGED,$TRIAGE_MODEL" >> "$TRIAGE_METRICS_CSV"
fi
log_info "Triage complete: $APPROVED approved, $ENHANCED enhanced, $RESCOPED rescoped, $SKIPPED skipped, $FLAGGED flagged"

# Slack notification
if [ "$DRY_RUN" != "--dry-run" ]; then
  bash "$NOTIFY" --as triage thread-reply automation "$THREAD_TS" "*Triage complete* — $UNTRIAGED_COUNT issues reviewed (model: $TRIAGE_MODEL)
✅ $APPROVED approved | ✨ $ENHANCED enhanced | 🔀 $RESCOPED rescoped | ⏭️ $SKIPPED skipped | 🚩 $FLAGGED flagged

$(echo -e "$RESULTS")
<https://linear.app/${LINEAR_ORG}|Linear Board>"
fi

echo ""
echo "📊 Triage log: $TRIAGE_LOG"
