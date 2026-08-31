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
# If the model returns no parseable verdict (API error, turn-limit cutoff), the
# issue is DEFERRED: left completely untouched, so it carries no "Triaged by"
# comment and the next run picks it up again. A model failure must never be
# recorded as a FLAG — see the comment above the verdict parse for why.
#
# Usage:
#   ./triage.sh              # triage all unreviewed backlog issues
#   ./triage.sh --dry-run    # preview without updating tracker
#   ./triage.sh --re-triage  # one-shot sweep: re-review ALL triageable issues,
#                            # including already-triaged ones (used to re-baseline
#                            # the backlog when triage policy changes, e.g. the
#                            # 2026-08-21 GA-readiness shift). Combinable with
#                            # --dry-run. Parked issues (needs-input/blocked/
#                            # started) stay untouched.

set -uo pipefail
# Note: not using -e (errexit) because individual issue failures should not abort the loop

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
AI_RESEARCH="$SCRIPT_DIR/../adapters/ai-research.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="triage"

REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
TRIAGE_LOG="$OUTPUT_DIR/lift-triage-$DATE.md"

DRY_RUN=""
RETRIAGE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN="--dry-run" ;;
    --re-triage) RETRIAGE="1" ;;
    *) echo "Unknown argument: $arg (valid: --dry-run, --re-triage)" >&2; exit 1 ;;
  esac
done

# Comment marker. "Re-triaged by" both records the sweep and satisfies the
# idempotency grep below, so re-triaged issues are not re-reviewed nightly.
TRIAGE_MARKER="Triaged by"
[ -n "$RETRIAGE" ] && TRIAGE_MARKER="Re-triaged by"

mkdir -p "$OUTPUT_DIR"

echo "🚥 Triage Agent — $DATE${RETRIAGE:+ (re-triage sweep)}" | tee "$TRIAGE_LOG"

# Start Slack thread for this triage session
THREAD_TS=$(bash "$NOTIFY" --as triage thread-start automation "🚥 *Triage — $DATE*${RETRIAGE:+ — GA re-triage sweep}")
THREAD_TS=$(echo "$THREAD_TS" | tr -d ' \n')

# Load product decisions for context
DECISIONS_FILE="${PRODUCT_DECISIONS_FILE:-}"
[ -n "$DECISIONS_FILE" ] && [ ! -f "$DECISIONS_FILE" ] && echo "  ⚠️ Product decisions file not found: $DECISIONS_FILE" >&2
PRODUCT_DECISIONS=$(cat "$DECISIONS_FILE" 2>/dev/null || echo "No product decisions file found")

# ── Reconcile issues whose PR was closed unmerged ────────────────────────
# Runs BEFORE the triageable query on purpose: reconcile moves rejected-PR
# issues out of state:started (which `triageable` excludes) and into
# state:triage, so anything it releases is triaged in this same run rather
# than waiting a week.
#
# This is a pre-step, not a gate — a reconcile failure must never stop triage
# from running, so its exit status is logged and swallowed.
#
# Kill switch: PR_RECONCILE_ENABLED=0 skips it entirely.
RECONCILE="$SCRIPT_DIR/pr-close-reconcile.sh"
if [ "${PR_RECONCILE_ENABLED:-1}" = "0" ]; then
  echo "  ⏭  PR-close reconcile disabled (PR_RECONCILE_ENABLED=0)" | tee -a "$TRIAGE_LOG"
elif [ ! -x "$RECONCILE" ]; then
  echo "  ⚠️  PR-close reconcile not found at $RECONCILE — skipping" | tee -a "$TRIAGE_LOG"
  log_warn "pr-close-reconcile.sh missing or not executable"
else
  # Triage's --dry-run must not let a sub-step mutate the tracker.
  RECONCILE_MODE="--apply"
  [ "$DRY_RUN" = "--dry-run" ] && RECONCILE_MODE="--dry-run"
  echo "  🔁 PR-close reconcile ($RECONCILE_MODE)..." | tee -a "$TRIAGE_LOG"
  RECONCILE_OUT=$(bash "$RECONCILE" "$RECONCILE_MODE" 2>&1) || {
    echo "  ⚠️  PR-close reconcile failed — continuing with triage" | tee -a "$TRIAGE_LOG"
    log_warn "pr-close-reconcile failed: $(echo "$RECONCILE_OUT" | tail -3 | tr '\n' ' ')"
  }
  echo "$RECONCILE_OUT" | grep -E "^(  [✖↩？]|Closed:)" | sed 's/^/    /' | tee -a "$TRIAGE_LOG" || true
