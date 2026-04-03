#!/bin/bash
# Overnight Self-Improving Portfolio Enhancer for Lift app
# Each iteration picks one issue, creates a branch, implements, reviews, and opens a PR.
#
# Usage:
#   ./builder.sh          # runs until 7:00 AM
#   ./builder.sh 06:00    # runs until 6:00 AM
#   ./builder.sh 1        # runs exactly 1 iteration
#
# Logs: ~/Documents/Claude/outputs/lift-enhance-<date>-run<N>.md

set -uo pipefail
# Note: not using -e (errexit) — individual command failures should not abort the loop.
# Failures are tracked via FAILURES counter and MAX_CONSECUTIVE_FAILURES.

# Source env vars when run by launchd (no login shell)
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/builder-utils.sh"
LOG_COMPONENT="builder"

slack_send() {
  bash "$NOTIFY" --as builder send-async automation "$1"
}
# thread_send is defined after THREAD_TS is set (below)

REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
STOP_AT="${1:-07:00}"
RUN=0
MAX_CONSECUTIVE_FAILURES=3
FAILURES=0
MAX_STALLS=2
STALLS=0
MAX_FIX_ATTEMPTS=1

mkdir -p "$OUTPUT_DIR"

# ── Usage tracking ───────────────────────────────────────────────────────────
BUDGET_CONF="$SCRIPT_DIR/../config/budget.conf"
[ -f "$BUDGET_CONF" ] && source "$BUDGET_CONF"
MAX_ITERATIONS_PER_NIGHT="${MAX_ITERATIONS_PER_NIGHT:-12}"
MAX_OUTPUT_TOKENS_PER_NIGHT="${MAX_OUTPUT_TOKENS_PER_NIGHT:-500000}"
ITERATION_COOLDOWN="${ITERATION_COOLDOWN:-30}"
ALERT_THRESHOLD_PCT="${ALERT_THRESHOLD_PCT:-80}"
DEFAULT_STOP_TIME="${DEFAULT_STOP_TIME:-07:00}"

USAGE_CSV="$OUTPUT_DIR/lift-usage-tracking.csv"
if [ ! -f "$USAGE_CSV" ]; then
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$USAGE_CSV"
fi

NIGHTLY_OUTPUT_TOKENS=0
ALERT_SENT=false

# parse_usage, usage_check, should_continue, parse_stop_time,
# pick_worst_verdict, verdict_emoji, format_review_findings,
# format_review_crosschecks are defined in lib/builder-utils.sh

parse_stop_time "${STOP_AT}" "${DEFAULT_STOP_TIME}"

# ── Worktree setup ──────────────────────────────────────────────────────────
# Use a git worktree so the builder never touches Aaron's working directory.
WORKTREE_DIR="${REPO}-builder"

cd "$REPO"
git fetch origin 2>/dev/null || true

# Set up or reuse the worktree (always on main/master for branch-per-issue)
if [ -d "$WORKTREE_DIR" ]; then
  cd "$WORKTREE_DIR"
  git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
  git pull --ff-only origin "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
else
  # Create worktree on main branch
  MAIN_CURRENT=$(cd "$REPO" && git branch --show-current 2>/dev/null || echo "")
  if [ "$MAIN_CURRENT" = "${DEFAULT_BRANCH:-master}" ]; then
    cd "$REPO" && git checkout --detach 2>/dev/null || true
  fi
  git worktree add "$WORKTREE_DIR" "${DEFAULT_BRANCH:-master}" 2>&1 || {
    echo "  ⚠️ Failed to create worktree. Falling back to main repo."
    WORKTREE_DIR="$REPO"
    cd "$REPO"
    git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
  }
  cd "$WORKTREE_DIR"
fi

# From here on, REPO points to the worktree (builder's isolated copy)
REPO="$WORKTREE_DIR"

# Ensure dependencies are installed in the worktree
if [ ! -d "$REPO/node_modules" ]; then
  echo "📦 Installing dependencies in worktree..."
  cd "$REPO" && npm ci --silent 2>&1 | tail -3
fi

BUILDER_START=$(date +%s)
echo "🤖 Starting overnight enhancer at $(date)"
echo "   Stop time: $STOP_AT | Worktree: $REPO"

# Start a Slack thread for this session — all updates go under it
THREAD_TS=$(bash "$NOTIFY" --as builder thread-start automation "🤖 *$PROJECT_NAME Overnight Build — $DATE*
Stop: $STOP_AT | Branch-per-issue mode")
THREAD_TS=$(echo "$THREAD_TS" | tr -d ' \n')

# Helper: post to the thread (falls back to standalone if no thread)
thread_send() {
  bash "$NOTIFY" --as builder thread-reply automation "$THREAD_TS" "$1"
}
echo ""

# Metrics tracking
METRICS_FILE="$OUTPUT_DIR/lift-metrics.csv"
if [ ! -f "$METRICS_FILE" ]; then
  echo "date,run,start_time,end_time,duration_sec,commits,tests_before,tests_after,tests_delta,issues_done,issues_skipped,issues_created,build_size_kb,success" > "$METRICS_FILE"
fi

# Track PRs created tonight
NIGHTLY_PRS=""
NIGHTLY_PR_COUNT=0
NIGHTLY_VERDICTS=""

# ── Check for failed PRs from previous nights to retry ──────────────────────
FAILED_PRS=$(cd "$REPO" && gh pr list --author "@me" --label "ci:failed" --json number,headRefName,title -q '.[].headRefName' 2>/dev/null || echo "")
RETRY_ISSUES=""
if [ -n "$FAILED_PRS" ]; then
  for failed_branch in $FAILED_PRS; do
    # Extract issue ID from branch name (enhance/MAS-123-2026-04-02)
    FAILED_ISSUE=$(echo "$failed_branch" | grep -oE 'MAS-[0-9]+' || true)
    if [ -n "$FAILED_ISSUE" ]; then
      RETRY_ISSUES+="$FAILED_ISSUE "
      # Close the old failed PR
      gh pr close "$failed_branch" --delete-branch 2>/dev/null || true
      echo "  🔄 Closed failed PR for $FAILED_ISSUE — will retry"
    fi
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# ── Main loop: one issue per iteration, one branch per issue ─────────────────
# ══════════════════════════════════════════════════════════════════════════════
while should_continue; do
  RUN=$((RUN + 1))
  RUN_LOG="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}.md"

  # ── Return to main branch for a clean start ──────────────────────────────
  cd "$REPO"
  git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
  git pull --ff-only origin "${DEFAULT_BRANCH:-master}" 2>/dev/null || true

  # Snapshot state before this iteration
  TESTS_BEFORE=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo "0")
  ITER_START=$(date +%s)
  ITER_START_FMT=$(date +%H:%M:%S)

  echo "━━━ Run $RUN starting at $(date) ━━━" | tee "$RUN_LOG"

  # Gather summaries from earlier runs today + recent days
  PREVIOUS_SUMMARIES=""
  for f in $(ls -t "$OUTPUT_DIR"/lift-enhance-*.md 2>/dev/null | head -3); do
    [ "$f" = "$RUN_LOG" ] && continue
    PREVIOUS_SUMMARIES+="
