#!/bin/bash
# Overnight Self-Improving Portfolio Enhancer for Lift app
# Each iteration picks one issue, creates a branch, implements, reviews, and opens a PR.
#
# Usage:
#   ./builder.sh          # runs until 7:00 AM
#   ./builder.sh 06:00    # runs until 6:00 AM
#   ./builder.sh 1        # runs exactly 1 iteration
#
# Env overrides:
#   PICKED_ISSUE_OVERRIDE=LIFT-NNN   # force a specific issue, skip the pre-pick stage
#                                    # (intended for one-off manual runs; ignored when empty)
#
# Logs: pilot/data/lift-enhance-<date>-run<N>.md

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

# Builder tool allowlist — restricts Claude to repo-scoped operations only.
# Blocks arbitrary shell, curl, env var exfil, and network access beyond git/gh.
# This is the primary defense against indirect prompt injection from web research.
# Note: git push is allowed but the security scan runs before any push in the loop.
BUILDER_ALLOWED_TOOLS="Read,Edit,Write,Glob,Grep,Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git checkout:*),Bash(git branch:*),Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git fetch:*),Bash(git merge:*),Bash(git stash:*),Bash(git show:*),Bash(git rev-parse:*),Bash(git config user:*),Bash(gh:*),Bash(npm run build:*),Bash(npm run lint:*),Bash(npm run typecheck:*),Bash(npm test:*),Bash(npx vitest:*),Bash(npm run dev:*),Bash(npm ci:*),Bash(npm install:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(mkdir:*),Bash(cp:*),Bash(mv:*)"

# Builder DISALLOWED tools — explicitly deny subagent invocation so Claude does
# the work in its own session and emits ISSUE_DONE markers in its final message.
# Origin: 2026-04-30 Auditor finding — 57% of runs in the prior week showed parent
# num_turns=1 with output_tokens<100, real work hiding in modelUsage (Haiku 5–10K
# tokens per run). Even though Task wasn't in --allowedTools, Claude was clearly
# delegating somehow; --disallowedTools makes it explicit.
#
# Also blocks `gh pr create` so Claude can't create the PR itself and bypass the
# script's pre-PR dedupe guard. The 2026-05-07 run produced PR #515 and #517 for
# issue #501 because Claude (despite the prompt saying not to) ran `gh pr create`
# inside its own session, which beat the script's guard. The script must be the
# only entity that opens PRs in this pipeline.
BUILDER_DISALLOWED_TOOLS="Task,Agent,WebFetch,WebSearch,Bash(gh pr create:*)"

REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
STOP_AT="${1:-07:00}"
RUN=0
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
FAILURES=0
MAX_STALLS="${MAX_STALLS:-2}"
STALLS=0
MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-1}"

# WIP limit: stop building new work when this many PRs are already open and
# waiting on Aaron (0 disables). See wip_gate_active in lib/builder-utils.sh.
MAX_OPEN_PRS="${MAX_OPEN_PRS:-8}"

# Wall-clock timeouts (seconds) for the builder's `claude` calls. A hung call
# with no timeout silently blocked the launchd builder for 5 days (2026-07-09),
# because StartCalendarInterval skips scheduled runs while a prior instance is
# still alive. run_with_timeout kills the process tree on expiry so the night
# finishes and launchd is free to start the next run. Defaults are generous — a
# healthy iteration runs ~5-12 min — so they only fire on a genuine hang.
# Override in project.env. Set to 0 to disable a given timeout.
BUILDER_ITERATION_TIMEOUT="${BUILDER_ITERATION_TIMEOUT:-3600}"  # main implement+review+push call
BUILDER_FIX_TIMEOUT="${BUILDER_FIX_TIMEOUT:-1800}"              # CI-fix / merge-conflict retry calls
BUILDER_PREPICK_TIMEOUT="${BUILDER_PREPICK_TIMEOUT:-300}"       # cheap issue pre-pick call
BUILDER_AUTH_TIMEOUT="${BUILDER_AUTH_TIMEOUT:-180}"             # auth preflight probe

mkdir -p "$OUTPUT_DIR"

# ── Usage tracking ───────────────────────────────────────────────────────────
BUDGET_CONF="$SCRIPT_DIR/../config/budget.conf"
[ -f "$BUDGET_CONF" ] && source "$BUDGET_CONF"
MAX_ITERATIONS_PER_NIGHT="${MAX_ITERATIONS_PER_NIGHT:-12}"
MAX_OUTPUT_TOKENS_PER_NIGHT="${MAX_OUTPUT_TOKENS_PER_NIGHT:-500000}"
ITERATION_COOLDOWN="${ITERATION_COOLDOWN:-30}"
ALERT_THRESHOLD_PCT="${ALERT_THRESHOLD_PCT:-80}"
DEFAULT_STOP_TIME="${DEFAULT_STOP_TIME:-07:00}"

# Per-agent turn caps (from project.env; safe fallbacks if unset)
BUILDER_MAX_TURNS="${BUILDER_MAX_TURNS:-100}"
BUILDER_FIX_MAX_TURNS="${BUILDER_FIX_MAX_TURNS:-30}"
BUILDER_PREPICK_MAX_TURNS="${BUILDER_PREPICK_MAX_TURNS:-2}"

# Commit co-author trailer — derived from the configured model so attribution
# stays a single source of truth (project.env's AI_CODE_MODEL). Without an
# explicit instruction the builder self-reports a stale version in the trailer
# (it identifies as its training-cutoff model, historically "Opus 4.6",
# regardless of the --model flag in use), producing inconsistent attribution.
CODE_MODEL="${AI_CODE_MODEL:-claude-opus-4-8[1m]}"
COAUTHOR_TRAILER="Co-Authored-By: $(model_display_name "$CODE_MODEL") <noreply@anthropic.com>"

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
  echo "date,run,start_time,end_time,duration_sec,commits,tests_before,tests_after,tests_delta,issues_done,issues_skipped,issues_created,stalls,build_size_kb,success" > "$METRICS_FILE"
fi

# Track PRs created tonight
NIGHTLY_PRS=""
NIGHTLY_PR_COUNT=0

# Track issues already attempted tonight — even when Claude doesn't emit
# ISSUE_DONE markers, so the next iteration won't pick the same issue.
NIGHTLY_ATTEMPTED_ISSUES=""

# ── Check for failed PRs from previous nights to retry ──────────────────────
FAILED_PRS=$(cd "$REPO" && gh pr list --author "@me" --label "ci:failed" --json number,headRefName,title -q '.[].headRefName' 2>/dev/null || echo "")
RETRY_ISSUES=""
if [ -n "$FAILED_PRS" ]; then
  for failed_branch in $FAILED_PRS; do
    # Extract issue ID from branch name (enhance/LIFT-123-2026-04-02)
    FAILED_ISSUE=$(echo "$failed_branch" | grep -oE "${ISSUE_PREFIX}-[0-9]+" || true)
    if [ -n "$FAILED_ISSUE" ]; then
      RETRY_ISSUES+="$FAILED_ISSUE "
      # Close the old failed PR
      gh pr close "$failed_branch" --delete-branch 2>/dev/null || true
      echo "  🔄 Closed failed PR for $FAILED_ISSUE — will retry"
    fi
  done
fi

# ── Rejection learnings ─────────────────────────────────────────────────────
# cleanup.sh harvests the closing comments from PRs Aaron closed WITHOUT merging
# into data/lift-build-learnings.md. Feeding the most recent entries into every
# iteration's prompt closes the human-feedback loop that died when the review
# tuner was removed (2026-05-11): merge/reject decisions were the one signal
# nothing in the pipeline learned from. tail keeps the newest entries (the file
# is append-only) and caps prompt cost.
BUILD_LEARNINGS=$(tail -c 4000 "$OUTPUT_DIR/lift-build-learnings.md" 2>/dev/null || true)