fi

# ── Promote issues Aaron filed by hand ───────────────────────────────────
# Also BEFORE the triageable query, and after reconcile: an issue Aaron filed
# through the GitHub UI has no state:* label, so it is already triageable —
# but it has no priority either, and the GA-readiness policy below would SKIP
# it to priority:4-low if it proposes a feature. This pre-step stamps
# origin:aaron + priority:1-urgent first, so the GA carve-out keyed on
# origin:aaron fires during this same run.
#
# Pre-step, not a gate — a failure must never stop triage. Kill switch:
# MANUAL_CLAIM_ENABLED=0.
CLAIM_MANUAL="$SCRIPT_DIR/claim-manual-issues.sh"
if [ "${MANUAL_CLAIM_ENABLED:-1}" = "0" ]; then
  echo "  ⏭  Manual-issue claim disabled (MANUAL_CLAIM_ENABLED=0)" | tee -a "$TRIAGE_LOG"
elif [ ! -x "$CLAIM_MANUAL" ]; then
  echo "  ⚠️  Manual-issue claim not found at $CLAIM_MANUAL — skipping" | tee -a "$TRIAGE_LOG"
  log_warn "claim-manual-issues.sh missing or not executable"
else
  CLAIM_MODE="--apply"
  [ "$DRY_RUN" = "--dry-run" ] && CLAIM_MODE="--dry-run"
  echo "  🙋 Manual-issue claim ($CLAIM_MODE)..." | tee -a "$TRIAGE_LOG"
  CLAIM_OUT=$(bash "$CLAIM_MANUAL" "$CLAIM_MODE" --notify 2>&1) || {
    echo "  ⚠️  Manual-issue claim failed — continuing with triage" | tee -a "$TRIAGE_LOG"
    log_warn "claim-manual-issues failed: $(echo "$CLAIM_OUT" | tail -3 | tr '\n' ' ')"
  }
  echo "$CLAIM_OUT" | grep -E "^(  [⤴⚠]|Promoted:)" | sed 's/^/    /' | tee -a "$TRIAGE_LOG" || true
fi

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

# ── Defer issues that already have an open PR ────────────────────────────
# Triage was the only stage that never looked at pull requests. `triageable`
# is label-based and excludes only {started, blocked, needs-input, canceled},
# so an issue whose PR is open but whose state label was never flipped to
# state:started looks like untouched backlog — and a RESCOPE verdict then
# forks live, already-implemented work into brand-new issue numbers.
#
# That is exactly how LIFT-783 became LIFT-1039 on 2026-07-28. PR #1032 had
# been open against #783 for 22 hours, but #783 still read state:unstarted
# (its state flip was lost to the ISSUE_DONE marker-format bug in builder.sh).
# Triage rescoped it and canceled the parent; the builder then picked #1039 —
# a fresh number no open PR referenced, so every issue-identity-keyed dedupe
# in the pipeline passed — and shipped PR #1041, a duplicate of #1032.
#
# This is a DEFERRAL, not a skip: the issue is left completely untouched and
# returns to triage scope the moment its PR merges or closes. Nothing is
# closed, canceled, or dropped, so a false positive costs one triage cycle,
# never a lost issue. Fails open — if the `gh` call errors the list is empty
# and triage proceeds exactly as before.
IN_FLIGHT_IDS=$(gh pr list --repo "$GITHUB_ISSUES_REPO" --state open --limit 200 \
  --json title -q '.[].title' 2>/dev/null \
  | grep -oE "(${ISSUE_PREFIX}-|#)[0-9]+" \
  | sed -E "s/^#/${ISSUE_PREFIX}-/" \
  | sort -u || true)