--- $(basename "$f") ---
$(sed -n '/## Summary/,/^---\|^$/p' "$f" 2>/dev/null | head -30)
$(sed -n '/## Plan/,/## /p' "$f" 2>/dev/null | head -20)
"
  done

  # Snapshot current state for the prompt
  TEST_COUNT=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | tail -5 || echo "unknown")
  GIT_LOG=$(cd "$REPO" && git log --oneline -10)

  # Pull Linear backlog for the Lift project
  LINEAR_ISSUES=$(bash "$TRACKER" list unstarted started || echo "Could not fetch Linear issues")

  # Fetch full details (description + comments) for top priority issues
  TOP_ISSUE_IDS=$({ echo "$LINEAR_ISSUES" | grep -oE 'MAS-[0-9]+' | head -5; } || true)
  ISSUE_DETAILS=""
  for issue_id in $TOP_ISSUE_IDS; do
    detail=$(bash "$TRACKER" view "$issue_id" || true)
    ISSUE_DETAILS+="
--- $issue_id ---
$detail
"
  done

  # Gather recently skipped issues so Claude avoids retrying them this session
  SKIPPED_ISSUES=$(grep -rohE 'LINEAR_SKIPPED:MAS-[0-9]+:[^"]*' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | sort -u || true)

  # ── Create a branch for this iteration ───────────────────────────────────
  # Branch name will be updated once we know which issue Claude picks.
  # Start on a temporary branch; rename after we parse the run log.
  ITER_BRANCH="enhance/run${RUN}-$DATE"
  git checkout -b "$ITER_BRANCH" "${DEFAULT_BRANCH:-master}" 2>/dev/null || {
    # Branch may already exist from a retry — force reset it
    git checkout "$ITER_BRANCH" 2>/dev/null || true
    git reset --hard "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
  }

  # ── Run Claude implementation ────────────────────────────────────────────
  COMMITS_BEFORE=$(git rev-list --count HEAD)
  CLAUDE_JSON="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}-output.json"
  if claude --dangerously-skip-permissions --output-format json -p "$(cat <<PROMPT
You are iteration $RUN of the overnight self-improving enhancer for $PROJECT_NAME at $REPO. This is Aaron Chung's portfolio project — he's an ex-AWS SDE2 targeting SWE roles at companies like Notion, Airtable, and Linear.

You are running in a loop. Previous iterations tonight and from recent days have already made improvements. Your job is to find the NEXT most impactful thing to do that hasn't been done yet.

## IMPORTANT: Branch-per-issue mode

You are working on a FRESH branch off ${DEFAULT_BRANCH:-master}. Each iteration produces its own PR for exactly ONE issue.
- Pick ONE high-impact issue from the backlog below
- Implement it fully, commit with conventional commit messages
- Focus on quality — this PR will be independently reviewed

${RETRY_ISSUES:+## Retry priority
These issues had failed PRs from previous nights. Prioritize retrying them:
$RETRY_ISSUES
}

## Conventional commits

Use structured commit prefixes:
- feat(MAS-XXX): for new features
- fix(MAS-XXX): for bug fixes
- a11y(MAS-XXX): for accessibility improvements
- test(MAS-XXX): for test additions
- perf(MAS-XXX): for performance improvements
- style(MAS-XXX): for visual/CSS changes
- refactor(MAS-XXX): for code refactoring
- chore(MAS-XXX): for maintenance tasks

## Current repo state

Recent commits:
$GIT_LOG

Current test output:
$TEST_COUNT

## What previous iterations accomplished

$PREVIOUS_SUMMARIES

## Linear backlog (open issues for $PROJECT_NAME)

$LINEAR_ISSUES

## Issue details (descriptions + comments — may include triage agent suggestions as a STARTING POINT — read the codebase and use your own judgment; deviate from suggestions if you find a better approach)

$ISSUE_DETAILS

## Issues skipped earlier tonight (do NOT retry these)

${SKIPPED_ISSUES:-None}

## Your job (this iteration)

1. **Read the repo** — look at what exists NOW (code, tests, config, README, etc.)
2. **Pick exactly ONE issue** from the Linear backlog to implement fully
3. **Cross-reference** with what previous iterations already did
4. **Implement it**, committing after each logical change with conventional commit messages
5. **Verify** tests pass and build succeeds

## Discovery (every iteration)

While reading the codebase, actively look for problems and improvement opportunities. For each discovery, output a LINEAR_DISCOVER line (see output format). Look for:
- UI bugs (contrast issues, layout shifts, broken themes, missing aria attributes)
- Code smells (dead code, unused imports, inconsistent patterns, TODO comments)
- Missing tests for critical paths
- Performance issues (large bundles, unnecessary re-renders, unoptimized images)
- Accessibility violations (missing labels, low contrast, keyboard traps)
- CLAUDE.md checklist violations (hardcoded colors, wrong spacing, missing safe-area-inset)
- Dependency vulnerabilities (check package.json for outdated or insecure deps)

Do NOT fix discoveries in the same iteration — just create the Linear issue. Fix them in a future iteration when they are the highest priority.

## Rules

- Pick ONE issue — do not mix multiple unrelated changes in one iteration
- Do NOT redo work from previous iterations — if tests exist, don't rewrite them
- Do NOT break existing functionality — run tests after each change
- Quality over quantity — fully implement the issue rather than doing it halfway
- If you cannot find anything meaningful to improve, output ONLY the line "NO_IMPROVEMENTS_REMAINING" and exit
- Commit with clear conventional commit messages (feat/fix/a11y/test/perf/style/refactor/chore prefix)
- If a test is failing when you start, you may try to fix it ONCE. If it still fails after one attempt, skip it and move on to new work. Do not spend more than 10 turns on any single fix.
- IMPORTANT: Focus on SHIPPING, not perfecting. Commit working improvements and move on.
- Do NOT create branches — you are already on the correct branch. Just commit to the current branch.
- Do NOT create pull requests — the pipeline handles PR creation after your work is done.
- Do NOT push to remote — the pipeline handles pushing.