# ══════════════════════════════════════════════════════════════════════════════
# ── Auth preflight: fail loud, not silent ────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
# The builder authenticates the `claude` CLI via the Max-subscription OAuth
# token in the macOS keychain. Under launchd there's no interactive session to
# refresh it, so the token can lapse for days. When it does, EVERY iteration's
# pre-pick stage 401s with "Invalid authentication credentials" — but the loop
# swallows that as a soft "no parseable ISSUE_PICKED marker" warning and grinds
# through MAX_CONSECUTIVE_FAILURES doomed iterations before stopping, producing
# a silent zero-PR night with no obvious cause. Root cause of the 2026-06-19 and
# 2026-06-22 dead nights.
#
# Catch it up front with one cheap probe down the exact code path the real
# stages use. On an auth-signature failure, alert loudly and abort BEFORE the
# loop. Transient/network errors are not auth signatures, so they fall through
# to the loop's own per-iteration failure handling rather than blocking the
# whole night. Escape hatch: SKIP_AUTH_PREFLIGHT=1.
if [ -z "${_PILOT_TEST_MODE:-}" ] && [ -z "${SKIP_AUTH_PREFLIGHT:-}" ]; then
  PREFLIGHT_LOG="$OUTPUT_DIR/lift-enhance-$DATE-preflight.md"
  AUTH_PROBE=$(run_with_timeout "$BUILDER_AUTH_TIMEOUT" claude --allowedTools "Read" --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" \
    --output-format json --max-turns 1 -p "Reply with exactly: AUTH_OK" 2>&1 || true)
  if is_auth_failure "$AUTH_PROBE"; then
    AUTH_ALERT="🚨 *${PROJECT_NAME} builder ABORTED — claude CLI is not authenticated.*
$(cat <<'PREFLIGHTMSG'
The keychain OAuth token is expired/invalid, so every iteration would 401. No iterations ran tonight.
*Fix:* run `claude setup-token` in a terminal (Max-subscription login), then re-run `scripts/builder.sh 1` to catch up.
Verify + details: docs/pilot-responsibilities.md → "Builder auth".
PREFLIGHTMSG
)"
    echo "🛑 Auth preflight FAILED — claude CLI not authenticated. Aborting before the loop at $(date)." | tee "$PREFLIGHT_LOG"
    echo "$AUTH_PROBE" | head -c 500 >> "$PREFLIGHT_LOG"
    log_error "Auth preflight failed: claude CLI not authenticated (401 / not logged in). Aborted before loop."
    slack_send "$AUTH_ALERT"
    thread_send "$AUTH_ALERT"
    exit 1
  fi
  echo "✅ Auth preflight passed — claude CLI authenticated." | tee "$PREFLIGHT_LOG"
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

  # ── WIP limit: gate the night when the review queue is saturated ──────────
  # Every PR the builder opens lands on Aaron's morning review queue. Once
  # MAX_OPEN_PRS are already open, building more just ages the queue and
  # multiplies rebase conflicts as earlier PRs merge — so stop for the night
  # and say so. Retry iterations are exempt (RETRY_ISSUES non-empty): their
  # failed PRs were closed at startup, so they don't grow the queue.
  OPEN_PR_COUNT=$(cd "$REPO" && gh pr list --state open --json number --jq 'length' 2>/dev/null | head -1 | tr -d ' \n' || true)
  case "$OPEN_PR_COUNT" in ''|*[!0-9]*) OPEN_PR_COUNT=0 ;; esac
  if wip_gate_active "$OPEN_PR_COUNT" "$MAX_OPEN_PRS" "$RETRY_ISSUES"; then
    RUN=$((RUN - 1))
    echo "🚧 WIP limit: $OPEN_PR_COUNT open PRs ≥ MAX_OPEN_PRS=$MAX_OPEN_PRS — no new work tonight until the review queue drains."
    log_info "WIP limit reached ($OPEN_PR_COUNT open PRs >= $MAX_OPEN_PRS) — night gated"
    thread_send "🚧 *WIP limit reached* — $OPEN_PR_COUNT PRs are already open (cap: $MAX_OPEN_PRS). No new work tonight; merge or close PRs to release the builder. Override: MAX_OPEN_PRS in project.env (0 disables)."
    break
  fi

  # Snapshot state before this iteration.
  # `head -1` guards against pipefail: if `npm test` exits non-zero (e.g. a broken
  # build), the pipeline already emitted "1335" then `|| echo "0"` appends "0",
  # producing a multi-line value that breaks `$((TESTS_AFTER - TESTS_BEFORE))`.
  TESTS_BEFORE=$({ cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo "0"; } | head -1)
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

  # Pull pickable issue backlog. "pickable" is exclusion-based: every open
  # issue NOT in {state:triage, state:backlog, state:started, state:blocked,
  # state:canceled}. Issues without any state:* label (architect orphans, old
  # untriaged items) are included — that way a single label-omitting agent
  # cannot silently drop issues from the picking pool. In-progress issues are
  # surfaced separately in a do-not-pick prompt section. See tracker.sh
  # gh_list "pickable" for the underlying jq query.
  BACKLOG_ISSUES=$(bash "$TRACKER" list pickable || echo "Could not fetch issues")

  # In-progress issues — work is already underway (state:started label set when
  # commits land in any iteration, or when Claude emits ISSUE_PROGRESS markers).
  # Shown to Claude as informational so it knows not to pick them, even if the
  # tracker has not been refreshed since they were marked.
  IN_PROGRESS_ISSUES=$(bash "$TRACKER" list started 2>/dev/null || true)

  # Fetch full details (description + comments) for top priority issues
  TOP_ISSUE_IDS=$({ echo "$BACKLOG_ISSUES" | grep -oE "${ISSUE_PREFIX}-[0-9]+" | head -5; } || true)
  ISSUE_DETAILS=""
  for issue_id in $TOP_ISSUE_IDS; do
    detail=$(bash "$TRACKER" view "$issue_id" || true)
    ISSUE_DETAILS+="