DEFERRED_IN_FLIGHT=""
if [ -n "$IN_FLIGHT_IDS" ]; then
  _kept=""
  for issue_id in $ISSUE_IDS; do
    if echo "$IN_FLIGHT_IDS" | grep -qx "$issue_id"; then
      DEFERRED_IN_FLIGHT+="$issue_id "
    else
      _kept+="$issue_id "
    fi
  done
  if [ -n "$DEFERRED_IN_FLIGHT" ]; then
    ISSUE_IDS=$(echo "$_kept" | tr ' ' '\n' | grep -E "${ISSUE_PREFIX}-[0-9]+" || true)
    _n=$(echo "$DEFERRED_IN_FLIGHT" | wc -w | tr -d ' \n')
    echo "  🔒 Deferred $_n issue(s) with an open PR — work already in flight, not triageable this cycle:" | tee -a "$TRIAGE_LOG"
    for _d in $DEFERRED_IN_FLIGHT; do
      echo "      • $_d" | tee -a "$TRIAGE_LOG"
    done
    bash "$NOTIFY" --as triage thread-reply automation "$THREAD_TS" \
      "🔒 Deferred *$_n* issue(s) with an open PR (already in flight, not re-triaged): $(echo "$DEFERRED_IN_FLIGHT" | xargs)" >/dev/null 2>&1 || true
  fi
fi

if [ -z "$ISSUE_IDS" ]; then
  echo "  No issues to triage (all remaining have open PRs)." | tee -a "$TRIAGE_LOG"
  exit 0
fi

# Check which issues have already been triaged (have a "Triaged by" comment).
# In --re-triage mode, skip the idempotency filter: every triageable issue is
# re-reviewed under the current policy, prior verdicts notwithstanding.
if [ -n "$RETRIAGE" ]; then
  UNTRIAGED_IDS=$(echo "$ISSUE_IDS" | xargs)
else
  UNTRIAGED_IDS=""
  for issue_id in $ISSUE_IDS; do
    COMMENTS=$(bash "$TRACKER" comment-list "$issue_id" || true)
    if ! echo "$COMMENTS" | grep -q "Triaged by\|Re-triaged by"; then
      UNTRIAGED_IDS+="$issue_id "
    fi
  done
  UNTRIAGED_IDS=$(echo "$UNTRIAGED_IDS" | xargs)
fi

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
FAILED=0
FAILED_IDS=""
RESULTS=""

# A model reply counts as usable only if it carries a parseable verdict line.
# Used in three places (post-Gemini, post-retry, post-Sonnet) — keep them in
# sync by going through this one predicate.
_has_verdict() {
  echo "$1" | grep -qE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)'
}

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

  # ── GA-policy carve-out for hand-filed issues ──────────────────────────
  # Read the label off the API rather than grepping ISSUE_DETAIL: the marker
  # comment claim-manual-issues.sh leaves contains the literal string
  # "origin:aaron", so a substring match over the issue text would false-
  # positive on any issue that merely quotes it.
  _issue_num="${issue_id#${ISSUE_PREFIX}-}"
  MANUAL_FILED=""
  if gh issue view "$_issue_num" --repo "$GITHUB_ISSUES_REPO" --json labels \
       --jq '[.labels[].name] | index("origin:aaron")' 2>/dev/null | grep -qE '^[0-9]+$'; then
    MANUAL_FILED="1"
  fi

  if [ -n "$MANUAL_FILED" ]; then
    GA_CARVEOUT="
