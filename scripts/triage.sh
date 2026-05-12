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
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
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

# Get every issue in scope for triage. "triageable" is exclusion-based:
# every open issue that is NOT in {state:started, state:blocked, state:canceled}.
# This includes state:triage, state:backlog, state:unstarted, AND issues with
# no state:* label at all (manual issues Aaron creates without labels, plus
# any legacy issue from before the labeling convention). Was previously
# `list backlog unstarted` (inclusion-based), which silently skipped every
# unlabeled issue — #216, #358, #434 sat untriaged for weeks because of this.
# tracker.sh's gh_list "triageable" implements the underlying jq exclusion.
ALL_ISSUES=$(bash "$TRACKER" list triageable)
ISSUE_IDS=$(echo "$ALL_ISSUES" | grep -oE "${ISSUE_PREFIX}-[0-9]+" || true)

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
echo "  Found $UNTRIAGED_COUNT untriaged issues — processing all." | tee -a "$TRIAGE_LOG"

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
  ISSUE_TITLE=$(echo "$ISSUE_DETAIL" | head -1 | sed "s/^# *${ISSUE_PREFIX}-[0-9]*: *//" || echo "$issue_id")
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

FLAG only when the issue has a genuine product/UX decision that requires Aaron's judgment — competing reasonable approaches with different tradeoffs, an unclear product intent, a missing requirement only Aaron can supply. Do NOT FLAG just because implementation details are fuzzy: if you can pick a sensible default, use ENHANCE instead and document the assumption. A blank \"NEEDS INPUT\" comment with no analysis is useless — every FLAG must include 2-4 concrete options with pros, cons, and your recommendation so Aaron can decide in 30 seconds.

Output EXACTLY this format:
VERDICT: APPROVE or ENHANCE or SKIP or FLAG or RESCOPE
CONFIDENCE: 1-10
REASON: 1-2 sentences
IMPLEMENTATION_PLAN: (if APPROVE/ENHANCE) 3 bullet points with specific files and changes
COMPLEXITY: small/medium/large
SUGGESTED_PRIORITY: 1-4

If FLAG, also output (mandatory — do not emit FLAG without these fields):
FLAG_QUESTION: 1-2 sentences naming the specific decision needed. Be concrete (e.g. \"Should the negative-delta indicator stay red, or use a neutral icon+color combo so it works without color?\"), not generic (\"unclear scope\").
OPTION_1_TITLE: short label for the option
OPTION_1_PROS: 1-3 pros separated by \" | \"
OPTION_1_CONS: 1-3 cons separated by \" | \"
OPTION_2_TITLE: short label
OPTION_2_PROS: pros separated by \" | \"
OPTION_2_CONS: cons separated by \" | \"
(repeat OPTION_3 / OPTION_4 if useful — provide AT LEAST 2 options, no more than 4)
RECOMMENDATION: name the recommended option and 1-2 sentences justifying the call

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
    # Triage only needs read access — no writes, no shell beyond git log
    TRIAGE_ALLOWED_TOOLS="Read,Glob,Grep,Bash(git log:*),Bash(git diff:*),Bash(ls:*),Bash(cat:*)"
    TRIAGE_RESULT=$(claude --allowedTools "$TRIAGE_ALLOWED_TOOLS" --model sonnet -p "$TRIAGE_PROMPT" --max-turns 3 2>&1 || true)
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
      FLAG_QUESTION=$(echo "$TRIAGE_RESULT" | grep -oE 'FLAG_QUESTION: .*' | head -1 | sed 's/FLAG_QUESTION: //')
      RECOMMENDATION=$(echo "$TRIAGE_RESULT" | grep -oE 'RECOMMENDATION: .*' | head -1 | sed 's/RECOMMENDATION: //')

      # Build options section from OPTION_1..OPTION_4 fields. Each option must
      # have a title; pros/cons are split on " | " into a bulleted list. If the
      # model omits the structured fields (older prompts, model regression),
      # fall back to a plain REASON line so the comment is still informative.
      OPTIONS_BLOCK=""
      OPTION_COUNT=0
      for i in 1 2 3 4; do
        O_TITLE=$(echo "$TRIAGE_RESULT" | grep -oE "OPTION_${i}_TITLE: .*" | head -1 | sed "s/OPTION_${i}_TITLE: //")
        [ -z "$O_TITLE" ] && continue
        OPTION_COUNT=$((OPTION_COUNT + 1))
        O_PROS=$(echo "$TRIAGE_RESULT" | grep -oE "OPTION_${i}_PROS: .*" | head -1 | sed "s/OPTION_${i}_PROS: //")
        O_CONS=$(echo "$TRIAGE_RESULT" | grep -oE "OPTION_${i}_CONS: .*" | head -1 | sed "s/OPTION_${i}_CONS: //")
        PROS_BULLETS=$(echo "$O_PROS" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/  - /')
        CONS_BULLETS=$(echo "$O_CONS" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/  - /')
        [ -z "$PROS_BULLETS" ] && PROS_BULLETS="  - (none provided)"
        [ -z "$CONS_BULLETS" ] && CONS_BULLETS="  - (none provided)"
        OPTIONS_BLOCK+="**Option ${i}: ${O_TITLE}**
Pros:
${PROS_BULLETS}
Cons:
${CONS_BULLETS}

"
      done

      if [ "$OPTION_COUNT" -eq 0 ]; then
        # Model didn't emit structured options — surface the bare reason so
        # Aaron at least sees something, and log the regression so we notice.
        echo "    ⚠️  FLAG verdict but no OPTION_N fields parsed — falling back to bare REASON." | tee -a "$TRIAGE_LOG"
        OPTIONS_BLOCK="_Triage did not emit structured options. Raw reason: ${REASON:-(empty)}_"
      fi

      bash "$TRACKER" comment-add "$issue_id" "**Triaged by $TRIAGE_MODEL** ($DATE) — 🚩 NEEDS INPUT

**Question:** ${FLAG_QUESTION:-${REASON:-No question summary provided.}}

${OPTIONS_BLOCK}**Recommendation:** ${RECOMMENDATION:-No recommendation provided.}

---
_Automated triage — this issue needs a human decision before the builder can proceed. Resolve by editing the issue with your answer, then flip \`state:needs-input\` → \`state:unstarted\` to release it into the picking pool._" || true
      # Park the issue on state:needs-input so list pickable / list triageable
      # both skip it. Aaron flips it back to state:unstarted once he answers.
      bash "$TRACKER" update "$issue_id" --state needs-input || true
      RESULTS+="  • 🚩 <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} — _${FLAG_QUESTION:-${REASON:-needs human decision}}_\n"
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
        SUB_ID=$(echo "$CREATE_OUTPUT" | grep -oE "${ISSUE_PREFIX}-[0-9]+" | head -1)

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
<$(bash "$TRACKER" board-url)|Issue Board>"
fi

echo ""
echo "📊 Triage log: $TRIAGE_LOG"