## Output format

## Plan
What issue you chose and why (1-3 sentences). Include the issue ID.

## Changes
What you did (bullet points)

## Linear updates
CRITICAL: You MUST output Linear status lines for the issue you worked on. Output each on its own line with NO leading whitespace.

For the issue you implemented:
LINEAR_DONE:MAS-XXX|Brief summary of implementation and any notable decisions
LINEAR_PROGRESS:MAS-XXX|What was completed so far and what remains
LINEAR_SKIPPED:MAS-XXX:reason (if you attempted but could not complete it)

If you did work that has no matching Linear issue, create one:
LINEAR_CREATE:priority:title
Then also output LINEAR_DONE or LINEAR_PROGRESS for it.

For discoveries you found but did NOT fix this iteration:
LINEAR_DISCOVER:priority:title
Priority is 1-4 (1=urgent, 2=high, 3=medium, 4=low).

Do not fabricate existing issue IDs — only use IDs from the backlog above.

## Summary
- Issue: MAS-XXX (title)
- Tests: X passing
- Build: pass/fail
- Category: feat|fix|a11y|test|perf|style|refactor|chore
PROMPT
)" --max-turns 100 2>&1 > "$CLAUDE_JSON"; then
    # Extract text result and append to run log
    CLAUDE_RESULT=$(python3 -c "
import json, sys
try:
    with open('$CLAUDE_JSON') as f:
        data = json.load(f)
    result = data.get('result', '')
    if result:
        print(result)
    else:
        print('⚠️ Claude returned empty result', file=sys.stderr)
except Exception as e:
    print(f'❌ Failed to parse Claude output: {e}', file=sys.stderr)
" 2>&1)
    if echo "$CLAUDE_RESULT" | grep -q "^⚠️\|^❌"; then
      echo "  $CLAUDE_RESULT" | tee -a "$RUN_LOG"
      thread_send "🚨 *Builder Run $RUN — Claude issue*
$CLAUDE_RESULT"
    else
      echo "$CLAUDE_RESULT" >> "$RUN_LOG"
    fi

    # Track token usage
    USAGE_DATA=$(parse_usage "$CLAUDE_JSON")
    ITER_OUTPUT=$(echo "$USAGE_DATA" | cut -d',' -f2)
    NIGHTLY_OUTPUT_TOKENS=$((NIGHTLY_OUTPUT_TOKENS + ITER_OUTPUT))
    ITER_END_USAGE=$(date +%s)
    ITER_DUR=$((ITER_END_USAGE - ITER_START))
    echo "$DATE,$RUN,$USAGE_DATA,$NIGHTLY_OUTPUT_TOKENS,$ITER_DUR" >> "$USAGE_CSV"
    echo "  📊 Output tokens: ${ITER_OUTPUT} | Nightly total: ${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} | Run $RUN/${MAX_ITERATIONS_PER_NIGHT}" | tee -a "$RUN_LOG"

    FAILURES=0

    # Check if Claude signaled nothing left to do
    if grep -q "NO_IMPROVEMENTS_REMAINING" "$RUN_LOG" 2>/dev/null; then
      echo "🏁 Claude says nothing left to improve." | tee -a "$RUN_LOG"
      STALLS=$MAX_STALLS  # force stop
      # Clean up empty branch
      git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
      git branch -D "$ITER_BRANCH" 2>/dev/null || true
    else
      # Check if any new commits were actually produced
      COMMITS_AFTER=$(git rev-list --count HEAD)
      NEW_COMMITS=$((COMMITS_AFTER - COMMITS_BEFORE))
      if [ "$NEW_COMMITS" -eq 0 ]; then
        STALLS=$((STALLS + 1))
        echo "⚠️  Run $RUN produced no commits (stall $STALLS/$MAX_STALLS)" | tee -a "$RUN_LOG"
        ITER_END=$(date +%s)
        ITER_DURATION=$((ITER_END - ITER_START))
        echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,,stall" >> "$METRICS_FILE"
        # Clean up empty branch
        git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
        git branch -D "$ITER_BRANCH" 2>/dev/null || true
      else
        STALLS=0
        echo "✅ Run $RUN finished at $(date) — $NEW_COMMITS new commit(s)" | tee -a "$RUN_LOG"

        # ── Rename branch to match the issue ─────────────────────────────
        PRIMARY_ISSUE=$(grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/LINEAR_DONE://" || true)
        if [ -z "$PRIMARY_ISSUE" ]; then
          PRIMARY_ISSUE=$(grep -oE "LINEAR_PROGRESS:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/LINEAR_PROGRESS://" || true)
        fi
        if [ -n "$PRIMARY_ISSUE" ]; then
          NEW_BRANCH="enhance/${PRIMARY_ISSUE}-$DATE"
          if [ "$NEW_BRANCH" != "$ITER_BRANCH" ]; then
            git branch -m "$ITER_BRANCH" "$NEW_BRANCH" 2>/dev/null || true
            ITER_BRANCH="$NEW_BRANCH"
          fi
        fi

        # ── Extract issue category for PR labeling ───────────────────────
        ISSUE_CATEGORY=$(grep -oE 'Category: (feat|fix|a11y|test|perf|style|refactor|chore)' "$RUN_LOG" 2>/dev/null | head -1 | sed 's/Category: //' || echo "feat")

        # ── Create new Linear issues for discoveries ─────────────────────
        { grep -oE 'LINEAR_DISCOVER:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  📋 Discovered issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" 2>&1 | tee -a "$RUN_LOG"
        done

        # Create new issues for work not in the backlog (already done)
        { grep -oE 'LINEAR_CREATE:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  Creating issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" --state "Done" 2>&1 | tee -a "$RUN_LOG"
        done

        # Handle skipped issues — move to Blocked with a comment
        { grep -oE "LINEAR_SKIPPED:${LINEAR_TEAM}-[0-9]+:[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ _ issue_id reason; do
          echo "  Blocking $issue_id: $reason" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "Blocked" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "Automated run blocked this issue on $DATE: $reason" 2>&1 | tee -a "$RUN_LOG"
        done

        # ── Layer 1 Review: Gemini Flash (mechanical gate) ────────────────
        REVIEW_ADAPTER="$SCRIPT_DIR/../adapters/ai-review.sh"
        DIFF_FILE=$(mktemp)
        git diff "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" > "$DIFF_FILE" 2>/dev/null

        L1_OUTPUT="$OUTPUT_DIR/lift-review-$DATE-run${RUN}-layer1.txt"
        bash "$REVIEW_ADAPTER" layer1 "$DIFF_FILE" "$L1_OUTPUT" 2>&1 | tee -a "$RUN_LOG"

        L1_VERDICT=$(grep "^REVIEW_VERDICT:" "$L1_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_VERDICT://' || echo "REVIEW")
        L1_MODEL=$(grep "^REVIEW_MODEL:" "$L1_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_MODEL://' || echo "unknown")
        L1_STATUS="✅"
        [ "$L1_MODEL" = "skipped" ] && L1_STATUS="⏭️"

        # Parse findings from Layer 1
        CRITICAL_FINDINGS=$(grep -E "^REVIEW_FIX:(critical|high):" "$L1_OUTPUT" 2>/dev/null || true)
        MEDIUM_LOW_FINDINGS=$(grep -E "^REVIEW_FIX:(medium|low):" "$L1_OUTPUT" 2>/dev/null || true)
        ALL_L1_FINDINGS=$(grep "^REVIEW_FIX:" "$L1_OUTPUT" 2>/dev/null || true)
        CRITICAL_COUNT=$(echo "$CRITICAL_FINDINGS" | grep -c "REVIEW_FIX" 2>/dev/null || echo "0")

        REVIEW_STATUS="clean"
        if echo "$L1_OUTPUT" | grep -q "REVIEW_CLEAN" 2>/dev/null; then
          echo "  Layer 1 verdict: ✅ MERGE (clean)" | tee -a "$RUN_LOG"
        elif [ "$CRITICAL_COUNT" -gt 0 ] 2>/dev/null; then
          echo "  Layer 1: $CRITICAL_COUNT critical/high finding(s), attempting fix..." | tee -a "$RUN_LOG"
          REVIEW_STATUS="findings-fixed"

          # ── Fix iteration for critical/high findings ──────────────────
          FIX_JSON="$OUTPUT_DIR/lift-fix-$DATE-run${RUN}.json"
          COMMITS_PRE_FIX=$(git rev-list --count HEAD)
          if claude --dangerously-skip-permissions --output-format json -p "$(cat <<FIX_PROMPT
You are fixing review findings in $PROJECT_NAME at $REPO on branch $ITER_BRANCH.
Do NOT create branches, PRs, or push. Just fix and commit.

## Review Findings (MUST FIX)
$CRITICAL_FINDINGS

## Your job
Fix each finding. Commit each fix with a conventional commit message:
fix(MAS-XXX): <description of fix>

Run tests after fixing to ensure nothing is broken.
FIX_PROMPT
)" --max-turns 50 2>&1 > "$FIX_JSON"; then
            FIX_USAGE=$(parse_usage "$FIX_JSON")
            FIX_TOKENS=$(echo "$FIX_USAGE" | cut -d',' -f2)
            NIGHTLY_OUTPUT_TOKENS=$((NIGHTLY_OUTPUT_TOKENS + FIX_TOKENS))
            FIX_COMMITS=$(($(git rev-list --count HEAD) - COMMITS_PRE_FIX))
            if [ "$FIX_COMMITS" -gt 0 ]; then
              echo "  🔧 Fix iteration: $FIX_COMMITS commit(s)" | tee -a "$RUN_LOG"
              NEW_COMMITS=$((NEW_COMMITS + FIX_COMMITS))
              # Update finding statuses
              CRITICAL_FINDINGS=$(echo "$CRITICAL_FINDINGS" | while IFS= read -r line; do
                echo "${line}|Status: 🔧 Fixed"
              done)
            else
              REVIEW_STATUS="findings-unfixed"
            fi
          else
            REVIEW_STATUS="findings-unfixed"
          fi

          # If fixes failed, revert and create Linear issue
          if [ "$REVIEW_STATUS" = "findings-unfixed" ]; then
            echo "  ↩️  Reverting run $RUN — could not fix review findings" | tee -a "$RUN_LOG"
            git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
            git branch -D "$ITER_BRANCH" 2>/dev/null || true
            if [ -n "$PRIMARY_ISSUE" ]; then
              bash "$TRACKER" comment-add "$PRIMARY_ISSUE" "Automated review found critical issues on $DATE. Reverted.
Findings:
$CRITICAL_FINDINGS" 2>&1 | tee -a "$RUN_LOG"
            fi
            thread_send "⚠️ *Run $RUN reverted* — critical issues couldn't be auto-fixed
${PRIMARY_ISSUE:+Issue: $PRIMARY_ISSUE}
$(echo "$CRITICAL_FINDINGS" | head -3)"
            ITER_END=$(date +%s)
            ITER_DURATION=$((ITER_END - ITER_START))
            echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,,reverted" >> "$METRICS_FILE"
            rm -f "$DIFF_FILE"
            sleep "$ITERATION_COOLDOWN"
            continue
          fi
        else
          # Has medium/low findings only
          REVIEW_STATUS="minor-only"
          echo "  Layer 1 verdict: $L1_VERDICT ($(echo "$ALL_L1_FINDINGS" | grep -c "REVIEW_FIX" || echo "0") finding(s))" | tee -a "$RUN_LOG"
        fi

        # Create Linear issues for medium/low findings (up to 5)
        if [ -n "$MEDIUM_LOW_FINDINGS" ]; then
          echo "$MEDIUM_LOW_FINDINGS" | head -5 | while IFS=: read -r _ severity filepath desc; do
            bash "$TRACKER" create "[Review] $desc" 3 --description "Found by Layer 1 review ($L1_MODEL) on $DATE in $filepath. Severity: $severity" 2>&1 | tee -a "$RUN_LOG"
          done
          # Mark deferred findings
          MEDIUM_LOW_FINDINGS=$(echo "$MEDIUM_LOW_FINDINGS" | while IFS= read -r line; do
            echo "${line}|Status: 📋 Deferred"
          done)
        fi

        # ── Push and create PR ───────────────────────────────────────────
        git push -u origin "$ITER_BRANCH" 2>&1 | tee -a "$RUN_LOG"

        # Update Linear issue status
        LATEST_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        COMMIT_URL="https://github.com/$GITHUB_REPO/commit/$LATEST_COMMIT"

        { grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+\|[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS='|' read -r marker summary; do
          issue_id=$(echo "$marker" | sed 's/LINEAR_DONE://')
          summary=${summary:-No details provided}
          echo "  Marking $issue_id as Done" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "Done" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "Completed by overnight automation on $DATE.

$summary

[View commit]($COMMIT_URL)" 2>&1 | tee -a "$RUN_LOG"
        done
        { grep -oE "LINEAR_PROGRESS:${LINEAR_TEAM}-[0-9]+\|[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS='|' read -r marker summary; do
          issue_id=$(echo "$marker" | sed 's/LINEAR_PROGRESS://')
          summary=${summary:-No details provided}
          echo "  Marking $issue_id as In Progress" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "In Progress" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "In progress — $summary" 2>&1 | tee -a "$RUN_LOG"
        done

        # Build structured PR description
        ISSUE_TITLE=$(grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+\|.*" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/LINEAR_DONE:${LINEAR_TEAM}-[0-9]*|//" || echo "")
        if [ -z "$ISSUE_TITLE" ]; then
          ISSUE_TITLE=$(grep -oE "LINEAR_PROGRESS:${LINEAR_TEAM}-[0-9]+\|.*" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/LINEAR_PROGRESS:${LINEAR_TEAM}-[0-9]*|//" || echo "Improvements")
        fi
        ISSUE_URL=""
        [ -n "$PRIMARY_ISSUE" ] && ISSUE_URL="https://linear.app/$LINEAR_ORG/issue/$PRIMARY_ISSUE"

        PLAN=$(sed -n '/^## Plan/,/^## /p' "$RUN_LOG" 2>/dev/null | grep -v '^## ' | head -5)
        CHANGES=$(sed -n '/^## Changes/,/^## /p' "$RUN_LOG" 2>/dev/null | grep -v '^## ' | head -10)
        TESTS_AFTER=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo "0")
        TESTS_DELTA=$((TESTS_AFTER - TESTS_BEFORE))

        PR_COMMIT_LIST=$(git log --oneline "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null | while read -r line; do
          HASH=$(echo "$line" | cut -d' ' -f1)
          MSG=$(echo "$line" | cut -d' ' -f2-)
          echo "- [\`$HASH\`](https://github.com/$GITHUB_REPO/commit/$HASH) $MSG"
        done)

        FIRST_COMMIT_MSG=$(git log --format=%s -1 "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null || echo "")
        PR_TITLE="${FIRST_COMMIT_MSG:-$ISSUE_CATEGORY($PRIMARY_ISSUE): $ISSUE_TITLE}"
        PR_TITLE=$(echo "$PR_TITLE" | head -c 70)

        PR_LABEL_ARGS=""
        case "$ISSUE_CATEGORY" in
          a11y)     PR_LABEL_ARGS="--label type:a11y" ;;
          test)     PR_LABEL_ARGS="--label type:test" ;;
          fix)      PR_LABEL_ARGS="--label type:bugfix" ;;
          perf)     PR_LABEL_ARGS="--label type:perf" ;;
          feat)     PR_LABEL_ARGS="--label type:feature" ;;
          style)    PR_LABEL_ARGS="--label type:style" ;;
          *)        PR_LABEL_ARGS="" ;;
        esac

        PR_URL=$(gh pr create --base "${DEFAULT_BRANCH:-master}" --head "$ITER_BRANCH" \
          --title "$PR_TITLE" \
          $PR_LABEL_ARGS \
          --body "$(cat <<PRBODY
## Summary
${PRIMARY_ISSUE:+**Issue:** [$PRIMARY_ISSUE]($ISSUE_URL)
}
$PLAN

## Changes
$CHANGES

## Commits
$PR_COMMIT_LIST

## Test Results
- Before: $TESTS_BEFORE passing
- After: $TESTS_AFTER passing (${TESTS_DELTA:+$TESTS_DELTA} delta)

---
_Automated by overnight pipeline — $(date)_
PRBODY
)" 2>&1 || echo "")

        if echo "$PR_URL" | grep -q "github.com"; then
          PR_URL=$(echo "$PR_URL" | grep -oE 'https://github.com/[^ ]+' | head -1)
        else
          PR_URL=$(cd "$REPO" && gh pr view "$ITER_BRANCH" --json url -q .url 2>/dev/null || echo "https://github.com/$GITHUB_REPO/pull/new/$ITER_BRANCH")
        fi

        NIGHTLY_PRS+="$PR_URL "
        NIGHTLY_PR_COUNT=$((NIGHTLY_PR_COUNT + 1))
        PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || true)

        # ── Post Layer 1 review comment on PR ────────────────────────────
        if [ -n "$PR_NUMBER" ] && [ "$L1_MODEL" != "skipped" ]; then
          L1_FINDINGS_MD=$(format_review_findings "$L1_OUTPUT")
          L1_VERDICT_EMOJI=$(verdict_emoji "$L1_VERDICT")
          BLOCKER_COUNT=$(grep -cE "^REVIEW_FIX:(critical|high):" "$L1_OUTPUT" 2>/dev/null || echo "0")
          NOTE_COUNT=$(grep -cE "^REVIEW_FIX:(medium|low):" "$L1_OUTPUT" 2>/dev/null || echo "0")

          gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPO" --body "## 🔍 Review — Gemini Flash (mechanical)

**Verdict: $L1_VERDICT_EMOJI $L1_VERDICT** | $BLOCKER_COUNT blocker(s) | $NOTE_COUNT note(s)

${L1_FINDINGS_MD:+### Findings
$L1_FINDINGS_MD
}${L1_FINDINGS_MD:+
}---
_$L1_MODEL | Layer 1_" 2>&1 || echo "  ⚠️ Failed to post Layer 1 comment"
        fi

        # ── Decide if deep review (Layers 2+3) is needed ────────────────
        # Run deep review if: Layer 1 found findings, OR high-risk category (feat/fix)
        L1_HAS_FINDINGS=$(grep -c "^REVIEW_FIX:" "$L1_OUTPUT" 2>/dev/null || echo "0")
        NEEDS_DEEP_REVIEW=false
        if [ "$L1_HAS_FINDINGS" -gt 0 ]; then
          NEEDS_DEEP_REVIEW=true
          echo "  → Deep review triggered: Layer 1 found $L1_HAS_FINDINGS finding(s)" | tee -a "$RUN_LOG"
        elif [ "$ISSUE_CATEGORY" = "feat" ] || [ "$ISSUE_CATEGORY" = "fix" ]; then
          NEEDS_DEEP_REVIEW=true
          echo "  → Deep review triggered: high-risk category ($ISSUE_CATEGORY)" | tee -a "$RUN_LOG"
        else
          echo "  → Skipping deep review: Layer 1 clean + low-risk category ($ISSUE_CATEGORY)" | tee -a "$RUN_LOG"
        fi

        L2_VERDICT="MERGE"; L2_MODEL="skipped"; L2_STATUS="⏭️"
        L3_VERDICT="MERGE"; L3_MODEL="skipped"; L3_STATUS="⏭️"
        PRIOR_FINDINGS_FILE=$(mktemp)
        cat "$L1_OUTPUT" > "$PRIOR_FINDINGS_FILE" 2>/dev/null

        if [ "$NEEDS_DEEP_REVIEW" = "true" ]; then
          # ── Layer 2 Review: Gemini Pro (architecture) ──────────────────
          # Refresh diff in case fix iteration added commits
          git diff "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" > "$DIFF_FILE" 2>/dev/null

          L2_OUTPUT="$OUTPUT_DIR/lift-review-$DATE-run${RUN}-layer2.txt"
          bash "$REVIEW_ADAPTER" layer2 "$DIFF_FILE" "$L2_OUTPUT" --prior-findings "$PRIOR_FINDINGS_FILE" 2>&1 | tee -a "$RUN_LOG"

          L2_VERDICT=$(grep "^REVIEW_VERDICT:" "$L2_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_VERDICT://' || echo "REVIEW")
          L2_MODEL=$(grep "^REVIEW_MODEL:" "$L2_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_MODEL://' || echo "unknown")
          L2_STATUS="✅"
          [ "$L2_MODEL" = "skipped" ] && L2_STATUS="⏭️"

          # Post Layer 2 comment
          if [ -n "$PR_NUMBER" ] && [ "$L2_MODEL" != "skipped" ]; then
            L2_FINDINGS_MD=$(format_review_findings "$L2_OUTPUT")
            L2_CROSSCHECK_MD=$(format_review_crosschecks "$L2_OUTPUT")
            L2_VERDICT_EMOJI=$(verdict_emoji "$L2_VERDICT")

            gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPO" --body "## 🔍 Review — Gemini Pro (architecture)

**Verdict: $L2_VERDICT_EMOJI $L2_VERDICT**

${L2_CROSSCHECK_MD:+### Cross-check with Layer 1
$L2_CROSSCHECK_MD
}
${L2_FINDINGS_MD:+### New findings
$L2_FINDINGS_MD
}
---
_$L2_MODEL | Layer 2_" 2>&1 || echo "  ⚠️ Failed to post Layer 2 comment"
          fi

          # ── Layer 3 Review: Claude Sonnet (self-check) ─────────────────
          cat "$L2_OUTPUT" >> "$PRIOR_FINDINGS_FILE" 2>/dev/null

          L3_OUTPUT="$OUTPUT_DIR/lift-review-$DATE-run${RUN}-layer3.txt"
          bash "$REVIEW_ADAPTER" layer3 "$DIFF_FILE" "$L3_OUTPUT" --prior-findings "$PRIOR_FINDINGS_FILE" 2>&1 | tee -a "$RUN_LOG"

          L3_VERDICT=$(grep "^REVIEW_VERDICT:" "$L3_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_VERDICT://' || echo "REVIEW")
          L3_MODEL=$(grep "^REVIEW_MODEL:" "$L3_OUTPUT" 2>/dev/null | head -1 | sed 's/REVIEW_MODEL://' || echo "unknown")
          L3_STATUS="✅"
          [ "$L3_MODEL" = "skipped" ] && L3_STATUS="⏭️"

          # Post Layer 3 comment
          if [ -n "$PR_NUMBER" ] && [ "$L3_MODEL" != "skipped" ]; then
            L3_FINDINGS_MD=$(format_review_findings "$L3_OUTPUT")
            L3_CROSSCHECK_MD=$(format_review_crosschecks "$L3_OUTPUT")
            L3_VERDICT_EMOJI=$(verdict_emoji "$L3_VERDICT")

            gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPO" --body "## 🔍 Review — Claude Sonnet (self-check)

**Verdict: $L3_VERDICT_EMOJI $L3_VERDICT**

${L3_CROSSCHECK_MD:+### Cross-check with Gemini
$L3_CROSSCHECK_MD
}
${L3_FINDINGS_MD:+### New findings
$L3_FINDINGS_MD
}
---
_$L3_MODEL | Layer 3_" 2>&1 || echo "  ⚠️ Failed to post Layer 3 comment"
          fi
        fi

        rm -f "$DIFF_FILE" "$PRIOR_FINDINGS_FILE"

        # ── Compute composite verdict ────────────────────────────────────
        COMPOSITE_VERDICT=$(pick_worst_verdict "$L1_VERDICT" "$L2_VERDICT" "$L3_VERDICT")
        # Track for end-of-night summary
        NIGHTLY_VERDICTS+="${PR_URL}|${COMPOSITE_VERDICT}|${PR_TITLE} "

        # ── Slack notification for this iteration ────────────────────────
        DONE_LINKS=$({ grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+\|[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS='|' read -r marker summary; do
          id=$(echo "$marker" | sed 's/LINEAR_DONE://')
          title=$(echo "$summary" | head -c 80)
          url=$(bash "$TRACKER" issue-url "$id")
          [ -n "$id" ] && echo "  ✅ <${url}|$id>: ${title:-no description}"
        done)

        ITER_COMMITS=$(git log --oneline "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null | while read -r line; do
          HASH=$(echo "$line" | cut -d' ' -f1)
          MSG=$(echo "$line" | cut -d' ' -f2-)
          echo "  • <https://github.com/$GITHUB_REPO/commit/$HASH|\`$HASH\`> $MSG"
        done)

        # Build review summary line for Slack
        COMPOSITE_EMOJI=$(verdict_emoji "$COMPOSITE_VERDICT")
        L1_FINDING_COUNT=$(grep -c "^REVIEW_FIX:" "$L1_OUTPUT" 2>/dev/null || echo "0")

        thread_send "*Run $RUN complete* — $NEW_COMMITS commit(s)
${DONE_LINKS}

🔍 *Review:* Flash $L1_STATUS | Pro $L2_STATUS | Sonnet $L3_STATUS → *$COMPOSITE_EMOJI $COMPOSITE_VERDICT*
${L1_FINDING_COUNT:+  $L1_FINDING_COUNT finding(s) from Flash}

${ITER_COMMITS:+*Commits:*
$ITER_COMMITS}
<$PR_URL|View PR>"

        # Collect metrics
        ITER_END=$(date +%s)
        ITER_DURATION=$((ITER_END - ITER_START))
        DONE_COUNT=$(grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        SKIPPED_COUNT=$(grep -oE "LINEAR_SKIPPED:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        CREATED_COUNT=$({ grep -oE 'LINEAR_CREATE:[1-4]:' "$RUN_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')
        BUILD_SIZE=$(cd "$REPO" && npm run build 2>&1 | grep -oE '[0-9]+\.[0-9]+ KiB' | head -1 | grep -oE '[0-9.]+' || echo "")
        echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,$NEW_COMMITS,$TESTS_BEFORE,$TESTS_AFTER,$TESTS_DELTA,$DONE_COUNT,$SKIPPED_COUNT,$CREATED_COUNT,$BUILD_SIZE,true" >> "$METRICS_FILE"
      fi
    fi
  else
    FAILURES=$((FAILURES + 1))
    log_error "Run $RUN failed (failure $FAILURES/$MAX_CONSECUTIVE_FAILURES)"
    echo "❌ Run $RUN failed at $(date) (failure $FAILURES/$MAX_CONSECUTIVE_FAILURES)" | tee -a "$RUN_LOG"
    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))
    echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,,false" >> "$METRICS_FILE"
    # Clean up empty branch
    git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
    git branch -D "$ITER_BRANCH" 2>/dev/null || true
  fi

  # Clear retry list after first iteration (only retry once)
  RETRY_ISSUES=""

  echo ""
  # Cooldown between iterations (avoids rate limit spikes)
  sleep "$ITERATION_COOLDOWN"
done

# ══════════════════════════════════════════════════════════════════════════════
# ── Post-loop: Backpressure, Summary, Notifications ──────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

# Return to main branch
cd "$REPO"
git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true

# ── Backpressure signal ──────────────────────────────────────────────────────
BACKLOG_FLAG="$OUTPUT_DIR/.lift-backlog-low"
UNSTARTED_COUNT=$(bash "$TRACKER" list unstarted | grep -c "${LINEAR_TEAM}-" || echo "0")
UNSTARTED_COUNT=$(echo "$UNSTARTED_COUNT" | tr -d ' \n')
if [ "$UNSTARTED_COUNT" -lt 3 ] 2>/dev/null; then
  touch "$BACKLOG_FLAG"
  echo "📉 Backlog low ($UNSTARTED_COUNT unstarted) — signaling discovery to run extra session"
  thread_send "📉 Backlog low ($UNSTARTED_COUNT unstarted) — discovery will run extra session"
elif [ "$UNSTARTED_COUNT" -ge 5 ] 2>/dev/null; then
  rm -f "$BACKLOG_FLAG"
fi

# ── Final summary ────────────────────────────────────────────────────────────
BUILDER_END=$(date +%s)
BUILDER_RUNTIME=$((BUILDER_END - BUILDER_START))
BUILDER_RUNTIME_MIN=$((BUILDER_RUNTIME / 60))
echo ""
echo "━━━ Overnight session complete ━━━"
echo "Total iterations: $RUN | Runtime: ${BUILDER_RUNTIME_MIN}m | PRs created: $NIGHTLY_PR_COUNT"
echo "Logs: ls $OUTPUT_DIR/lift-enhance-$DATE-run*.md"

# Usage trends
USAGE_TRENDS=$(python3 -c "
import csv
from collections import defaultdict
nights = defaultdict(lambda: {'output': 0, 'iterations': 0})
try:
    with open('$USAGE_CSV') as f:
        reader = csv.DictReader(f)
        for row in reader:
            d = row['date']
            out = int(row.get('output_tokens', 0) or 0)
            nights[d]['output'] += out
            run = row.get('run', '0')
            if run.isdigit():
                nights[d]['iterations'] = max(nights[d]['iterations'], int(run))
    days = len(nights) or 1
    total_output = sum(n['output'] for n in nights.values())
    total_iters = sum(n['iterations'] for n in nights.values())
    avg_output = total_output // days
    avg_iters = total_iters // days
    print(f'{avg_output},{avg_iters},{days},{total_output}')
except Exception as e: print('0,0,0,0')
" 2>/dev/null)
AVG_OUTPUT=$(echo "$USAGE_TRENDS" | cut -d',' -f1)
AVG_ITERS=$(echo "$USAGE_TRENDS" | cut -d',' -f2)
TREND_DAYS=$(echo "$USAGE_TRENDS" | cut -d',' -f3)

# Count total commits and tests across all PRs tonight
FINAL_TESTS=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 || echo "unknown")
TOTAL_COMMITS=0
for pr_url in $NIGHTLY_PRS; do
  PR_BRANCH=$(echo "$pr_url" | grep -oE '[^/]+$' || true)
  if [ -n "$PR_BRANCH" ]; then
    BRANCH_COMMITS=$(git rev-list --count "origin/${DEFAULT_BRANCH:-master}..origin/$PR_BRANCH" 2>/dev/null || echo "0")
    TOTAL_COMMITS=$((TOTAL_COMMITS + BRANCH_COMMITS))
  fi
done
# Fallback: count from metrics
if [ "$TOTAL_COMMITS" -eq 0 ]; then
  TOTAL_COMMITS=$(awk -F',' -v d="$DATE" '$1==d && $6>0 {s+=$6} END {print s+0}' "$METRICS_FILE" 2>/dev/null || echo "0")
fi

LINEAR_DONE_COUNT=$(grep -rh '^LINEAR_DONE:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
LINEAR_PROGRESS_COUNT=$(grep -rh '^LINEAR_PROGRESS:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")

# Collect per-run summaries
RUN_SUMMARIES=""
for f in $(ls "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | sort -V); do
  RUN_NUM=$(basename "$f" | grep -oE 'run[0-9]+' | grep -oE '[0-9]+')
  PLAN=$(sed -n '/^## Plan/,/^## /p' "$f" 2>/dev/null | grep -v '^## ' | head -3)
  STATUS=$(grep -E '^(✅|❌|⚠️|🏁)' "$f" 2>/dev/null | tail -1 || true)
  if [ -n "$PLAN" ] || [ -n "$STATUS" ]; then
    RUN_SUMMARIES+="
*Run $RUN_NUM:* $STATUS
$PLAN
"
  fi
done

# Build morning digest
DIGEST="$OUTPUT_DIR/lift-digest-$DATE.md"
cat > "$DIGEST" <<DIGEST_EOF
# $PROJECT_NAME Overnight Digest — $DATE

## At a Glance
- **Iterations:** $RUN
- **PRs created:** $NIGHTLY_PR_COUNT
- **Runtime:** ${BUILDER_RUNTIME_MIN}m
- **Total commits:** $TOTAL_COMMITS
- **Tests:** $FINAL_TESTS
- **Linear issues closed:** $LINEAR_DONE_COUNT
- **Linear issues in progress:** $LINEAR_PROGRESS_COUNT
- **Output tokens tonight:** ${NIGHTLY_OUTPUT_TOKENS} / ${MAX_OUTPUT_TOKENS_PER_NIGHT} cap
- **Avg per night:** ${AVG_OUTPUT} output tokens, ${AVG_ITERS} iterations (over $TREND_DAYS nights)

## PRs
$(for pr_url in $NIGHTLY_PRS; do echo "- $pr_url"; done)

## Linear Board
https://linear.app/$LINEAR_ORG → $LINEAR_PROJECT project

## Run-by-Run
$RUN_SUMMARIES

## Next Steps
Review PRs on GitHub, spot-check preview deploys on your phone, approve and merge.
DIGEST_EOF

echo "📋 Morning digest saved to: $DIGEST"

# Collect all issues closed/progressed tonight
ALL_DONE_LINKS=$(python3 -c "
import re, os
output_dir = '$OUTPUT_DIR'
date = '$DATE'
team = '${LINEAR_TEAM}'
org = '${LINEAR_ORG}'

import glob
done_items = {}
progress_items = {}
for f in sorted(glob.glob(f'{output_dir}/lift-enhance-{date}-run*.md')):
    with open(f) as fh:
        content = fh.read()
    for m in re.finditer(r'LINEAR_DONE:(' + team + r'-\d+)\|(.+)', content):
        done_items[m.group(1)] = m.group(2).strip()[:100]
    for m in re.finditer(r'LINEAR_PROGRESS:(' + team + r'-\d+)\|(.+)', content):
        progress_items[m.group(1)] = m.group(2).strip()[:100]

lines = []
if done_items:
    lines.append('*Closed:*')
    for iid, summary in done_items.items():
        url = f'https://linear.app/{org}/issue/{iid}'
        lines.append(f'  ✅ <{url}|{iid}>: {summary}')
if progress_items:
    lines.append('*In Progress:*')
    for iid, summary in progress_items.items():
        url = f'https://linear.app/{org}/issue/{iid}'
        lines.append(f'  🔄 <{url}|{iid}>: {summary}')
print('\n'.join(lines) if lines else '  (no issue updates)')
" 2>/dev/null)

# PR links for Slack
PR_LINKS=""
for pr_url in $NIGHTLY_PRS; do
  PR_LINKS+="  • <$pr_url|$(basename "$pr_url")>
"
done

# Categorize PRs by verdict for the summary
MERGE_PRS=""
REVIEW_PRS=""
for entry in $NIGHTLY_VERDICTS; do
  pr_url=$(echo "$entry" | cut -d'|' -f1)
  verdict=$(echo "$entry" | cut -d'|' -f2)
  title=$(echo "$entry" | cut -d'|' -f3- | tr '_' ' ')
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
  case "$verdict" in
    MERGE)        MERGE_PRS+="  ✅ <$pr_url|#$pr_num> $title
" ;;
    DO_NOT_MERGE) REVIEW_PRS+="  🚫 <$pr_url|#$pr_num> $title (DO NOT MERGE)
" ;;
    *)            REVIEW_PRS+="  ⚠️ <$pr_url|#$pr_num> $title (REVIEW)
" ;;
  esac
done

# Send completion summary to thread
thread_send "✅ *Build Complete — $DATE*

*Stats:* $RUN iterations | ${BUILDER_RUNTIME_MIN}m runtime | $TOTAL_COMMITS commits | $FINAL_TESTS
*Tokens:* ${NIGHTLY_OUTPUT_TOKENS} output (avg ${AVG_OUTPUT}/night over ${TREND_DAYS}d)

${MERGE_PRS:+*Ready to merge:*
$MERGE_PRS}${REVIEW_PRS:+*Needs review:*
$REVIEW_PRS}
${ALL_DONE_LINKS}

<https://linear.app/${LINEAR_ORG}|Linear Board>"

# Draft email summary
claude --dangerously-skip-permissions -p "Create a Gmail draft (do NOT send) to aschung212@gmail.com with subject '$PROJECT_NAME Overnight Digest — $DATE' and this body as text/plain. Use the gmail_create_draft tool. Do not add any extra commentary:

$PROJECT_NAME Overnight Digest — $DATE

Iterations: $RUN
PRs created: $NIGHTLY_PR_COUNT
Total commits: $TOTAL_COMMITS
Tests: $FINAL_TESTS
Linear issues closed: $LINEAR_DONE_COUNT
Linear issues in progress: $LINEAR_PROGRESS_COUNT

PRs:
$(for pr_url in $NIGHTLY_PRS; do echo "  $pr_url"; done)

Linear board: https://linear.app/$LINEAR_ORG

Run-by-run:
$RUN_SUMMARIES

Next: Review PRs on GitHub, spot-check preview deploys, approve and merge." --max-turns 5 2>&1 | tail -5

echo "✅ Notifications sent."

# Tuners now run independently on their own weekly schedule (Sunday via launchd).
# See com.aaron.pilot-tune-budget.plist and com.aaron.pilot-tune-reviews.plist.

# Cleanup: archive completed/canceled issues, deduplicate backlog
echo ""
echo "── Running cleanup ──"
CLEANUP_OUTPUT=$(bash "$SCRIPT_DIR/cleanup.sh" 2>&1 || echo "⚠️ Cleanup failed (non-fatal)")
echo "$CLEANUP_OUTPUT"
CLEANUP_ARCHIVED=$(echo "$CLEANUP_OUTPUT" | grep -oE '[0-9]+ archived' | head -1 || echo "0 archived")
thread_send "🧹 *Cleanup:* $CLEANUP_ARCHIVED
<https://linear.app/${LINEAR_ORG}|Linear Board>"
