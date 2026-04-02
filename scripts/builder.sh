#!/bin/bash
# Overnight Self-Improving Portfolio Enhancer for Lift app
# Loops until morning, each iteration finding and implementing new improvements.
#
# Usage:
#   ./lift-enhance-overnight.sh          # runs until 7:00 AM
#   ./lift-enhance-overnight.sh 06:00    # runs until 6:00 AM
#   ./lift-enhance-overnight.sh 1        # runs exactly 1 iteration
#
# Logs: ~/Documents/Claude/outputs/lift-enhance-<date>-run<N>.md

set -uo pipefail
# Note: not using -e (errexit) — individual command failures should not abort the loop.
# Failures are tracked via FAILURES counter and MAX_CONSECUTIVE_FAILURES.

# Source env vars when run by launchd (no login shell)
[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"

slack_send() {
  bash "$NOTIFY" send-async automation "$1"
}

REPO="${REPO_PATH:-/Users/aaron/development/lift}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
STOP_AT="${1:-07:00}"
RUN=0
MAX_CONSECUTIVE_FAILURES=3
FAILURES=0
MAX_STALLS=2
STALLS=0

mkdir -p "$OUTPUT_DIR"

# ── Usage tracking ───────────────────────────────────────────────────────────
BUDGET_CONF="$HOME/Documents/Scripts/lift-budget.conf"
[ -f "$BUDGET_CONF" ] && source "$BUDGET_CONF"
MAX_ITERATIONS_PER_NIGHT="${MAX_ITERATIONS_PER_NIGHT:-8}"
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

# Parse usage from Claude JSON output
parse_usage() {
  local json_file="$1"
  python3 -c "
import json
try:
    with open('$json_file') as f:
        data = json.load(f)
    usage = data.get('usage', {})
    inp = usage.get('input_tokens', 0)
    out = usage.get('output_tokens', 0)
    cache_read = usage.get('cache_read_input_tokens', 0)
    cache_create = usage.get('cache_creation_input_tokens', 0)
    print(f'{inp},{out},{cache_read},{cache_create}')
except:
    print('0,0,0,0')
" 2>/dev/null
}

usage_check() {
  # Check iteration cap
  if [ "$RUN" -ge "$MAX_ITERATIONS_PER_NIGHT" ]; then
    echo "🛑 Iteration cap reached ($RUN/$MAX_ITERATIONS_PER_NIGHT). Stopping."
    slack_send "🛑 *Overnight builder stopped — iteration cap*
$RUN/$MAX_ITERATIONS_PER_NIGHT iterations | ${NIGHTLY_OUTPUT_TOKENS} output tokens"
    return 1
  fi
  # Check token cap
  if [ "$NIGHTLY_OUTPUT_TOKENS" -ge "$MAX_OUTPUT_TOKENS_PER_NIGHT" ]; then
    echo "🛑 Token cap reached (${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens). Stopping."
    slack_send "🛑 *Overnight builder stopped — token cap*
${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens | $RUN iterations"
    return 1
  fi
  # Alert at threshold (once)
  if [ "$ALERT_SENT" = "false" ]; then
    local pct
    pct=$(python3 -c "print(int($NIGHTLY_OUTPUT_TOKENS / $MAX_OUTPUT_TOKENS_PER_NIGHT * 100))")
    if [ "$pct" -ge "$ALERT_THRESHOLD_PCT" ]; then
      slack_send "⚠️ *Overnight builder — ${pct}% of token cap*
${NIGHTLY_OUTPUT_TOKENS}/${MAX_OUTPUT_TOKENS_PER_NIGHT} output tokens | $RUN iterations"
      ALERT_SENT=true
    fi
  fi
  return 0
}

# If no CLI arg, use config default
if [ "$STOP_AT" = "07:00" ]; then
  STOP_AT="$DEFAULT_STOP_TIME"
fi

# If argument is a number, treat it as max iterations override
if [[ "$STOP_AT" =~ ^[0-9]+$ ]]; then
  MAX_ITERATIONS_PER_NIGHT="$STOP_AT"
  STOP_AT="23:59"
fi

should_continue() {
  # Check usage caps (iterations + tokens)
  if ! usage_check; then
    return 1
  fi
  # Check time — handles overnight runs (e.g. start at 21:00, stop at 07:00)
  local now_mins stop_mins
  now_mins=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  stop_mins=$(( 10#${STOP_AT%%:*} * 60 + 10#${STOP_AT##*:} ))
  # If stop time is in the morning (before noon) and we started in the evening,
  # we only stop once we're past midnight AND past the stop time
  if [ "$stop_mins" -lt 720 ]; then
    # Overnight mode: stop only if current time is after midnight and past stop time
    if [ "$now_mins" -ge "$stop_mins" ] && [ "$now_mins" -lt 720 ]; then
      echo "Past stop time ($STOP_AT). Stopping."
      return 1
    fi
  else
    # Same-day mode: stop if current time is past stop time
    if [ "$now_mins" -ge "$stop_mins" ]; then
      echo "Past stop time ($STOP_AT). Stopping."
      return 1
    fi
  fi
  # Check consecutive failures
  if [ "$FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    echo "$MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping."
    return 1
  fi
  # Check stagnation (no new commits produced)
  if [ "$STALLS" -ge "$MAX_STALLS" ]; then
    echo "$MAX_STALLS consecutive iterations with no new commits. Nothing left to improve. Stopping."
    return 1
  fi
  return 0
}

# Use a git worktree so the builder never touches Aaron's working directory.
# The main repo at $REPO stays on whatever branch Aaron is using.
# The builder works in $REPO-builder (a separate checkout of the same repo).
WORKTREE_DIR="${REPO}-builder"

cd "$REPO"
git fetch origin 2>/dev/null || true

# Determine which branch to work on
EXISTING_BRANCH=$(git branch --list 'enhance/portfolio-improvements-*' | sed 's/^[* ]*//' | tail -1)
BRANCH=""
if [ -n "$EXISTING_BRANCH" ]; then
  PR_STATE=$(gh pr view "$EXISTING_BRANCH" --json state -q .state 2>/dev/null || echo "NONE")
  if [ "$PR_STATE" = "OPEN" ] || [ "$PR_STATE" = "NONE" ]; then
    BRANCH="$EXISTING_BRANCH"
  else
    # PR was merged or closed — clean up old branch
    git branch -d "$EXISTING_BRANCH" 2>/dev/null || true
  fi
fi
if [ -z "$BRANCH" ]; then
  BRANCH="enhance/portfolio-improvements-$DATE"
  # Create the branch from latest master (without checking it out here)
  git fetch origin master 2>/dev/null || true
  git branch "$BRANCH" origin/master 2>/dev/null || true
fi

# Set up or reuse the worktree
if [ -d "$WORKTREE_DIR" ]; then
  # Worktree exists — make sure it's on the right branch
  cd "$WORKTREE_DIR"
  CURRENT=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$CURRENT" != "$BRANCH" ]; then
    git checkout "$BRANCH" 2>/dev/null || true
  fi
  git pull --ff-only origin "$BRANCH" 2>/dev/null || true
else
  # Create worktree — if the branch is checked out in the main repo, detach it first
  MAIN_CURRENT=$(cd "$REPO" && git branch --show-current 2>/dev/null || echo "")
  if [ "$MAIN_CURRENT" = "$BRANCH" ]; then
    echo "  ℹ️  Branch $BRANCH is checked out in main repo — detaching to free it for worktree."
    cd "$REPO" && git checkout --detach 2>/dev/null || true
  fi

  git worktree add "$WORKTREE_DIR" "$BRANCH" 2>&1 || {
    echo "  ⚠️ Failed to create worktree. Falling back to main repo."
    WORKTREE_DIR="$REPO"
    cd "$REPO"
    git checkout "$BRANCH" 2>/dev/null || true
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
echo "🏋️ Starting overnight enhancer at $(date)"
echo "   Stop time: $STOP_AT | Branch: $BRANCH | Worktree: $REPO"
echo ""

# Metrics tracking
METRICS_FILE="$OUTPUT_DIR/lift-metrics.csv"
if [ ! -f "$METRICS_FILE" ]; then
  echo "date,run,start_time,end_time,duration_sec,commits,tests_before,tests_after,tests_delta,issues_done,issues_skipped,issues_created,build_size_kb,success" > "$METRICS_FILE"
fi

while should_continue; do
  RUN=$((RUN + 1))
  RUN_LOG="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}.md"

  # Snapshot state before this iteration
  COMMITS_BEFORE=$(git rev-list --count HEAD)
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
  # Only pick from Unstarted (triaged + approved) and Started issues — skip raw Backlog
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


  # Linear updates happen after each iteration completes (Done/Blocked)
  CLAUDE_JSON="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}-output.json"
  if claude --dangerously-skip-permissions --output-format json -p "$(cat <<PROMPT
You are iteration $RUN of the overnight self-improving enhancer for the Lift workout tracker at $REPO. This is Aaron Chung's portfolio project — he's an ex-AWS SDE2 targeting SWE roles at companies like Notion, Airtable, and Linear.

You are running in a loop. Previous iterations tonight and from recent days have already made improvements. Your job is to find the NEXT most impactful thing to do that hasn't been done yet.

## Current repo state

Recent commits:
$GIT_LOG

Current test output:
$TEST_COUNT

## What previous iterations accomplished

$PREVIOUS_SUMMARIES

## Linear backlog (open issues for the Lift project)

$LINEAR_ISSUES

## Issue details (descriptions + comments — may include triage agent suggestions as a STARTING POINT — read the codebase and use your own judgment; deviate from suggestions if you find a better approach)

$ISSUE_DETAILS

## Issues skipped earlier tonight (do NOT retry these)

${SKIPPED_ISSUES:-None}

## Your job (this iteration)

1. **Read the repo** — look at what exists NOW (code, tests, config, README, etc.)
2. **Check the Linear backlog above** — you MUST pick work that maps to a Linear issue whenever possible. Match broadly: if you are writing tests, that maps to MAS-191. If you improve accessibility, find the closest issue. If you identify valuable work that has NO matching Linear issue, output a line to create one (see output format below), then proceed with the work.
3. **Cross-reference** with what previous iterations already did (below)
4. **Pick 1-3 focused improvements** that would have the most impact for a portfolio review
5. **Implement them**, committing after each with a conventional commit message
6. **Verify** tests pass and build succeeds

If no Linear issues match, refer to the improvement categories in CLAUDE.md.

## Discovery (every iteration)

While reading the codebase, actively look for problems and improvement opportunities. For each discovery, output a LINEAR_CREATE line (see output format). Look for:
- UI bugs (contrast issues, layout shifts, broken themes, missing aria attributes)
- Code smells (dead code, unused imports, inconsistent patterns, TODO comments)
- Missing tests for critical paths
- Performance issues (large bundles, unnecessary re-renders, unoptimized images)
- Accessibility violations (missing labels, low contrast, keyboard traps)
- CLAUDE.md checklist violations (hardcoded colors, wrong spacing, missing safe-area-inset)
- Dependency vulnerabilities (check package.json for outdated or insecure deps)

Do NOT fix discoveries in the same iteration — just create the Linear issue. Fix them in a future iteration when they are the highest priority.

## Rules

- Do NOT redo work from previous iterations — if tests exist, don't rewrite them
- Do NOT break existing functionality — run tests after each change
- Quality over quantity — 1 excellent improvement beats 3 mediocre ones
- If you cannot find anything meaningful to improve, output ONLY the line "NO_IMPROVEMENTS_REMAINING" and exit
- Commit with clear conventional commit messages
- If a test is failing when you start, you may try to fix it ONCE. If it still fails after one attempt, skip it and move on to new work. Do not spend more than 10 turns on any single fix.
- IMPORTANT: Focus on SHIPPING, not perfecting. Commit working improvements and move on.

## Output format

## Plan
What you chose and why (1-3 sentences)

## Changes
What you did (bullet points)

## Linear updates
CRITICAL: You MUST output Linear status lines for every issue you worked on. Every iteration should have at least one. Output each on its own line with NO leading whitespace.

For existing issues, use a pipe-separated format with a summary of what was done and any design decisions:
LINEAR_DONE:MAS-XXX|Brief summary of implementation and any notable decisions (e.g. "Added tag manager modal with inline rename/delete. Used expandable rows instead of a separate screen to stay consistent with iOS progressive disclosure pattern.")
LINEAR_PROGRESS:MAS-XXX|What was completed so far and what remains
LINEAR_SKIPPED:MAS-XXX:reason (if you attempted an issue but could not complete it)

If you did work that has no matching Linear issue, create one:
LINEAR_CREATE:priority:title
Then also output LINEAR_DONE or LINEAR_PROGRESS for it (use the title to track it — the script will link them).

For discoveries you found but did NOT fix this iteration (just logging for future work):
LINEAR_DISCOVER:priority:title
Priority is 1-4 (1=urgent, 2=high, 3=medium, 4=low). Example:
LINEAR_DISCOVER:3:Settings modal missing safe-area-inset-bottom padding

Do not fabricate existing issue IDs — only use IDs from the backlog above.

## Summary
- Tests: X passing
- Build: pass/fail
- What to tackle next iteration: (suggestion for the next run)
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
      slack_send "🚨 *Builder Run $RUN — Claude issue*
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
      else
        STALLS=0
        echo "✅ Run $RUN finished at $(date) — $NEW_COMMITS new commit(s)" | tee -a "$RUN_LOG"
        git push -u origin "$BRANCH" 2>&1 | tee -a "$RUN_LOG"

        # Create new issues for discovered problems (backlog, not done)
        { grep -oE 'LINEAR_DISCOVER:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  📋 Discovered issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" 2>&1 | tee -a "$RUN_LOG"
        done

        # Create new issues for work not in the backlog (already done)
        { grep -oE 'LINEAR_CREATE:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  Creating issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" --state "Done" 2>&1 | tee -a "$RUN_LOG"
        done

        # Handle skipped issues — move to Blocked with a comment explaining why
        { grep -oE "LINEAR_SKIPPED:${LINEAR_TEAM}-[0-9]+:[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ _ issue_id reason; do
          echo "  Blocking $issue_id: $reason" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "Blocked" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "Automated run blocked this issue on $DATE: $reason" 2>&1 | tee -a "$RUN_LOG"
        done

        # Get the latest commit hash and build GitHub link
        LATEST_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        COMMIT_URL="https://github.com/$GITHUB_REPO/commit/$LATEST_COMMIT"

        # Update issues based on Claude's output (flexible matching)
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
        # Slack notification with iteration results
        # Extract done/blocked with titles for Slack links
        DONE_LINKS=$({ grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+\|[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS='|' read -r marker summary; do
          id=$(echo "$marker" | sed 's/LINEAR_DONE://')
          title=$(echo "$summary" | head -c 80)
          url=$(bash "$TRACKER" issue-url "$id")
          [ -n "$id" ] && echo "  • <${url}|$id: ${title:-no description}>"
        done)
        BLOCKED_LINKS=$({ grep -oE "LINEAR_SKIPPED:${LINEAR_TEAM}-[0-9]+:[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ _ id reason; do
          url=$(bash "$TRACKER" issue-url "$id")
          [ -n "$id" ] && echo "  • <${url}|$id: ${reason:-no reason}>"
        done)
        DONE_LIST=$({ grep -oE "LINEAR_DONE:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null || true; } | sed 's/LINEAR_DONE://' | sort -u)
        BLOCKED_LIST=$({ grep -oE "LINEAR_SKIPPED:${LINEAR_TEAM}-[0-9]+" "$RUN_LOG" 2>/dev/null || true; } | sed 's/LINEAR_SKIPPED://' | sed 's/:.*//' | sort -u)
        PLAN=$({ grep -A3 '^## Plan' "$RUN_LOG" 2>/dev/null || true; } | grep -v '^## Plan' | head -2 | tr '\n' ' ')
        SLACK_MSG="*$PROJECT_NAME Run $RUN complete* — $NEW_COMMITS commit(s)
${PLAN}
${DONE_LINKS:+*Done:*
$DONE_LINKS}${BLOCKED_LINKS:+
*Blocked:*
$BLOCKED_LINKS}"
        slack_send "$SLACK_MSG"

        # Collect metrics for this iteration
        ITER_END=$(date +%s)
        ITER_DURATION=$((ITER_END - ITER_START))
        TESTS_AFTER=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo "0")
        TESTS_DELTA=$((TESTS_AFTER - TESTS_BEFORE))
        DONE_COUNT=$(echo "$DONE_LIST" | grep -c 'MAS' || echo "0")
        SKIPPED_COUNT=$(echo "$BLOCKED_LIST" | grep -c 'MAS' || echo "0")
        CREATED_COUNT=$({ grep -oE 'LINEAR_CREATE:[1-4]:' "$RUN_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')
        BUILD_SIZE=$(cd "$REPO" && npm run build 2>&1 | grep -oE '[0-9]+\.[0-9]+ KiB' | head -1 | grep -oE '[0-9.]+' || echo "")
        echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,$NEW_COMMITS,$TESTS_BEFORE,$TESTS_AFTER,$TESTS_DELTA,$DONE_COUNT,$SKIPPED_COUNT,$CREATED_COUNT,$BUILD_SIZE,true" >> "$METRICS_FILE"
      fi
    fi
  else
    FAILURES=$((FAILURES + 1))
    echo "❌ Run $RUN failed at $(date) (failure $FAILURES/$MAX_CONSECUTIVE_FAILURES)" | tee -a "$RUN_LOG"
    # Log failed iteration metrics
    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))
    echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,,false" >> "$METRICS_FILE"
  fi

  echo ""
  # Cooldown between iterations (avoids rate limit spikes)
  sleep "$ITERATION_COOLDOWN"
done

# Final summary
BUILDER_END=$(date +%s)
BUILDER_RUNTIME=$((BUILDER_END - BUILDER_START))
BUILDER_RUNTIME_MIN=$((BUILDER_RUNTIME / 60))
echo ""
echo "━━━ Overnight session complete ━━━"
echo "Total iterations: $RUN | Runtime: ${BUILDER_RUNTIME_MIN}m"
echo "Branch: $BRANCH"
echo "Review: cd $REPO && git log --oneline origin/${DEFAULT_BRANCH:-master}..$BRANCH"
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

# Build morning digest
TOTAL_COMMITS=$(git rev-list --count origin/${DEFAULT_BRANCH:-master}.."$BRANCH" 2>/dev/null || echo "?")
FINAL_TESTS=$(cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 || echo "unknown")
LINEAR_DONE_COUNT=$(grep -rh '^LINEAR_DONE:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
LINEAR_PROGRESS_COUNT=$(grep -rh '^LINEAR_PROGRESS:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
# Ensure a PR exists for the branch (may not if this is a fresh branch)
if ! gh pr view "$BRANCH" --json url -q .url >/dev/null 2>&1; then
  if [ "$TOTAL_COMMITS" != "?" ] && [ "$TOTAL_COMMITS" -gt 0 ] 2>/dev/null; then
    echo "  Creating PR..."
    gh pr create --base master --head "$BRANCH" \
      --title "Overnight improvements — $DATE" \
      --body "Automated overnight session: $RUN iterations, $TOTAL_COMMITS commits, $LINEAR_DONE_COUNT issues closed.

Review summaries will be posted as comments by the automated review pipeline." 2>&1 || true
  fi
fi
PR_URL=$(cd "$REPO" && gh pr view "$BRANCH" --json url -q .url 2>/dev/null || echo "https://github.com/$GITHUB_REPO/pull/new/$BRANCH")

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

DIGEST="$OUTPUT_DIR/lift-digest-$DATE.md"
cat > "$DIGEST" <<DIGEST_EOF
# Lift Overnight Digest — $DATE

## At a Glance
- **Iterations:** $RUN
- **Runtime:** ${BUILDER_RUNTIME_MIN}m
- **Commits:** $TOTAL_COMMITS
- **Tests:** $FINAL_TESTS
- **Linear issues closed:** $LINEAR_DONE_COUNT
- **Linear issues in progress:** $LINEAR_PROGRESS_COUNT
- **Output tokens tonight:** ${NIGHTLY_OUTPUT_TOKENS} / ${MAX_OUTPUT_TOKENS_PER_NIGHT} cap
- **Avg per night:** ${AVG_OUTPUT} output tokens, ${AVG_ITERS} iterations (over $TREND_DAYS nights)

## Review
- **PR:** $PR_URL
- **Linear:** https://linear.app/$LINEAR_ORG → $LINEAR_PROJECT project
- **Logs:** ~/Documents/Claude/outputs/lift-enhance-$DATE-run*.md

## Run-by-Run
$RUN_SUMMARIES

## Next Steps
Review the PR on GitHub, test locally with \`npm run dev\`, merge when satisfied.
DIGEST_EOF

echo "📋 Morning digest saved to: $DIGEST"

# Send Slack notification
slack_send "🏋️ *Lift Overnight Build Complete*

Iterations: $RUN/$MAX_ITERATIONS_PER_NIGHT | Runtime: ${BUILDER_RUNTIME_MIN}m | Commits: $TOTAL_COMMITS | Tests: $FINAL_TESTS
Linear: $LINEAR_DONE_COUNT closed, $LINEAR_PROGRESS_COUNT in progress
📊 Tokens: ${NIGHTLY_OUTPUT_TOKENS} output tonight (avg ${AVG_OUTPUT}/night over ${TREND_DAYS}d)
PR: $PR_URL"

# ── Automated PR Review (2 layers) ──────────────────────────────────────────
# Only review if there are actual commits to review
if [ "$TOTAL_COMMITS" != "?" ] && [ "$TOTAL_COMMITS" -gt 0 ] 2>/dev/null; then
  echo ""
  echo "── Running automated PR reviews ──"

  # PR was already created above — just grab the number
  PR_NUMBER=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null || echo "")

  # Get the full diff for review
  DIFF=$(git diff origin/${DEFAULT_BRANCH:-master}.."$BRANCH" 2>/dev/null | head -5000)
  COMMIT_LOG=$(git log --oneline origin/${DEFAULT_BRANCH:-master}.."$BRANCH" 2>/dev/null)

  # Load reviewer learnings (self-improving context)
  REVIEW_LEARNINGS=$(cat "$OUTPUT_DIR/lift-review-learnings.md" 2>/dev/null || echo "No learnings yet.")

  # ── Layer 1: Claude adversarial review ──────────────────────────────────
  echo "  🔍 Layer 1: Claude adversarial review..."
  REVIEW_JSON="$OUTPUT_DIR/lift-review-claude-$DATE.json"
  CLAUDE_REVIEW_PROMPT_FILE=$(mktemp)
  cat > "$CLAUDE_REVIEW_PROMPT_FILE" <<REVIEW_PROMPT
You are a senior engineer doing an adversarial code review. Your job is to find problems, not to praise. Be specific and actionable.

Review this overnight PR for the Lift workout tracker (Vue 3 + TypeScript PWA).

## Commits
$COMMIT_LOG

## Diff (truncated to 5000 lines)
$DIFF

## Review Checklist
1. Bugs — logic errors, off-by-ones, null/undefined risks, race conditions
2. Security — XSS, injection, auth issues, exposed secrets, CSP violations
3. Performance — unnecessary re-renders, large bundle imports, missing lazy loading, N+1 queries
4. iOS/PWA — missing safe-area handling, touch target sizes, offline behavior
5. Accessibility — missing aria labels, contrast issues, keyboard navigation
6. Design consistency — does it follow iOS HIG? Hardcoded colors/sizes instead of tokens?
7. Test coverage — are new features tested? Are edge cases covered?

Start with a severity summary for each category. Then list specific findings with file:line references. End with a GO/NO-GO recommendation.

## Learnings from past reviews
$REVIEW_LEARNINGS
REVIEW_PROMPT
  if claude --dangerously-skip-permissions --output-format json --model sonnet -p "$(cat "$CLAUDE_REVIEW_PROMPT_FILE")" --max-turns 5 2>&1 > "$REVIEW_JSON"; then
    CLAUDE_REVIEW=$(python3 -c "
import json
try:
    with open('$REVIEW_JSON') as f:
        data = json.load(f)
    print(data.get('result', 'Review failed to produce output.'))
except: print('Review failed to parse.')
" 2>/dev/null)
    echo "  ✅ Claude review complete"

    # Post to PR as comment
    if [ -n "$PR_NUMBER" ]; then
      gh pr comment "$PR_NUMBER" --body "## 🔍 Automated Review — Layer 1: Claude Sonnet (Adversarial)

$CLAUDE_REVIEW

---
_Automated review by overnight pipeline — $(date) — model: claude-sonnet-4-6_" 2>&1 || echo "  ⚠️ Failed to post Claude review to PR"
    fi
  else
    echo "  ⚠️ Claude review failed"
    CLAUDE_REVIEW="Review failed."
  fi
  rm -f "$CLAUDE_REVIEW_PROMPT_FILE"

  # ── Layer 2: Gemini review via CLI ──────────────────────────────────────
  echo "  🔍 Layer 2: Gemini review (via Gemini CLI)..."
  GEMINI_REVIEW_FILE="$OUTPUT_DIR/lift-review-gemini-$DATE.md"
  GEMINI_PROMPT_FILE=$(mktemp)
  cat > "$GEMINI_PROMPT_FILE" <<GEMINI_PROMPT
You are a senior engineer reviewing a pull request. Focus on areas a DIFFERENT reviewer might miss:

1. **Architecture** — are the changes cohesive? Do they follow Vue 3 composition API best practices?
2. **User experience** — will these changes feel right to an end user on mobile (iOS PWA)?
3. **Edge cases** the original developer likely didn't consider
4. **Dependency/upgrade risks** — any packages outdated or risky?
5. **What's MISSING** — what should have been included but wasn't?

## Commits
$COMMIT_LOG

## Diff (truncated to 5000 lines)
$DIFF

Output a structured review with specific findings and file:line references where possible. End with a confidence score (1-10) for merging safely.

## Learnings from past reviews (PAY ATTENTION — these are real patterns)
$REVIEW_LEARNINGS
GEMINI_PROMPT

  # Gemini Flash review (fast, strong on coding benchmarks, no quota issues)
  GEMINI_MODEL="gemini-2.5-flash"
  gemini -p "$(cat "$GEMINI_PROMPT_FILE")" -m "$GEMINI_MODEL" --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt" > "$GEMINI_REVIEW_FILE" 2>/dev/null || true
  echo "  Used model: $GEMINI_MODEL"
  if [ -s "$GEMINI_REVIEW_FILE" ] && ! grep -q "exhausted your capacity" "$GEMINI_REVIEW_FILE" 2>/dev/null; then
    GEMINI_REVIEW=$(cat "$GEMINI_REVIEW_FILE")
    echo "  ✅ Gemini review complete"

    # Post to PR as comment
    if [ -n "$PR_NUMBER" ] && [ -n "$GEMINI_REVIEW" ]; then
      gh pr comment "$PR_NUMBER" --body "## 🔍 Automated Review — Layer 2: Gemini $GEMINI_MODEL (Architecture & UX)

$GEMINI_REVIEW

---
_Automated review by overnight pipeline — $(date) — model: ${GEMINI_MODEL}_" 2>&1 || echo "  ⚠️ Failed to post Gemini review to PR"
    fi
  else
    echo "  ⚠️ Gemini review failed"
    GEMINI_REVIEW="Review failed."
  fi
  rm -f "$GEMINI_PROMPT_FILE"

  # Notify Slack that reviews are posted
  slack_send "🔍 *PR Reviews Posted*
Layer 1 (Claude adversarial) + Layer 2 (Gemini architecture/UX) posted to PR.
$PR_URL"

  # Append reviews to morning digest
  cat >> "$DIGEST" <<REVIEW_EOF

## Automated Reviews

### Layer 1: Claude (Adversarial)
$CLAUDE_REVIEW

### Layer 2: Gemini (Architecture & UX)
$GEMINI_REVIEW
REVIEW_EOF

else
  echo "  No commits to review — skipping automated reviews."
fi

# Draft email summary
claude --dangerously-skip-permissions -p "Create a Gmail draft (do NOT send) to aschung212@gmail.com with subject 'Lift Overnight Digest — $DATE' and this body as text/plain. Use the gmail_create_draft tool. Do not add any extra commentary:

Lift Overnight Digest — $DATE

Iterations: $RUN
Commits: $TOTAL_COMMITS
Tests: $FINAL_TESTS
Linear issues closed: $LINEAR_DONE_COUNT
Linear issues in progress: $LINEAR_PROGRESS_COUNT

Review PR: $PR_URL
Linear board: https://linear.app/$LINEAR_ORG

Run-by-run:
$RUN_SUMMARIES

Next: Review the PR on GitHub, test locally, merge when satisfied." --max-turns 5 2>&1 | tail -5

echo "✅ Notifications sent."

# Tuners now run independently on their own weekly schedule (Sunday via launchd).
# See com.aaron.pilot-tune-budget.plist and com.aaron.pilot-tune-reviews.plist.

# Cleanup: archive completed/canceled issues, deduplicate backlog
echo ""
echo "── Running cleanup ──"
bash "$SCRIPT_DIR/cleanup.sh" 2>&1 || echo "⚠️ Cleanup failed (non-fatal)"