--- $issue_id ---
$detail
"
  done

  # Gather recently skipped issues so Claude avoids retrying them this session
  SKIPPED_ISSUES=$(grep -rohE "ISSUE_SKIPPED:${ISSUE_PREFIX}-[0-9]+:[^\"]*" "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | sort -u || true)

  # ── Picking-time dedupe: issues that ALREADY have an open PR ─────────────
  # Query GitHub for every open PR title and extract the issue references
  # (`#NNN` or `LIFT-NNN`). Inject the deduped list into the prompt so Claude
  # sees them BEFORE picking — tonight's earlier iterations, previous nights'
  # still-open PRs, and any manual PRs Aaron made between runs all show up here.
  # Belt-and-suspenders: the post-work guard at line ~668 still fires if Claude
  # picks one of these anyway, but this preempts the wasted compute.
  OPEN_PR_ISSUES=$(cd "$REPO" && gh pr list --state open --json title --limit 100 \
    -q '.[] | .title' 2>/dev/null \
    | grep -oE "(${ISSUE_PREFIX}-|#)[0-9]+" \
    | sed -E "s/^#/${ISSUE_PREFIX}-/" \
    | sort -u | tr '\n' ' ' || true)

  # Merge open-PR issues into the nightly attempted list. They're functionally
  # equivalent — both mean "do not pick" — and pre-loading the list this way
  # also covers run 1 of the night, before NIGHTLY_ATTEMPTED_ISSUES has anything.
  for _open_ref in $OPEN_PR_ISSUES; do
    case " $NIGHTLY_ATTEMPTED_ISSUES " in
      *" $_open_ref "*) ;;
      *) NIGHTLY_ATTEMPTED_ISSUES+="$_open_ref " ;;
    esac
  done

  # ── Deterministic backlog filter ────────────────────────────────────────
  # The pre-pick stage is a cheap call that does NOT reliably honor the
  # "do not pick" lists by eye — on 2026-05-20 it picked LIFT-591 (which had
  # open PR #596) on two consecutive runs, stalling the whole night. Strip
  # every already-excluded issue out of BACKLOG_ISSUES here so the pre-pick
  # physically cannot pick one. The prompt's do-not-pick sections stay as
  # belt-and-suspenders. Covers: open-PR issues, issues attempted/skipped
  # earlier tonight, and issues already In Progress.
  EXCLUDED_IDS=$(
    { echo "$NIGHTLY_ATTEMPTED_ISSUES" | tr ' ' '\n'
      echo "$OPEN_PR_ISSUES" | tr ' ' '\n'
      echo "$IN_PROGRESS_ISSUES" | grep -oE "${ISSUE_PREFIX}-[0-9]+"
      echo "$SKIPPED_ISSUES" | grep -oE "${ISSUE_PREFIX}-[0-9]+"
    } 2>/dev/null | grep -oE "${ISSUE_PREFIX}-[0-9]+" | sort -u || true)
  if [ -n "$EXCLUDED_IDS" ]; then
    _backlog_before=$(echo "$BACKLOG_ISSUES" | grep -cE "${ISSUE_PREFIX}-[0-9]+" | tr -d ' \n')
    while IFS= read -r _ex; do
      [ -z "$_ex" ] && continue
      BACKLOG_ISSUES=$(echo "$BACKLOG_ISSUES" | grep -v "^${_ex} " || true)
    done <<< "$EXCLUDED_IDS"
    _backlog_after=$(echo "$BACKLOG_ISSUES" | grep -cE "${ISSUE_PREFIX}-[0-9]+" | tr -d ' \n')
    echo "  🧹 Backlog filter: ${_backlog_before} pickable → ${_backlog_after} after removing already-claimed/attempted issues" | tee -a "$RUN_LOG"
  fi

  # ── Create a branch for this iteration ───────────────────────────────────
  # Branch name will be updated once we know which issue Claude picks.
  # Start on a temporary branch; rename after we parse the run log.
  ITER_BRANCH="enhance/run${RUN}-$DATE"
  git checkout -b "$ITER_BRANCH" "${DEFAULT_BRANCH:-master}" 2>/dev/null || {
    # Branch may already exist from a retry — force reset it
    git checkout "$ITER_BRANCH" 2>/dev/null || true
    git reset --hard "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
  }

  # ── Stage 1: pre-pick the issue, flip state to In Progress ────────────
  # Why two-stage: the script is blocked while the main `claude -p` runs, so
  # it cannot flip the issue state mid-session. If iteration N stalls without
  # commits, iteration N+1 sees the same issue as unstarted and re-picks it
  # (the 2026-05-07 stall-then-rerun pattern). Stage 1 is a cheap read-only
  # call (~30s, ~$0.05) that just picks the next issue. The script flips its
  # state to In Progress immediately, BEFORE the main call starts. Even if
  # the main call stalls without producing a commit, the label is already
  # flipped, so the next iteration excludes the issue from its picking pool.
  #
  # PICKED_ISSUE_OVERRIDE env var bypass: when set (e.g. for a manual one-off
  # "fix this specific issue" run), skip the pre-pick stage entirely and use
  # the override value. Cleared after use so it only applies to the first
  # iteration — subsequent iterations in the same loop fall back to pre-pick.
  PICKED_ISSUE=""
  if [ -n "${PICKED_ISSUE_OVERRIDE:-}" ]; then
    PICKED_ISSUE="$PICKED_ISSUE_OVERRIDE"
    echo "  🎯 PICKED_ISSUE_OVERRIDE=$PICKED_ISSUE — bypassing pre-pick stage" | tee -a "$RUN_LOG"
    bash "$TRACKER" update "$PICKED_ISSUE" --state "In Progress" 2>&1 | tee -a "$RUN_LOG" || true
    case " $NIGHTLY_ATTEMPTED_ISSUES " in
      *" $PICKED_ISSUE "*) ;;
      *) NIGHTLY_ATTEMPTED_ISSUES+="$PICKED_ISSUE " ;;
    esac
    PICKED_ISSUE_OVERRIDE=""
  else
  PRE_PICK_JSON="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}-prepick.json"
  # Pin the Opus-tier model for picking quality, but deliberately NOT max effort:
  # choosing one issue from titles is trivial, so max effort would only add cost/latency.
  PRE_PICK_RESULT=$(run_with_timeout "$BUILDER_PREPICK_TIMEOUT" claude --allowedTools "Read,Glob,Grep" --disallowedTools "$BUILDER_DISALLOWED_TOOLS" --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" --output-format json --max-turns "$BUILDER_PREPICK_MAX_TURNS" -p "$(cat <<PREPICK
You are the pre-pick stage of the overnight builder pipeline for $PROJECT_NAME. Your only job in this call is to pick exactly ONE issue from the unstarted backlog to work on next. You are NOT implementing anything in this call — that happens in the next stage. Pick the issue and exit immediately.

## Unstarted backlog (pickable)

$BACKLOG_ISSUES

## Issues already IN PROGRESS — do NOT pick

${IN_PROGRESS_ISSUES:-None}

## Issues with EXISTING OPEN PRs — do NOT pick

${OPEN_PR_ISSUES:-None}

## Issues already attempted earlier tonight — do NOT pick

${NIGHTLY_ATTEMPTED_ISSUES:-None}

## Issues skipped earlier tonight — do NOT pick

${SKIPPED_ISSUES:-None}

## How to pick

Pick the highest-priority unstarted issue that is NOT in any of the do-not-pick lists above. Priority labels (priority:1-urgent / 2-high / 3-medium / 4-low) appear in the issue list. $PROJECT_NAME is stabilizing for a GA release: if two issues are equal priority, prefer user-facing bug fixes first, then performance/reliability fixes, then UI/UX and accessibility polish. Put refactors, test-only additions, and anything feature-shaped last.

You do NOT need to read the issue bodies or the codebase in this stage — just pick from titles and priorities. The next stage has the full context.

## Output format (REQUIRED)

Output exactly one line — nothing else, no explanation, no preamble:

  ISSUE_PICKED:${ISSUE_PREFIX}-<number>

Example: ISSUE_PICKED:${ISSUE_PREFIX}-501

If absolutely nothing in the unstarted backlog is suitable to work on right now (every option is blocked, ambiguous, or already covered), output exactly:

  NO_IMPROVEMENTS_REMAINING

Do not output any other text. Do not explain your choice. The next stage of the pipeline parses this single line and aborts on anything else.
PREPICK
)" 2>&1 || echo "")
  # claude --output-format json prints one JSON object, but the run captures
  # stdout+stderr together (2>&1) and Bun prepends a "warn: CPU lacks AVX
  # support" line on this machine. Feeding the whole stream to json.loads()
  # then throws and the result is silently dropped — that bug made all 12
  # pre-pick stages unparseable on 2026-05-19. Scan for the JSON line instead.
  PRE_PICK_TEXT=$(echo "$PRE_PICK_RESULT" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('{'):
        try:
            print(json.loads(line).get('result', ''))
            break
        except Exception:
            pass
" 2>/dev/null || true)
  # Fallback: if JSON parsing yielded nothing (format drift, truncation),
  # grep the marker straight out of the raw result — ISSUE_PICKED and
  # NO_IMPROVEMENTS_REMAINING contain no JSON-special characters.
  if [ -z "$PRE_PICK_TEXT" ]; then
    PRE_PICK_TEXT=$(echo "$PRE_PICK_RESULT" | grep -oE "ISSUE_PICKED:${ISSUE_PREFIX}-[0-9]+|NO_IMPROVEMENTS_REMAINING" | head -1 || true)
  fi
  PICKED_ISSUE=$(echo "$PRE_PICK_TEXT" | grep -oE "ISSUE_PICKED:${ISSUE_PREFIX}-[0-9]+" | head -1 | sed "s/ISSUE_PICKED://" || true)
  echo "$PRE_PICK_RESULT" > "$PRE_PICK_JSON" 2>/dev/null || true

  # Guard: the pre-pick must choose from the (already-filtered) pickable
  # backlog. If it named something not in BACKLOG_ISSUES — a hallucinated ID
  # or an excluded issue it picked despite the do-not-pick lists — discard the
  # pick so Stage 2 free-picks instead of burning the iteration on a dead issue.
  if [ -n "$PICKED_ISSUE" ] && ! echo "$BACKLOG_ISSUES" | grep -q "^${PICKED_ISSUE} "; then
    echo "  ⚠️ Pre-pick chose $PICKED_ISSUE, which is not in the pickable backlog — discarding pick; Stage 2 will free-pick." | tee -a "$RUN_LOG"
    PICKED_ISSUE=""
  fi

  if echo "$PRE_PICK_TEXT" | grep -q "NO_IMPROVEMENTS_REMAINING"; then
    echo "  🛑 Pre-pick stage returned NO_IMPROVEMENTS_REMAINING — ending nightly run early" | tee -a "$RUN_LOG"
    thread_send "🛑 *Run $RUN — pre-pick returned NO_IMPROVEMENTS_REMAINING* — backlog exhausted, ending nightly run."
    git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
    git branch -D "$ITER_BRANCH" 2>/dev/null || true
    break
  fi

  if [ -n "$PICKED_ISSUE" ]; then
    echo "  🎯 Pre-pick: $PICKED_ISSUE — flipping state to In Progress before implementation" | tee -a "$RUN_LOG"
    bash "$TRACKER" update "$PICKED_ISSUE" --state "In Progress" 2>&1 | tee -a "$RUN_LOG" || true
    # Also add to NIGHTLY_ATTEMPTED so a stall-then-retry within the night skips it.
    case " $NIGHTLY_ATTEMPTED_ISSUES " in
      *" $PICKED_ISSUE "*) ;;
      *) NIGHTLY_ATTEMPTED_ISSUES+="$PICKED_ISSUE " ;;
    esac
  else
    echo "  ⚠️ Pre-pick stage produced no parseable ISSUE_PICKED marker. Stage 2 will still run, but state-flip-on-pick is skipped this iteration. Raw response: $(echo "$PRE_PICK_TEXT" | head -c 300)" | tee -a "$RUN_LOG"
  fi
  fi  # end PICKED_ISSUE_OVERRIDE bypass

  # ── Stage 2: implement the picked issue ──────────────────────────────────
  # Baseline measured on $ITER_BRANCH specifically — NOT `git rev-list HEAD`.
  # The builder Claude sometimes checks out its own branch and commits there;
  # counting HEAD would score that as success while $ITER_BRANCH stays empty.
  COMMITS_BEFORE=$(git rev-list --count "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null || echo 0)
  CLAUDE_JSON="$OUTPUT_DIR/lift-enhance-$DATE-run${RUN}-output.json"
  # Enable review-router builder mode — Claude (Sonnet) adversarial review via post-commit hook
  export PILOT_BUILDER=1
  export PILOT_REVIEW_LOG="$OUTPUT_DIR/lift-review-$DATE-run${RUN}.log"

  # Precompute prompt fragments for the assigned-issue path. ${var:-fallback}
  # returns $var when set, so it cannot be used to inject a fallback string;
  # easier to build the strings here than fight bash parameter expansion.
  if [ -n "$PICKED_ISSUE" ]; then
    PICKED_NUM=$(echo "$PICKED_ISSUE" | sed "s/${ISSUE_PREFIX}-//")
    ASSIGNED_BLOCK=$(cat <<ASSIGNED
## ASSIGNED ISSUE FOR THIS ITERATION

Pre-pick stage already chose **${PICKED_ISSUE}** for you and has flipped its tracker state to In Progress. Work on ${PICKED_ISSUE} this iteration. Do NOT pick a different issue. If after reading the codebase you decide ${PICKED_ISSUE} is genuinely unworkable (truly blocked, missing info, out of scope), output \`ISSUE_SKIPPED:${PICKED_ISSUE}:<reason>\` AND run this command to release it back into the backlog:

  gh issue edit ${PICKED_NUM} --repo ${GITHUB_ISSUES_REPO} --remove-label state:started --add-label state:unstarted

Do not pick a replacement in the same iteration — let the next iteration pick fresh.
ASSIGNED
)
    STEP2_TEXT="**Implement \`${PICKED_ISSUE}\`** (already pre-picked and claimed in the tracker — see Assigned Issue above)"
  else
    ASSIGNED_BLOCK=""
    STEP2_TEXT="**Pick exactly ONE issue** from the unstarted backlog to implement fully"
  fi

  run_with_timeout "$BUILDER_ITERATION_TIMEOUT" claude --allowedTools "$BUILDER_ALLOWED_TOOLS" --disallowedTools "$BUILDER_DISALLOWED_TOOLS" --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" --effort "${AI_CODE_EFFORT:-max}" --output-format json -p "$(cat <<PROMPT
You are iteration $RUN of the overnight self-improving enhancer for $PROJECT_NAME at $REPO. This is Aaron Chung's portfolio project — he's an ex-AWS SDE2 targeting SWE roles at companies like Notion, Airtable, and Linear.

You are running in a loop. Previous iterations tonight and from recent days have already made improvements. Your job is to find the NEXT most impactful thing to do that hasn't been done yet.

## IMPORTANT: Branch-per-issue mode

You are ALREADY checked out on the branch for this iteration: \`$ITER_BRANCH\` (freshly created off ${DEFAULT_BRANCH:-master}). Each iteration produces its own PR for exactly ONE issue.
- Pick ONE high-impact issue from the backlog below
- Implement it fully, committing with conventional commit messages **directly on \`$ITER_BRANCH\`**
- Do NOT run \`git checkout\`, \`git switch\`, \`git branch\`, or \`git checkout -b\` — do not create, rename, or switch branches. Stay on \`$ITER_BRANCH\` for the entire iteration.
- Creating your own branch (e.g. \`test/...\`, \`refactor/...\`) STRANDS the work: the pipeline pushes \`$ITER_BRANCH\` and opens the PR from it, so commits on any other branch are invisible and produce no PR. This is exactly what wasted 10 of 12 runs on 2026-05-19.
- When you push, push this branch by name: \`git push -u origin $ITER_BRANCH\` (naming it explicitly guards against an accidental stray checkout).
- Focus on quality — this PR will be independently reviewed

${RETRY_ISSUES:+## Retry priority
These issues had failed PRs from previous nights. Prioritize retrying them:
$RETRY_ISSUES
}

## Conventional commits

Use structured commit prefixes:
- feat(LIFT-XXX): for new features
- fix(LIFT-XXX): for bug fixes
- a11y(LIFT-XXX): for accessibility improvements
- test(LIFT-XXX): for test additions
- perf(LIFT-XXX): for performance improvements
- style(LIFT-XXX): for visual/CSS changes
- refactor(LIFT-XXX): for code refactoring
- chore(LIFT-XXX): for maintenance tasks

### Commit author attribution

Every commit you make MUST end with exactly this co-author trailer, verbatim, as the last line of the commit body:

\`$COAUTHOR_TRAILER\`

Do NOT write any other version, capitalization, or suffix (no "(1M context)", no "Opus 4.6", no "Co-authored-by" lowercase). Your own self-knowledge of which model you are is unreliable here — use the exact trailer string above and nothing else. This is the canonical attribution for the model actually running this iteration.

## Current repo state

Recent commits:
$GIT_LOG

Current test output:
$TEST_COUNT

## What previous iterations accomplished

$PREVIOUS_SUMMARIES

## Issue backlog (UNSTARTED issues for $PROJECT_NAME — these are pickable)

$BACKLOG_ISSUES

## Issues already IN PROGRESS — DO NOT PICK (work already underway)

These issues have the \`state:started\` label, meaning a previous builder iteration (tonight or earlier) committed work against them. Picking one of these will produce a redundant branch on top of work that is already underway. If you think one looks genuinely stalled and should be retried, output \`ISSUE_SKIPPED:<id>:looks stalled, needs human review\` and pick something different from the backlog instead.

${IN_PROGRESS_ISSUES:-None}

## Issue details (descriptions + comments — may include triage agent suggestions as a STARTING POINT — read the codebase and use your own judgment; deviate from suggestions if you find a better approach)

$ISSUE_DETAILS

## Issues skipped earlier tonight (do NOT retry these)

${SKIPPED_ISSUES:-None}

## Issues with EXISTING OPEN PRs — DO NOT PICK (would create a duplicate)

These issues already have an open pull request on GitHub right now — from earlier iterations tonight, previous nights, or a manual PR Aaron opened. Picking any of these will create a duplicate PR, the failure mode that produced 5 PRs for #438 on 2026-04-29 and 2 PRs for #501 on 2026-05-07. Pick something else from the backlog — or if everything in the backlog already has an open PR, output "NO_IMPROVEMENTS_REMAINING" and exit.

${OPEN_PR_ISSUES:-None}

## Issues already ATTEMPTED tonight (do NOT pick any of these — even if they appear in the backlog above)

${NIGHTLY_ATTEMPTED_ISSUES:-None}

${BUILD_LEARNINGS:+## Learnings from PRs Aaron rejected (closed unmerged)

These are the reasons Aaron gave when closing previous builder PRs without merging. Treat them like product decisions — do NOT repeat a rejected approach:

$BUILD_LEARNINGS
}
$ASSIGNED_BLOCK

## Your job (this iteration)

1. **Read the repo** — look at what exists NOW (code, tests, config, README, etc.)
2. $STEP2_TEXT
3. **Cross-reference** with what previous iterations already did
4. **Implement it**, committing after each logical change with conventional commit messages
5. **Verify** tests pass and build succeeds

## Discovery (every iteration)

While reading the codebase, actively look for problems. For each discovery, output an ISSUE_DISCOVER line (see output format). $PROJECT_NAME is feature-complete and stabilizing for GA, so report ONLY defects and refinements of existing behavior — do NOT file feature ideas, and do NOT file test-coverage gaps (the suite is already extensive; new tests belong inside bug fixes as regression proof). Look for:
- Functional bugs (unhandled errors, race conditions, data loss paths, broken edge cases: empty data, offline, rapid input)
- UI bugs (contrast issues, layout shifts, broken themes, missing aria attributes)
- UX friction in existing flows (missing loading/error/empty states, inconsistent spacing or copy, dead ends)
- Performance issues (large bundles, unnecessary re-renders, unoptimized images)
- Accessibility violations (missing labels, low contrast, keyboard traps)
- CLAUDE.md checklist violations (hardcoded colors, wrong spacing, missing safe-area-inset)
- Dependency vulnerabilities (check package.json for outdated or insecure deps)

Do NOT fix discoveries in the same iteration — just create an issue. Fix them in a future iteration when they are the highest priority.

## Review feedback and push workflow

A Claude adversarial review runs automatically via a Husky post-commit git hook — after each commit it sends the full branch diff (vs master) to an independent Claude model (Sonnet, different from the one writing this code) and prints the findings inline. No separate command is needed; the review appears right after your commit completes.

### Step 1: Implement and commit (FOREGROUND ONLY)
Write code, run tests, then commit with conventional prefixes. The post-commit review runs synchronously and can take 2-5 minutes — this is expected; wait for it. DO NOT pass run_in_background:true on this or any \`git commit\` / \`git push\` / git-hook call. Backgrounding triggers the early-exit failure mode where you receive a "background task completed" notification and reply with a chatty one-liner instead of the structured response. That pattern caused the 2026-05-13 P2 audit finding (25/60 runs missing ISSUE_DONE markers — full iteration of compute wasted on each).

### Step 2: Address findings
Read the review output carefully. If the reviewer identifies real issues (P1/P2):
1. Fix them in new commits — each commit triggers a fresh review
2. One or two review passes is typically sufficient
If findings are false positives (e.g. concerns about persistence that's already handled by a watcher), ignore them and move on.

### Step 3: Push (FOREGROUND ONLY)
When your implementation is complete and findings are addressed, push to remote IN THE FOREGROUND:
  git push -u origin $ITER_BRANCH

### Step 4: Output structured response, THEN exit
After your final push completes, you MUST emit the full structured response below (Plan / Changes / Issue updates / Verification / Screenshots / Summary) **as your final assistant message in this session**. The pipeline parses ISSUE_DONE / ISSUE_PROGRESS markers from this response — if you exit without them, the issue is dropped from tomorrow's tracking and gets re-attempted next night, wasting a full iteration of compute. "The pipeline handles PR creation" does NOT mean you can skip the response format. Specifically: do NOT exit with a chatty one-liner like "background task completed, pipeline will handle the rest" — that is the failure mode that caused the 2026-05-06 P1 and 2026-05-13 P2 audit findings.

**Pre-exit self-check (do this before emitting your final message):** your final assistant message must contain ALL of these literal strings, in order: \`## Plan\`, \`## Changes\`, \`## Issue updates\`, an \`ISSUE_DONE:${ISSUE_PREFIX}-\` or \`ISSUE_PROGRESS:${ISSUE_PREFIX}-\` line, \`## Verification\`, \`## Screenshots\`, \`## Summary\`. If any are missing, the iteration is dropped. The receipt of a background-task completion notification is NOT permission to exit early — even if the work is done and the PR is live, you must still emit the full structured response before the session ends.

## Rules

- NEVER fabricate, guess, or invent URLs, domains, API keys, or external identifiers. If you need the deployment URL, read CLAUDE.md (the "Live:" field). If you need a repo URL, use the git remote. If you cannot find the authoritative value, SKIP the task — do not make one up.
- Pick ONE issue — do not mix multiple unrelated changes in one iteration
- Do NOT redo work from previous iterations — if tests exist, don't rewrite them
- Do NOT break existing functionality — run tests after each change
- Quality over quantity — fully implement the issue rather than doing it halfway
- If the triage comment on your issue lists **Acceptance criteria**, treat them as the definition of done: verify each criterion before you push, and confirm each one explicitly in the Verification section below.
- If you cannot find anything meaningful to improve, output ONLY the line "NO_IMPROVEMENTS_REMAINING" and exit
- Commit with clear conventional commit messages (feat/fix/a11y/test/perf/style/refactor/chore prefix)
- End every commit body with exactly this trailer (see "Commit author attribution" above): \`$COAUTHOR_TRAILER\`. Do not self-report a different model version.
- Include \`Closes #N\` (where N is the issue number, no LIFT- prefix) in at least one commit body so GitHub auto-closes the issue when the PR merges. The pipeline depends on this — it no longer closes issues at implementation time because that orphaned issues whose PRs failed CI (see PR #467 / LIFT-436, 2026-04-30).
- If a test is failing when you start, you may try to fix it ONCE. If it still fails after one attempt, skip it and move on to new work. Do not spend more than 10 turns on any single fix.
- IMPORTANT: Focus on SHIPPING, not perfecting. Commit working improvements and move on.
- Do NOT create, switch, or rename branches — no \`git checkout\`, \`git switch\`, \`git branch\`, or \`git checkout -b\`. You are already on \`$ITER_BRANCH\`; commit directly to it. Work committed to any other branch is invisible to the pipeline and produces no PR (see "Branch-per-issue mode" above).
- Do NOT create pull requests — the pipeline handles PR creation after your work is done.
- You MUST push to remote when your implementation is complete: git push -u origin $ITER_BRANCH. A Claude adversarial review runs automatically after each commit (post-commit hook); address any P1/P2 findings in follow-up commits before you push.
- CRITICAL — DO NOT DELEGATE: do this work yourself in this session. Do not invoke Task, Agent, or any sub-agent. The pipeline parses your final assistant message for the structured \`## Issue updates\` markers below; if you delegate, those markers end up inside a sub-agent's response that the pipeline cannot read, and the iteration gets re-run on the same issue tomorrow night. The 2026-04-29 builder run produced 12 duplicate PRs because the parent kept exiting after one turn while the real work was happening in a sub-agent. Stay in your own session, emit the markers, finish the iteration.
- CRITICAL — DO NOT BACKGROUND GIT OPERATIONS: run \`git commit\`, \`git push\`, and git hooks in the FOREGROUND (see Step 1 above for the full rationale). Do not pass run_in_background:true for any git command. That pattern caused the 2026-05-06 P1 (33/55 runs) and the 2026-05-13 P2 (25/60 runs) audit findings. Foreground git, run the Step 4 self-check, then exit.

## Output format

## Plan
What issue you chose and why (1-3 sentences). Include the issue ID.

## Changes
What you did (bullet points)

## Issue updates
CRITICAL: You MUST output issue status lines for the issue you worked on. Output each on its own line with NO leading whitespace.

For the issue you implemented:
ISSUE_DONE:LIFT-XXX|Brief summary of implementation and any notable decisions
ISSUE_PROGRESS:LIFT-XXX|What was completed so far and what remains
ISSUE_SKIPPED:LIFT-XXX:reason (if you attempted but could not complete it)

If you did work that has no matching issue, create one:
ISSUE_CREATE:priority:title
Then also output ISSUE_DONE or ISSUE_PROGRESS for it.

For discoveries you found but did NOT fix this iteration:
ISSUE_DISCOVER:priority:title
Priority is 1-4 (1=urgent, 2=high, 3=medium, 4=low).

Do not fabricate existing issue IDs — only use IDs from the backlog above.

## Verification
Write this section for the human reviewer who will test on a real iPhone before merging. Include ALL of these subsections:

### Steps to test
Numbered steps to manually verify the change works. Be specific — include which screen to navigate to, what to tap, what gesture to perform. Assume the reviewer opens the Vercel preview URL on their iPhone, signs in with Google OAuth, and lands on the main app. Start from step 1 being navigation within the app — do not include sign-in steps.

### Expected behavior
What the reviewer should see after each step. Describe visible outcomes, not implementation details.

### What to watch for
Specific things that could go wrong with this change. Think about: theme rendering across all 9 themes (especially light mode), scroll behavior, keyboard interactions, touch target sizes, animations, layout shifts, and edge cases the reviewer should try to break.

### Risk assessment
- **Scope:** What parts of the app are affected (narrow = just this component, broad = multiple views)
- **Confidence:** How confident are you this is correct (high/medium/low and why)
- **Rollback:** If this breaks something, what is the revert path

## Screenshots
List the routes/screens this change affects so the pipeline can auto-capture screenshots from a local dev server. Output one route per line, prefixed with SCREENSHOT_ROUTE: and starting with /. Only include routes whose VISUAL output changed.

Examples:
SCREENSHOT_ROUTE:/
SCREENSHOT_ROUTE:/settings/themes
SCREENSHOT_ROUTE:/workout

If the change is purely backend/data/test/refactor with no visual impact, output exactly:
SCREENSHOT_ROUTE:NONE

## Summary
- Issue: LIFT-XXX (title)
- Tests: X passing
- Build: pass/fail
- Category: feat|fix|a11y|test|perf|style|refactor|chore
PROMPT
)" --max-turns "$BUILDER_MAX_TURNS" 2>&1 > "$CLAUDE_JSON"
  CLAUDE_EXIT=$?
  if [ "$CLAUDE_EXIT" -eq 124 ]; then
    echo "⏱️  Run $RUN timed out after ${BUILDER_ITERATION_TIMEOUT}s — killed the hung claude call" | tee -a "$RUN_LOG"
    log_error "Run $RUN timed out after ${BUILDER_ITERATION_TIMEOUT}s (hung claude implement call killed)"
    thread_send "⏱️ *Builder Run $RUN timed out* — the implement call exceeded ${BUILDER_ITERATION_TIMEOUT}s and was killed. Scored as a failure; the loop continues."
  fi
  if [ "$CLAUDE_EXIT" -eq 0 ]; then
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

    # Check if Claude signaled nothing left to do.
    # Only honor NO_IMPROVEMENTS_REMAINING from Stage 2 when it was free-picking
    # (no pre-picked issue). When an issue was assigned, Stage 2 only assessed
    # that ONE issue — its NO_IMPROVEMENTS verdict says nothing about the rest
    # of the backlog and must not end the night (2026-05-20: a dup-skip on the
    # assigned LIFT-591 emitted NO_IMPROVEMENTS and killed the run after 2
    # iterations). Genuine backlog exhaustion is detected by the pre-pick stage.
    if [ -z "$PICKED_ISSUE" ] && grep -q "NO_IMPROVEMENTS_REMAINING" "$RUN_LOG" 2>/dev/null; then
      echo "🏁 Claude says nothing left to improve." | tee -a "$RUN_LOG"
      STALLS=$MAX_STALLS  # force stop
      # Clean up empty branch
      git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
      git branch -D "$ITER_BRANCH" 2>/dev/null || true
    else
      # ── Reconcile stray branches ─────────────────────────────────────
      # The builder Claude is told to commit directly to $ITER_BRANCH, but
      # it sometimes runs `git checkout -b <its-own-name>` and commits there
      # instead (the 2026-05-19 pattern: 10/12 runs left enhance/runN empty
      # while the real work sat on test/* and refactor/* branches, so the
      # pipeline pushed empty branches and opened no PRs). If HEAD ended up
      # off $ITER_BRANCH with more commits than $ITER_BRANCH has, move
      # $ITER_BRANCH onto that work so the push + PR pipeline sees it.
      CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
      if [ "$CURRENT_BRANCH" != "$ITER_BRANCH" ]; then
        STRAY_AHEAD=$(git rev-list --count "${DEFAULT_BRANCH:-master}"..HEAD 2>/dev/null || echo 0)
        ITER_AHEAD=$(git rev-list --count "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null || echo 0)
        echo "  ⚠️ Builder strayed off $ITER_BRANCH — HEAD on '${CURRENT_BRANCH:-detached}' ($STRAY_AHEAD commit(s) ahead); $ITER_BRANCH has $ITER_AHEAD" | tee -a "$RUN_LOG"
        if [ "$STRAY_AHEAD" -gt "$ITER_AHEAD" ]; then
          if git branch -f "$ITER_BRANCH" HEAD 2>/dev/null; then
            echo "  🔧 Reconciled: moved $ITER_BRANCH onto the off-branch work ($STRAY_AHEAD commit(s))" | tee -a "$RUN_LOG"
          fi
        fi
        git checkout "$ITER_BRANCH" 2>/dev/null || true
      fi

      # Check if any new commits were actually produced — measured on
      # $ITER_BRANCH (post-reconcile), not HEAD, so a run that strayed and
      # could not be reconciled is correctly scored as a stall.
      COMMITS_AFTER=$(git rev-list --count "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null || echo 0)
      NEW_COMMITS=$((COMMITS_AFTER - COMMITS_BEFORE))
      if [ "$NEW_COMMITS" -eq 0 ]; then
        STALLS=$((STALLS + 1))
        echo "⚠️  Run $RUN produced no commits (stall $STALLS/$MAX_STALLS)" | tee -a "$RUN_LOG"
        ITER_END=$(date +%s)
        ITER_DURATION=$((ITER_END - ITER_START))
        echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,1,,stall" >> "$METRICS_FILE"
        # Clean up empty branch
        git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
        git branch -D "$ITER_BRANCH" 2>/dev/null || true
      else
        STALLS=0
        echo "✅ Run $RUN finished at $(date) — $NEW_COMMITS new commit(s)" | tee -a "$RUN_LOG"

        # ── Rename branch to match the issue ─────────────────────────────
        PRIMARY_ISSUE=$(grep -oE "ISSUE_DONE:${ISSUE_PREFIX}-[0-9]+" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/ISSUE_DONE://" || true)
        if [ -z "$PRIMARY_ISSUE" ]; then
          PRIMARY_ISSUE=$(grep -oE "ISSUE_PROGRESS:${ISSUE_PREFIX}-[0-9]+" "$RUN_LOG" 2>/dev/null | head -1 | sed "s/ISSUE_PROGRESS://" || true)
        fi
        # Fallback: when Claude doesn't emit ISSUE_DONE markers (happens when
        # the inline post-commit review hook makes Claude exit with a terse ack),
        # infer the issue from the commit messages so the branch still gets
        # renamed and the dedupe guard below can fire.
        if [ -z "$PRIMARY_ISSUE" ]; then
          ISSUE_NUM_FROM_COMMIT=$(git log --format=%s "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null \
            | grep -oE "${ISSUE_PREFIX}-[0-9]+|#[0-9]+" | head -1 | grep -oE '[0-9]+' || true)
          if [ -n "$ISSUE_NUM_FROM_COMMIT" ]; then
            PRIMARY_ISSUE="${ISSUE_PREFIX}-${ISSUE_NUM_FROM_COMMIT}"
            echo "  ℹ️ Inferred PRIMARY_ISSUE=$PRIMARY_ISSUE from commit message (no ISSUE_DONE marker emitted)" | tee -a "$RUN_LOG"
          fi
        fi
        if [ -n "$PRIMARY_ISSUE" ]; then
          NEW_BRANCH="enhance/${PRIMARY_ISSUE}-$DATE"
          if [ "$NEW_BRANCH" != "$ITER_BRANCH" ]; then
            git branch -m "$ITER_BRANCH" "$NEW_BRANCH" 2>/dev/null || true
            ITER_BRANCH="$NEW_BRANCH"
          fi
        fi

        # Track every issue touched this iteration so the next iteration's
        # prompt can steer away from it, even if Claude didn't mark it Done.
        ATTEMPTED_THIS_RUN=$(git log --format=%s "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null \
          | grep -oE "${ISSUE_PREFIX}-[0-9]+|#[0-9]+" | sort -u || true)
        [ -n "$PRIMARY_ISSUE" ] && ATTEMPTED_THIS_RUN+="
$PRIMARY_ISSUE"
        for _ref in $ATTEMPTED_THIS_RUN; do
          # Normalize "#438" -> "LIFT-438" so SKIPPED/ATTEMPTED lists use one shape.
          if [[ "$_ref" =~ ^#([0-9]+)$ ]]; then
            _ref="${ISSUE_PREFIX}-${BASH_REMATCH[1]}"
          fi
          case " $NIGHTLY_ATTEMPTED_ISSUES " in
            *" $_ref "*) ;;
            *) NIGHTLY_ATTEMPTED_ISSUES+="$_ref " ;;
          esac
        done

        # ── Mark touched issues as In Progress in the tracker ────────────
        # Commit-driven, not marker-driven: even when Claude exits without
        # emitting ISSUE_PROGRESS markers (the 2026-05-07 stall pattern), the
        # tracker state reflects that work has started. Subsequent iterations
        # query "tracker.sh list pickable" for the picking pool, so once
        # the label flips, the issue disappears from the picking list.
        # The later ISSUE_DONE handler at line ~620 closes issues that finished;
        # this only sets In Progress for issues that received commits but no
        # completion marker.
        for _ref in $ATTEMPTED_THIS_RUN; do
          if [[ "$_ref" =~ ^#([0-9]+)$ ]]; then
            _ref="${ISSUE_PREFIX}-${BASH_REMATCH[1]}"
          fi
          # Skip if Claude already emitted an ISSUE_DONE marker for this issue
          # (the Done update later in the iteration is the right end state).
          if grep -qE "ISSUE_DONE:${_ref}\b" "$RUN_LOG" 2>/dev/null; then
            continue
          fi
          echo "  🟡 Marking $_ref as In Progress (commit detected)" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$_ref" --state "In Progress" 2>&1 | tee -a "$RUN_LOG" || true
        done

        # ── Extract issue category for PR labeling ───────────────────────
        ISSUE_CATEGORY=$(grep -oE 'Category: (feat|fix|a11y|test|perf|style|refactor|chore)' "$RUN_LOG" 2>/dev/null | head -1 | sed 's/Category: //' || echo "feat")

        # ── Create new issues for discoveries ─────────────────────
        { grep -oE 'ISSUE_DISCOVER:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  📋 Discovered issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" 2>&1 | tee -a "$RUN_LOG"
        done

        # Create new issues for work not in the backlog (already done)
        { grep -oE 'ISSUE_CREATE:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ priority title; do
          echo "  Creating issue: $title (priority $priority)" | tee -a "$RUN_LOG"
          bash "$TRACKER" create "$title" "$priority" --state "Done" 2>&1 | tee -a "$RUN_LOG"
        done

        # Handle skipped issues — move to Blocked with a comment
        { grep -oE "ISSUE_SKIPPED:${ISSUE_PREFIX}-[0-9]+:[^\"]*" "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS=: read -r _ _ issue_id reason; do
          echo "  Blocking $issue_id: $reason" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "Blocked" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "Automated run blocked this issue on $DATE: $reason" 2>&1 | tee -a "$RUN_LOG"
        done

        # ── Security scan before push ─────────────────────────────────────
        if ! bash "$SCRIPT_DIR/../lib/security-scan.sh" "${DEFAULT_BRANCH:-master}" 2>&1 | tee -a "$RUN_LOG"; then
          echo "🚨 Security scan blocked push — skipping this iteration" | tee -a "$RUN_LOG"
          thread_send "🚨 *Security scan blocked push on $ITER_BRANCH* — suspicious patterns in diff"
          continue
        fi

        # ── Validate CI (build + test) before creating PR ──────────────────
        # Ensure branch is pushed (fallback if Claude didn't push)
        git push -u origin "$ITER_BRANCH" 2>&1 | tee -a "$RUN_LOG" || true

        CI_PASS=true
        BUILD_OUT=$(cd "$REPO" && npm run build 2>&1) || CI_PASS=false
        TEST_OUT=$(cd "$REPO" && npm test -- --reporter=dot 2>&1) || CI_PASS=false

        if [ "$CI_PASS" = "false" ]; then
          echo "⚠️  CI failed on $ITER_BRANCH — attempting auto-fix" | tee -a "$RUN_LOG"
          FIX_ATTEMPTS=0
          while [ "$CI_PASS" = "false" ] && [ "$FIX_ATTEMPTS" -lt "$MAX_FIX_ATTEMPTS" ]; do
            FIX_ATTEMPTS=$((FIX_ATTEMPTS + 1))
            echo "  Fix attempt $FIX_ATTEMPTS/$MAX_FIX_ATTEMPTS" | tee -a "$RUN_LOG"

            # Merge latest master to resolve conflicts
            git fetch origin "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
            if ! git merge "origin/${DEFAULT_BRANCH:-master}" --no-edit 2>&1 | tee -a "$RUN_LOG"; then
              # Merge conflict — ask Claude to resolve
              CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
              if [ -n "$CONFLICT_FILES" ]; then
                run_with_timeout "$BUILDER_FIX_TIMEOUT" claude --allowedTools "$BUILDER_ALLOWED_TOOLS" --disallowedTools "$BUILDER_DISALLOWED_TOOLS" --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" --effort "${AI_CODE_EFFORT:-max}" -p "You are in the $REPO repo on branch $ITER_BRANCH. There are merge conflicts with master in these files:
$CONFLICT_FILES

Resolve all merge conflicts, keeping the intent of both sides. Then run npm test and npm run build to verify. Commit the resolution with message 'fix: resolve merge conflicts with master'. End the commit body with exactly this trailer (do not self-report a different model version): $COAUTHOR_TRAILER" --max-turns "$BUILDER_FIX_MAX_TURNS" 2>&1 | tee -a "$RUN_LOG" || true
              fi
            fi

            # Now fix any build/test failures
            CI_PASS=true
            BUILD_OUT=$(cd "$REPO" && npm run build 2>&1) || CI_PASS=false
            TEST_OUT=$(cd "$REPO" && npm test -- --reporter=dot 2>&1) || CI_PASS=false

            if [ "$CI_PASS" = "false" ]; then
              FAIL_SNIPPET=$(echo "$BUILD_OUT" | tail -30)
              TEST_SNIPPET=$(echo "$TEST_OUT" | tail -30)
              run_with_timeout "$BUILDER_FIX_TIMEOUT" claude --allowedTools "$BUILDER_ALLOWED_TOOLS" --disallowedTools "$BUILDER_DISALLOWED_TOOLS" --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" --effort "${AI_CODE_EFFORT:-max}" -p "You are in the $REPO repo on branch $ITER_BRANCH. The CI build or tests are failing. Fix the issues and commit the fix.

Build output (last 30 lines):
$FAIL_SNIPPET

Test output (last 30 lines):
$TEST_SNIPPET

Fix the failing build/tests. Do NOT revert the feature — fix the actual issue. Commit with conventional commit prefix. Run npm test and npm run build to verify your fix works. End the commit body with exactly this trailer (do not self-report a different model version): $COAUTHOR_TRAILER" --max-turns "$BUILDER_FIX_MAX_TURNS" 2>&1 | tee -a "$RUN_LOG" || true

              # Re-check
              CI_PASS=true
              BUILD_OUT=$(cd "$REPO" && npm run build 2>&1) || CI_PASS=false
              TEST_OUT=$(cd "$REPO" && npm test -- --reporter=dot 2>&1) || CI_PASS=false
            fi
          done

          if [ "$CI_PASS" = "true" ]; then
            echo "✅ CI fixed after $FIX_ATTEMPTS attempt(s)" | tee -a "$RUN_LOG"
            git push origin "$ITER_BRANCH" 2>&1 | tee -a "$RUN_LOG" || true
          else
            echo "❌ CI still failing after $MAX_FIX_ATTEMPTS fix attempts — creating PR anyway (needs manual fix)" | tee -a "$RUN_LOG"
            git push origin "$ITER_BRANCH" 2>&1 | tee -a "$RUN_LOG" || true
          fi
        else
          echo "✅ CI passed (build + tests)" | tee -a "$RUN_LOG"
        fi

        # Update issue status
        LATEST_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        COMMIT_URL="https://github.com/$GITHUB_REPO/commit/$LATEST_COMMIT"

        # ── Mark ISSUE_DONE issues as In Progress, NOT closed ──────────────
        # Actual closure happens when GitHub auto-closes the issue on PR merge
        # via "Closes #N" in the commit message. Closing here is premature:
        # PR #467 (LIFT-436) failed CI and never merged, but the issue was
        # marked Done by this loop and got swept closed by cleanup.sh. The
        # PR is still open while the issue shows Closed — orphaned state.
        # Builder requires Claude to include "Closes #N" in commit bodies so
        # the GitHub merge mechanism is the single source of truth.
        _marker_lines ISSUE_DONE "$RUN_LOG" | sort -u | while IFS='|' read -r marker summary; do
          issue_id=$(echo "$marker" | sed 's/ISSUE_DONE://')
          summary=${summary:-No details provided}
          echo "  Marking $issue_id as In Progress (closes on PR merge)" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "In Progress" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "Implementation complete on $DATE — PR opened.

$summary

[View commit]($COMMIT_URL)

This issue will close automatically when the PR merges." 2>&1 | tee -a "$RUN_LOG"
        done
        _marker_lines ISSUE_PROGRESS "$RUN_LOG" | sort -u | while IFS='|' read -r marker summary; do
          issue_id=$(echo "$marker" | sed 's/ISSUE_PROGRESS://')
          summary=${summary:-No details provided}
          echo "  Marking $issue_id as In Progress" | tee -a "$RUN_LOG"
          bash "$TRACKER" update "$issue_id" --state "In Progress" 2>&1 | tee -a "$RUN_LOG"
          bash "$TRACKER" comment-add "$issue_id" "In progress — $summary" 2>&1 | tee -a "$RUN_LOG"
        done

        # Build structured PR description
        ISSUE_TITLE=$(_marker_lines ISSUE_DONE "$RUN_LOG" | head -1 | sed "s/ISSUE_DONE:${ISSUE_PREFIX}-[0-9]*|//" || echo "")
        if [ -z "$ISSUE_TITLE" ]; then
          ISSUE_TITLE=$(_marker_lines ISSUE_PROGRESS "$RUN_LOG" | head -1 | sed "s/ISSUE_PROGRESS:${ISSUE_PREFIX}-[0-9]*|//" || echo "Improvements")
        fi
        ISSUE_URL=""
        [ -n "$PRIMARY_ISSUE" ] && ISSUE_URL=$(bash "$TRACKER" issue-url "$PRIMARY_ISSUE")

        PLAN=$(sed -n '/^## Plan/,/^## /p' "$RUN_LOG" 2>/dev/null | grep -v '^## ' | head -5)
        CHANGES=$(sed -n '/^## Changes/,/^## /p' "$RUN_LOG" 2>/dev/null | grep -v '^## ' | head -10)
        VERIFICATION=$(sed -n '/^## Verification/,/^## Summary/p' "$RUN_LOG" 2>/dev/null | grep -v '^## Summary' | head -40)
        TESTS_AFTER=$({ cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || echo "0"; } | head -1)
        TESTS_DELTA=$((TESTS_AFTER - TESTS_BEFORE))

        PR_COMMIT_LIST=$(git log --oneline "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null | while read -r line; do
          HASH=$(echo "$line" | cut -d' ' -f1)
          MSG=$(echo "$line" | cut -d' ' -f2-)
          echo "- [\`$HASH\`](https://github.com/$GITHUB_REPO/commit/$HASH) $MSG"
        done)

        FIRST_COMMIT_MSG=$(git log --format=%s -1 "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null || echo "")
        PR_TITLE="${FIRST_COMMIT_MSG:-$ISSUE_CATEGORY($PRIMARY_ISSUE): $ISSUE_TITLE}"

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

        # ── Skip if an open PR already exists for this issue ──────────────
        # Load-bearing guard: even if Claude didn't emit ISSUE_DONE markers
        # and the tracker still shows the issue as unstarted, never create
        # a second PR for the same issue. Match against both `#NNN` and
        # `LIFT-NNN` shapes since commit messages and PR titles may use either.
        # Fallback chain: prefer FIRST_COMMIT_MSG (most reliable signal of what
        # Claude worked on), then PRIMARY_ISSUE (already inferred above), then
        # any commit message on the iter branch — handles the case where the
        # first commit's subject happens to lack a ref.
        ISSUE_NUM_FOR_DEDUPE=$(echo "${FIRST_COMMIT_MSG:-}" | grep -oE "#[0-9]+|${ISSUE_PREFIX}-[0-9]+" | head -1 | grep -oE '[0-9]+' || true)
        if [ -z "$ISSUE_NUM_FOR_DEDUPE" ] && [ -n "${PRIMARY_ISSUE:-}" ]; then
          ISSUE_NUM_FOR_DEDUPE=$(echo "$PRIMARY_ISSUE" | grep -oE '[0-9]+' || true)
        fi
        if [ -z "$ISSUE_NUM_FOR_DEDUPE" ]; then
          ISSUE_NUM_FOR_DEDUPE=$(git log --format=%B "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null \
            | grep -oE "#[0-9]+|${ISSUE_PREFIX}-[0-9]+" | head -1 | grep -oE '[0-9]+' || true)
        fi
        if [ -n "$ISSUE_NUM_FOR_DEDUPE" ]; then
          EXISTING_PR=$(gh pr list --repo "$GITHUB_REPO" --state open --json number,title --limit 100 \
            -q ".[] | select(.title | test(\"#${ISSUE_NUM_FOR_DEDUPE}\\\\b|${ISSUE_PREFIX}-${ISSUE_NUM_FOR_DEDUPE}\\\\b\")) | .number" \
            2>/dev/null | head -1)
          echo "  🔍 Pre-PR dedupe check: issue #$ISSUE_NUM_FOR_DEDUPE → existing open PR: ${EXISTING_PR:-none}" | tee -a "$RUN_LOG"
          if [ -n "$EXISTING_PR" ]; then
            DUP_URL="https://github.com/$GITHUB_REPO/pull/$EXISTING_PR"
            echo "♻️ PR #$EXISTING_PR already exists for issue #$ISSUE_NUM_FOR_DEDUPE — skipping duplicate" | tee -a "$RUN_LOG"
            thread_send "♻️ *Run $RUN — skipped duplicate PR* for issue #$ISSUE_NUM_FOR_DEDUPE (existing: <$DUP_URL|PR #$EXISTING_PR>)"
            git checkout "${DEFAULT_BRANCH:-master}" 2>/dev/null || true
            git push origin --delete "$ITER_BRANCH" 2>/dev/null || true
            git branch -D "$ITER_BRANCH" 2>/dev/null || true
            ITER_END=$(date +%s)
            ITER_DURATION=$((ITER_END - ITER_START))
            echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,$NEW_COMMITS,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,0,,duplicate" >> "$METRICS_FILE"
            continue
          fi
        else
          # Couldn't extract an issue number — guard can't help. Log loudly so
          # this shows up in audit reports if a duplicate slips through.
          echo "  ⚠️ Pre-PR dedupe check: could not extract issue number from FIRST_COMMIT_MSG=\"${FIRST_COMMIT_MSG:-(empty)}\" or PRIMARY_ISSUE=\"${PRIMARY_ISSUE:-(empty)}\" — guard cannot fire. PR will be created without dedupe." | tee -a "$RUN_LOG"
        fi

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

$VERIFICATION

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

        # ── Fetch Vercel preview URL ─────────────────────────────────────
        PREVIEW_URL=""
        if [ -n "$PR_NUMBER" ]; then
          # Wait for Vercel to deploy the branch (usually < 90s)
          BRANCH_SHA=$(gh api "repos/$GITHUB_REPO/git/ref/heads/$ITER_BRANCH" --jq '.object.sha' 2>/dev/null || true)
          for i in 1 2 3 4 5 6 7 8 9; do
            sleep 10
            if [ -n "$BRANCH_SHA" ] && [ "$BRANCH_SHA" != "null" ]; then
              LATEST_DEPLOY_ID=$(gh api "repos/$GITHUB_REPO/deployments?sha=$BRANCH_SHA&environment=Preview&per_page=1" --jq '.[0].id' 2>/dev/null || true)
              if [ -n "$LATEST_DEPLOY_ID" ] && [ "$LATEST_DEPLOY_ID" != "null" ]; then
                DEPLOY_STATE=$(gh api "repos/$GITHUB_REPO/deployments/$LATEST_DEPLOY_ID/statuses" --jq '.[0].state // empty' 2>/dev/null || true)
                if [ "$DEPLOY_STATE" = "success" ]; then
                  PREVIEW_URL=$(gh api "repos/$GITHUB_REPO/deployments/$LATEST_DEPLOY_ID/statuses" --jq '.[0].environment_url // empty' 2>/dev/null || true)
                  [ -n "$PREVIEW_URL" ] && break
                fi
              fi
            fi
          done
          # Update PR body with preview link if we got one
          if [ -n "$PREVIEW_URL" ]; then
            echo "  🔗 Preview: $PREVIEW_URL" | tee -a "$RUN_LOG"
            gh pr edit "$PR_NUMBER" --repo "$GITHUB_REPO" --body "$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPO" --json body -q .body)

## Preview
Test on your phone: $PREVIEW_URL" 2>/dev/null || true
          fi
        fi

        # ── Capture local screenshots of affected routes ──────────────────
        # Saved to ~/development/pilot/data/pr-screenshots/pr-NUM-ISSUE-slug/
        # so Aaron can browse them in Finder before merging.
        SCREENSHOT_DIR=""
        SCREENSHOT_ROUTES=$({ grep -oE '^SCREENSHOT_ROUTE:[^ ]+' "$RUN_LOG" 2>/dev/null || true; } | sed 's|^SCREENSHOT_ROUTE:||' | grep -v '^NONE$' | sort -u)
        if [ -n "$SCREENSHOT_ROUTES" ] && [ -n "$PR_NUMBER" ]; then
          # Build a folder name like: pr-42-LIFT-123-fix-theme-toggle
          PR_SLUG=$(echo "$PR_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g' | head -c 40)
          SCREENSHOT_SUBDIR="pr-${PR_NUMBER}${PRIMARY_ISSUE:+-$PRIMARY_ISSUE}${PR_SLUG:+-$PR_SLUG}"
          SCREENSHOT_DIR="$OUTPUT_DIR/pr-screenshots/$SCREENSHOT_SUBDIR"
          # Convert newline-separated routes into args for the capture script.
          # shellcheck disable=SC2086
          PR_TITLE="$PR_TITLE" PR_URL="$PR_URL" ISSUE_ID="$PRIMARY_ISSUE" \
            bash "$SCRIPT_DIR/capture-pr-screenshots.sh" "$REPO" "$SCREENSHOT_DIR" $SCREENSHOT_ROUTES 2>&1 | tee -a "$RUN_LOG" || true
          if [ ! -d "$SCREENSHOT_DIR" ] || [ -z "$(ls -A "$SCREENSHOT_DIR" 2>/dev/null)" ]; then
            SCREENSHOT_DIR=""  # capture failed — don't advertise the path
          fi
        fi

        # ── Slack notification for this iteration ────────────────────────
        DONE_LINKS=$(_marker_lines ISSUE_DONE "$RUN_LOG" | sort -u | while IFS='|' read -r marker summary; do
          id=$(echo "$marker" | sed 's/ISSUE_DONE://')
          title=$(echo "$summary" | head -c 80)
          url=$(bash "$TRACKER" issue-url "$id")
          [ -n "$id" ] && echo "  ✅ <${url}|$id>: ${title:-no description}"
        done)

        ITER_COMMITS=$(git log --oneline "${DEFAULT_BRANCH:-master}".."$ITER_BRANCH" 2>/dev/null | while read -r line; do
          HASH=$(echo "$line" | cut -d' ' -f1)
          MSG=$(echo "$line" | cut -d' ' -f2-)
          echo "  • <https://github.com/$GITHUB_REPO/commit/$HASH|\`$HASH\`> $MSG"
        done)

        # Extract compact verification info for Slack
        RISK_LINE=$(echo "$VERIFICATION" | grep -A1 '### Risk assessment' | grep -i 'scope\|confidence' | head -2 | sed 's/^- //' | tr '\n' ' ')
        WATCH_FOR=$(echo "$VERIFICATION" | sed -n '/### What to watch for/,/### /p' | grep -v '^### ' | head -3 | sed 's/^- /• /' | tr '\n' ' ')

        thread_send "*Run $RUN complete* — $NEW_COMMITS commit(s)
${DONE_LINKS}

🔍 Reviewed inline (Claude adversarial review on commit)

${ITER_COMMITS:+*Commits:*
$ITER_COMMITS}
${RISK_LINE:+📋 $RISK_LINE
}${WATCH_FOR:+⚠️ *Watch for:* $WATCH_FOR
}${PREVIEW_URL:+📱 *Preview:* <$PREVIEW_URL|Test on phone>
}${SCREENSHOT_DIR:+📸 *Screenshots:* \`$SCREENSHOT_DIR\`
}<$PR_URL|View PR>"

        # Collect metrics
        ITER_END=$(date +%s)
        ITER_DURATION=$((ITER_END - ITER_START))
        # `grep -c PATTERN file` prints "0\n" AND exits 1 when no matches, so the
        # `|| echo "0"` would APPEND another "0\n", corrupting the CSV row across
        # multiple lines. Pipe through head -1 to keep just the first count.
        DONE_COUNT=$({ grep -c "ISSUE_DONE:${ISSUE_PREFIX}-[0-9]" "$RUN_LOG" 2>/dev/null || echo "0"; } | head -1)
        SKIPPED_COUNT=$({ grep -c "ISSUE_SKIPPED:${ISSUE_PREFIX}-[0-9]" "$RUN_LOG" 2>/dev/null || echo "0"; } | head -1)
        CREATED_COUNT=$({ grep -c 'ISSUE_CREATE:[1-4]:' "$RUN_LOG" 2>/dev/null || echo "0"; } | head -1)
        BUILD_SIZE=$({ cd "$REPO" && npm run build 2>&1 | grep -oE '[0-9]+\.[0-9]+ KiB' | head -1 | grep -oE '[0-9.]+' || echo ""; } | head -1)
        echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,$NEW_COMMITS,$TESTS_BEFORE,$TESTS_AFTER,$TESTS_DELTA,$DONE_COUNT,$SKIPPED_COUNT,$CREATED_COUNT,0,$BUILD_SIZE,true" >> "$METRICS_FILE"
      fi
    fi
  else
    FAILURES=$((FAILURES + 1))
    log_error "Run $RUN failed (failure $FAILURES/$MAX_CONSECUTIVE_FAILURES)"
    echo "❌ Run $RUN failed at $(date) (failure $FAILURES/$MAX_CONSECUTIVE_FAILURES)" | tee -a "$RUN_LOG"
    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))
    echo "$DATE,$RUN,$ITER_START_FMT,$(date +%H:%M:%S),$ITER_DURATION,0,$TESTS_BEFORE,$TESTS_BEFORE,0,0,0,0,0,,false" >> "$METRICS_FILE"
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
UNSTARTED_COUNT=$({ bash "$TRACKER" list unstarted | grep -c "${ISSUE_PREFIX}-" || echo "0"; } | head -1 | tr -d ' \n')
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
FINAL_TESTS=$({ cd "$REPO" && npm test -- --reporter=dot 2>&1 | grep -oE '[0-9]+ passed' | tail -1 || echo "unknown"; } | head -1)
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

ISSUE_DONE_COUNT=$(grep -rh '^ISSUE_DONE:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
ISSUE_PROGRESS_COUNT=$(grep -rh '^ISSUE_PROGRESS:' "$OUTPUT_DIR"/lift-enhance-$DATE-run*.md 2>/dev/null | wc -l | tr -d ' \n' || echo "0")

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
- **Issues closed:** $ISSUE_DONE_COUNT
- **Issues in progress:** $ISSUE_PROGRESS_COUNT
- **Output tokens tonight:** ${NIGHTLY_OUTPUT_TOKENS} / ${MAX_OUTPUT_TOKENS_PER_NIGHT} cap
- **Avg per night:** ${AVG_OUTPUT} output tokens, ${AVG_ITERS} iterations (over $TREND_DAYS nights)

## PRs
$(for pr_url in $NIGHTLY_PRS; do echo "- $pr_url"; done)

## Issue Board
$(bash "$TRACKER" board-url)

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
prefix = '${ISSUE_PREFIX}'
tracker = '${TRACKER}'

import glob, subprocess
done_items = {}
progress_items = {}
for f in sorted(glob.glob(f'{output_dir}/lift-enhance-{date}-run*.md')):
    with open(f) as fh:
        content = fh.read()
    for m in re.finditer(r'ISSUE_DONE:(' + prefix + r'-\d+)\|(.+)', content):
        done_items[m.group(1)] = m.group(2).strip()[:100]
    for m in re.finditer(r'ISSUE_PROGRESS:(' + prefix + r'-\d+)\|(.+)', content):
        progress_items[m.group(1)] = m.group(2).strip()[:100]

def issue_url(iid):
    try:
        return subprocess.check_output(['bash', tracker, 'issue-url', iid], text=True).strip()
    except:
        return ''

lines = []
if done_items:
    lines.append('*Closed:*')
    for iid, summary in done_items.items():
        url = issue_url(iid)
        lines.append(f'  ✅ <{url}|{iid}>: {summary}')
if progress_items:
    lines.append('*In Progress:*')
    for iid, summary in progress_items.items():
        url = issue_url(iid)
        lines.append(f'  🔄 <{url}|{iid}>: {summary}')
print('\n'.join(lines) if lines else '  (no issue updates)')
" 2>/dev/null)

# PR links for Slack
PR_LINKS=""
for pr_url in $NIGHTLY_PRS; do
  PR_LINKS+="  • <$pr_url|$(basename "$pr_url")>
"
done

# Send completion summary to thread
thread_send "✅ *Build Complete — $DATE*

*Stats:* $RUN iterations | ${BUILDER_RUNTIME_MIN}m runtime | $TOTAL_COMMITS commits | $FINAL_TESTS
*Tokens:* ${NIGHTLY_OUTPUT_TOKENS} output (avg ${AVG_OUTPUT}/night over ${TREND_DAYS}d)

${PR_LINKS:+*PRs:*
$PR_LINKS}
${ALL_DONE_LINKS}

<$(bash "$TRACKER" board-url)|Issue Board>"

echo "✅ Notifications sent."

# Budget tuner runs independently on its own weekly schedule (Sunday via launchd).
# See com.aaron.pilot-tune-budget.plist.

# Cleanup: archive completed/canceled issues, deduplicate backlog
echo ""
echo "── Running cleanup ──"
CLEANUP_OUTPUT=$(bash "$SCRIPT_DIR/cleanup.sh" 2>&1 || echo "⚠️ Cleanup failed (non-fatal)")
echo "$CLEANUP_OUTPUT"
CLEANUP_CLOSED=$(echo "$CLEANUP_OUTPUT" | grep -oE '[0-9]+ closed' | head -1 || echo "0 closed")
BOARD_URL=$(bash "$TRACKER" board-url)
thread_send "🧹 *Cleanup:* $CLEANUP_CLOSED
<${BOARD_URL}|Issue Board>"