OVERRIDE — THIS ISSUE IS EXEMPT FROM THE GA-READINESS POLICY ABOVE. It carries the \`origin:aaron\` label, meaning Aaron filed it by hand rather than a Pilot agent proposing it. Standing rule (2026-08-30): if Aaron takes the time to file a ticket himself, it gets addressed ASAP. Therefore:
- You MUST NOT return SKIP on the grounds that it is a net-new feature, a new screen, a new integration, or growth/monetization work. 'Deferred until post-GA' does NOT apply to this issue.
- Treat it as APPROVE or ENHANCE. Prefer ENHANCE when the issue is loosely specified — tighten the scope and add implementation guidance rather than punting.
- Leave SUGGESTED_PRIORITY at 1. It has already been promoted to priority:1-urgent deliberately; do not lower it.
- SKIP remains valid ONLY for reasons unrelated to the GA policy — e.g. it is a true duplicate of an existing issue, or it is already implemented. Say which, explicitly.
- FLAG remains valid if there is a genuine product decision only Aaron can make, subject to the two-concrete-options rule below."
  else
    GA_CARVEOUT=""
  fi

  # Build a concise triage prompt — keep under shell arg limits
  TRIAGE_PROMPT="Triage this issue for $PROJECT_NAME ($TECH_STACK).

$PRODUCT_DECISIONS

CRITICAL RULES FROM PAST CORRECTIONS: $TRIAGE_LEARNINGS

Issue: $ISSUE_TITLE
Details: $(echo "$ISSUE_DETAIL" | head -20 | tr '\n' ' ')

GA-READINESS POLICY (in effect since 2026-08, supersedes any older triage verdict in the issue's comments): $PROJECT_NAME is feature-complete and in beta, stabilizing for a general-availability release. The pipeline now ships ONLY: bug fixes, performance improvements, UI/UX refinement of existing flows, accessibility fixes, and security fixes.
- SKIP any issue proposing a net-new feature, new screen, new integration, or monetization/growth/marketing/SEO work. In the REASON, say 'deferred until post-GA' — these are not bad ideas, just not now.
- SKIP issues that only add test coverage or tooling without fixing a user-facing defect (the suite is already extensive). Tests are welcome only inside a bug-fix issue as regression proof.
- Large refactors: APPROVE only if they directly unblock a bug, performance, or reliability fix — not for cleanliness alone.
- Bug reports, perf issues, UX polish, a11y, and security issues triage normally under the rules below.
- SUGGESTED_PRIORITY under this policy: 1=crash/data loss/security, 2=user-visible bug or significant perf problem, 3=UX friction/polish, 4=cosmetic or deferred.
$GA_CARVEOUT

$RESCOPE_GUIDANCE

The builder agent (Claude Opus) is highly capable — it handles complex, multi-file changes across the codebase in a single iteration. Do NOT rescope an issue just because it is large or touches many files. Only RESCOPE when an issue bundles genuinely unrelated deliverables that have no dependency on each other (e.g. 'redesign the settings page AND add export functionality' — those are two separate features).

FLAG only when the issue has a genuine product/UX decision that requires Aaron's judgment — competing reasonable approaches with different tradeoffs, an unclear product intent, a missing requirement only Aaron can supply. Do NOT FLAG just because implementation details are fuzzy: if you can pick a sensible default, use ENHANCE instead and document the assumption.

**FLAG is only valid if you can enumerate at least 2 concrete options with pros and cons.** If you cannot, the verdict must be ENHANCE (pick a sensible default + document the assumption) or SKIP, NEVER FLAG. A blank \"NEEDS INPUT\" comment with no analysis wastes Aaron's time — better to ship an enhanced scope he can override than to punt with no signal.

Output EXACTLY this format:
VERDICT: APPROVE or ENHANCE or SKIP or FLAG or RESCOPE
CONFIDENCE: 1-10
REASON: 1-2 sentences
IMPLEMENTATION_PLAN: (if APPROVE/ENHANCE) 3 bullet points with specific files and changes
ACCEPTANCE_CRITERIA: (if APPROVE/ENHANCE) 2-4 testable criteria separated by \" | \" — each a concrete, observable behavior a reviewer can verify on the running app (what the user sees or does), not an implementation detail. Example: \"deleting the last set removes the exercise card | the undo toast appears for 5s and restores the set when tapped\". These become the definition of done: the builder must satisfy every criterion before opening the PR.
COMPLEXITY: small/medium/large
SUGGESTED_PRIORITY: 1-4

If FLAG, you MUST emit every field below. If you cannot fill in OPTION_1 and OPTION_2 with concrete content, change the verdict to ENHANCE instead of FLAG.
FLAG_QUESTION: 1-2 sentences naming the specific decision needed. Be concrete (e.g. \"Should the negative-delta indicator stay red, or use a neutral icon+color combo so it works without color?\"), not generic (\"unclear scope\").
OPTION_1_TITLE: short label for the option
OPTION_1_PROS: 1-3 pros separated by \" | \"
OPTION_1_CONS: 1-3 cons separated by \" | \"
OPTION_2_TITLE: short label
OPTION_2_PROS: pros separated by \" | \"
OPTION_2_CONS: cons separated by \" | \"
(repeat OPTION_3 / OPTION_4 if useful — provide AT LEAST 2 options, no more than 4)
RECOMMENDATION: name the recommended option and 1-2 sentences justifying the call

Example FLAG output (follow this shape exactly when you choose FLAG):

VERDICT: FLAG
CONFIDENCE: 7
REASON: Color-only delta indicator has multiple valid a11y fixes with different UX tradeoffs.
COMPLEXITY: small
SUGGESTED_PRIORITY: 3
FLAG_QUESTION: Should the negative bodyweight delta keep red color alone, pair red with a directional icon, or switch to a monochrome treatment to satisfy WCAG 1.4.1 without losing scannability?
OPTION_1_TITLE: Icon + color (e.g. ↑/↓ next to value)
OPTION_1_PROS: works without color | matches WCAG 1.4.1 | reuses existing icon set
OPTION_1_CONS: extra DOM node | slightly noisier UI
OPTION_2_TITLE: Monochrome with subtle weight change
OPTION_2_PROS: lowest visual noise | no new asset required
OPTION_2_CONS: loses scannable signal | mild regression for sighted users
RECOMMENDATION: Option 1 — icon+color is the standard a11y pattern and Tailwind already has the chevron asset wired in.

If RESCOPE, also output (2-4 sub-issues, no more):
SUB_ISSUE_1_TITLE: concise title
SUB_ISSUE_1_PRIORITY: 1-4
SUB_ISSUE_1_DESCRIPTION: 2-3 sentences with specific files and changes
SUB_ISSUE_2_TITLE: ...
SUB_ISSUE_2_PRIORITY: ...
SUB_ISSUE_2_DESCRIPTION: ...
(repeat for each sub-issue, max 4)"

  # Run Gemini Flash via the ai-research adapter (Gemini API key; no web
  # grounding needed — triage reasons over the prompt context, not the web).
  # Fall back to Claude Sonnet if Gemini is unavailable or returns no verdict.
  TRIAGE_MODEL="gemini-2.5-flash"
  TRIAGE_RESULT=$(bash "$AI_RESEARCH" prompt "$TRIAGE_PROMPT" --no-grounding 2>>"$TRIAGE_LOG" || true)

  # Retry once before paying for the Sonnet fallback.
  #
  # Scope note: this covers genuinely transient failures only. On 2026-08-29 the
  # adapter reported HTTP 503 "currently experiencing high demand" on 7 of 23
  # issues, which reads as transient — but the cause, diagnosed 2026-08-30, was
  # the free tier's PER-MODEL daily request cap being exhausted. A retry cannot
  # clear an empty daily bucket, and it did not: every retry that day also
  # failed. That class of outage is handled by keeping AI_RESEARCH_MODEL on a
  # model with free quota (see project.env.example), and, when it happens
  # anyway, by the deferral below — which is what makes a dry bucket cost a
  # triage cycle instead of a false human gate.
  # TRIAGE_RETRY_DELAY=0 in tests so the suite does not sleep per issue.
  if ! _has_verdict "$TRIAGE_RESULT"; then
    echo "    (no verdict from Gemini — retrying once)" | tee -a "$TRIAGE_LOG"
    sleep "${TRIAGE_RETRY_DELAY:-5}"
    TRIAGE_RESULT=$(bash "$AI_RESEARCH" prompt "$TRIAGE_PROMPT" --no-grounding 2>>"$TRIAGE_LOG" || true)
  fi

  # Validate we got a real verdict, not an error
  if ! _has_verdict "$TRIAGE_RESULT"; then
    echo "    (Gemini failed, falling back to Claude Sonnet)" | tee -a "$TRIAGE_LOG"
    # FAIL LOUD once per run — if the Gemini path is down (API key / tier issue),
    # surface it instead of silently burning Claude tokens on every issue all night.
    if [ -z "${TRIAGE_GEMINI_ALERTED:-}" ]; then
      TRIAGE_GEMINI_ALERTED=1
      bash "$NOTIFY" --as triage thread-reply automation "$THREAD_TS" "⚠️ *Triage — Gemini Flash unavailable*
Falling back to Claude Sonnet for triage this run (higher token cost). Check GEMINI_API_KEY / adapters/ai-research.sh." >/dev/null 2>&1 || true
    fi
    TRIAGE_MODEL="claude-sonnet"
    # Triage only needs read access — no writes, no shell beyond git log
    TRIAGE_ALLOWED_TOOLS="Read,Glob,Grep,Bash(git log:*),Bash(git diff:*),Bash(ls:*),Bash(cat:*)"
    # max-turns 12: the FLAG verdict requires emitting FLAG_QUESTION + 2–4
    # OPTION_N blocks + RECOMMENDATION after any tool use. At max-turns 3,
    # Sonnet was spending all turns on Read/Glob/Grep and getting cut off
    # before the structured output landed — produced empty NEEDS INPUT
    # comments on LIFT-550/546/531 during the 2026-05-12 backfill rerun.
    # Raised 3→6 then, and 6→12 on 2026-08-29 after the same cutoff
    # recurred on LIFT-1223/1179/1098/1096 ("Error: Reached max turns (6)").
    # The architect-filed issues that trip this are the ones needing the most
    # codebase reading before the structured block can be written.
    TRIAGE_RESULT=$(claude --allowedTools "$TRIAGE_ALLOWED_TOOLS" --model sonnet --effort "${AI_TRIAGE_EFFORT:-high}" -p "$TRIAGE_PROMPT" --max-turns "${TRIAGE_MAX_TURNS:-12}" 2>&1 || true)
  fi

  # Parse verdict.
  #
  # An unparseable reply is a TRIAGE FAILURE, not a FLAG. This line used to read
  # `VERDICT=${VERDICT:-FLAG}`, which made a model error indistinguishable from a
  # genuine product question: the issue got a content-free "NEEDS INPUT" comment
  # ("Question: No question summary provided") and was parked on
  # state:needs-input — a label BOTH `list triageable` and `list pickable`
  # exclude. So a transient API blip silently removed the issue from the pipeline
  # until Aaron noticed and flipped the label back by hand.
  #
  # Fired in production 2026-08-29: Gemini 503'd on 7 of 23 issues, Sonnet then
  # hit `Error: Reached max turns (6)` on 4 of them, and LIFT-1223/1179/1098/1096
  # were all gated on a question that was never asked.
  #
  # Now the issue is left COMPLETELY untouched — no comment, no state, no
  # priority. With no "Triaged by" comment it stays in `list triageable` and is
  # retried next run, the same fail-open shape as the open-PR deferral above.
  # A failure costs one triage cycle; it can never manufacture a human gate.
  VERDICT=$(echo "$TRIAGE_RESULT" | grep -oE 'VERDICT: (APPROVE|ENHANCE|SKIP|FLAG|RESCOPE)' | head -1 | sed 's/VERDICT: //')

  if [ -z "$VERDICT" ]; then
    FAILED=$((FAILED + 1))
    FAILED_IDS+="$issue_id "
    _WHY=$(echo "$TRIAGE_RESULT" | grep -oE 'Error: Reached max turns \([0-9]+\)|API error [0-9]+' | head -1)
    echo "  ⚠️  DEFERRED: $ISSUE_TITLE" | tee -a "$TRIAGE_LOG"
    echo "      no verdict parsed from $TRIAGE_MODEL${_WHY:+ ($_WHY)} — issue left untouched, retried next run" | tee -a "$TRIAGE_LOG"
    echo "$TRIAGE_RESULT" >> "$TRIAGE_LOG"
    log_warn "triage: no verdict for $issue_id (model=$TRIAGE_MODEL)${_WHY:+ — $_WHY}"
    continue
  fi

  echo "  $VERDICT: $ISSUE_TITLE" | tee -a "$TRIAGE_LOG"
  echo "$TRIAGE_RESULT" >> "$TRIAGE_LOG"

  if [ "$DRY_RUN" = "--dry-run" ]; then
    continue
  fi

  ISSUE_URL=$(bash "$TRACKER" issue-url "$issue_id")

  case "$VERDICT" in
    APPROVE)
      APPROVED=$((APPROVED + 1))
      IMPL_PLAN=$(echo "$TRIAGE_RESULT" | sed -n '/IMPLEMENTATION_PLAN:/,/ACCEPTANCE_CRITERIA:\|COMPLEXITY:\|SUGGESTED_PRIORITY:\|$/p' | head -10)
      CONFIDENCE=$(echo "$TRIAGE_RESULT" | grep -oE 'CONFIDENCE: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "?")
      COMPLEXITY=$(echo "$TRIAGE_RESULT" | grep -oE 'COMPLEXITY: [a-z]+' | head -1 | sed 's/COMPLEXITY: //' || echo "?")
      # Acceptance criteria: pipe-separated in the model output, rendered as a
      # checklist. This is the definition of done — the builder verifies each
      # criterion before pushing, and the human reviewer checks them on the PR.
      ACCEPTANCE=$(echo "$TRIAGE_RESULT" | grep -oE 'ACCEPTANCE_CRITERIA: .*' | head -1 | sed 's/ACCEPTANCE_CRITERIA: //')
      ACCEPTANCE_BULLETS=$(echo "$ACCEPTANCE" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/- [ ] /')
      bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — ✅ APPROVED

$IMPL_PLAN

${ACCEPTANCE_BULLETS:+**Acceptance criteria** (definition of done — builder verifies each before opening the PR):
$ACCEPTANCE_BULLETS

}---
_Automated triage — suggested starting point, not a mandate. Read the codebase and deviate if you find a better approach._" || true
      bash "$TRACKER" update "$issue_id" --state unstarted || true
      RESULTS+="  • ✅ <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} _(${COMPLEXITY}, confidence ${CONFIDENCE}/10)_\n"
      ;;
    ENHANCE)
      ENHANCED=$((ENHANCED + 1))
      ENHANCED_DESC=$(echo "$TRIAGE_RESULT" | sed -n '/ENHANCED_DESCRIPTION:/,/IMPLEMENTATION_PLAN:\|$/p' | head -5 | sed 's/ENHANCED_DESCRIPTION: //')
      IMPL_PLAN=$(echo "$TRIAGE_RESULT" | sed -n '/IMPLEMENTATION_PLAN:/,/ACCEPTANCE_CRITERIA:\|COMPLEXITY:\|SUGGESTED_PRIORITY:\|$/p' | head -10)
      CONFIDENCE=$(echo "$TRIAGE_RESULT" | grep -oE 'CONFIDENCE: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "?")
      COMPLEXITY=$(echo "$TRIAGE_RESULT" | grep -oE 'COMPLEXITY: [a-z]+' | head -1 | sed 's/COMPLEXITY: //' || echo "?")
      ACCEPTANCE=$(echo "$TRIAGE_RESULT" | grep -oE 'ACCEPTANCE_CRITERIA: .*' | head -1 | sed 's/ACCEPTANCE_CRITERIA: //')
      ACCEPTANCE_BULLETS=$(echo "$ACCEPTANCE" | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d; s/^/- [ ] /')
      bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — ✨ ENHANCED

**Refined scope:**
$ENHANCED_DESC

$IMPL_PLAN

${ACCEPTANCE_BULLETS:+**Acceptance criteria** (definition of done — builder verifies each before opening the PR):
$ACCEPTANCE_BULLETS

}---
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
      bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — ⏭️ SKIP

$REASON

---
_Automated triage — can be overridden by moving to Unstarted._" || true
      # Deterministic backstop for the GA carve-out. The prompt tells the model
      # not to SKIP an origin:aaron issue, but a prompt is a request, not a
      # guarantee — and the demotion to priority:4 is exactly what buries a
      # hand-filed issue for good. Keep the SKIP comment (the reasoning may be
      # worth reading) but refuse the demotion.
      if [ -n "$MANUAL_FILED" ]; then
        echo "    ⚠️  SKIP verdict on hand-filed $issue_id — keeping priority:1-urgent (GA carve-out)" | tee -a "$TRIAGE_LOG"
        log_warn "triage returned SKIP on origin:aaron issue $issue_id; demotion suppressed"
        bash "$TRACKER" comment-add "$issue_id" "⚠️ The SKIP above was **not** applied to this issue's priority. It carries \`origin:aaron\` (filed by hand), so the GA-readiness policy does not defer it and it stays at \`priority:1-urgent\`. If this really should be dropped, remove the \`origin:aaron\` label." || true
      else
        bash "$TRACKER" update "$issue_id" --priority 4 || true
      fi
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

      bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — 🚩 NEEDS INPUT

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
          bash "$TRACKER" comment-add "$SUB_ID" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — ✅ APPROVED (split from ${issue_id})

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
        bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — 🔀 RESCOPED

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
        bash "$TRACKER" comment-add "$issue_id" "**$TRIAGE_MARKER $TRIAGE_MODEL** ($DATE) — 🚩 RESCOPE FAILED

Attempted to split this issue but sub-issue creation failed. Needs manual rescoping.

$REASON" || true
        RESULTS+="  • 🚩 <${ISSUE_URL}|${issue_id}>: ${ISSUE_TITLE} — _rescope failed, needs manual split_\n"
      fi
      ;;
  esac
done

echo "" | tee -a "$TRIAGE_LOG"
echo "━━━ Triage Complete ━━━" | tee -a "$TRIAGE_LOG"
echo "Approved: $APPROVED | Enhanced: $ENHANCED | Rescoped: $RESCOPED | Skipped: $SKIPPED | Flagged: $FLAGGED | Deferred (no verdict): $FAILED" | tee -a "$TRIAGE_LOG"
if [ "$FAILED" -gt 0 ]; then
  echo "  ⚠️  $FAILED issue(s) got no parseable verdict and were left untouched: $(echo "$FAILED_IDS" | xargs)" | tee -a "$TRIAGE_LOG"
  echo "      They keep no 'Triaged by' comment, so the next run retries them automatically." | tee -a "$TRIAGE_LOG"
fi

# Triage metrics CSV
TRIAGE_METRICS_CSV="$OUTPUT_DIR/lift-triage-metrics.csv"
if [ ! -f "$TRIAGE_METRICS_CSV" ]; then
  echo "date,total,approved,enhanced,rescoped,skipped,flagged,model,failed" > "$TRIAGE_METRICS_CSV"
fi
# Schema migration. Columns have been added to the row format twice without the
# header ever being rewritten — the header is only emitted when the file does
# not exist, so it froze at the original 7 columns. `rescoped` was inserted in
# 97c06d5 and `failed` added 2026-08-29, leaving a 7-column header sitting over
# 8-column rows: every row ragged, and csv.DictReader silently bucketing the
# overflow under the None key while `row.get("model")` returned the *flagged*
# count. Normalise header and rows to the current schema. Pre-RESCOPE rows take
# rescoped=0 (the verdict did not exist yet); every pre-fix row takes failed=0
# (an unparseable verdict was miscounted as FLAG back then, and is counted in
# the flagged column). Idempotent — a matching header is left alone.
_CSV_SCHEMA="date,total,approved,enhanced,rescoped,skipped,flagged,model,failed"
if [ "$(head -1 "$TRIAGE_METRICS_CSV" 2>/dev/null)" != "$_CSV_SCHEMA" ]; then
  awk -F, -v schema="$_CSV_SCHEMA" '
    NR==1        { print schema; next }
    NF==0        { next }
    NF==7        { print $1","$2","$3","$4",0,"$5","$6","$7",0"; next }   # pre-rescoped, pre-failed
    NF==8        { print $0 ",0"; next }                                  # pre-failed
                 { print }
  ' "$TRIAGE_METRICS_CSV" > "$TRIAGE_METRICS_CSV.tmp" \
    && mv "$TRIAGE_METRICS_CSV.tmp" "$TRIAGE_METRICS_CSV"
fi
if [ "$DRY_RUN" != "--dry-run" ]; then
  echo "$DATE,$UNTRIAGED_COUNT,$APPROVED,$ENHANCED,$RESCOPED,$SKIPPED,$FLAGGED,$TRIAGE_MODEL,$FAILED" >> "$TRIAGE_METRICS_CSV"
fi
log_info "Triage complete: $APPROVED approved, $ENHANCED enhanced, $RESCOPED rescoped, $SKIPPED skipped, $FLAGGED flagged, $FAILED deferred (no verdict)"

# Slack notification
if [ "$DRY_RUN" != "--dry-run" ]; then
  bash "$NOTIFY" --as triage thread-reply automation "$THREAD_TS" "*Triage complete*${RETRIAGE:+ (re-triage sweep)} — $UNTRIAGED_COUNT issues reviewed (model: $TRIAGE_MODEL)
✅ $APPROVED approved | ✨ $ENHANCED enhanced | 🔀 $RESCOPED rescoped | ⏭️ $SKIPPED skipped | 🚩 $FLAGGED flagged${FAILED:+ | ⚠️ $FAILED deferred}

$(echo -e "$RESULTS")${FAILED:+$([ "$FAILED" -gt 0 ] && printf '\n⚠️ *%s issue(s) got no parseable verdict* and were left untouched (retried next run): %s\n' "$FAILED" "$(echo "$FAILED_IDS" | xargs)")}
<$(bash "$TRACKER" board-url)|Issue Board>"
fi

echo ""
echo "📊 Triage log: $TRIAGE_LOG"
