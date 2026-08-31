#!/bin/bash
# Target-CI Watch — is the target repo's default branch actually green?
#
# THE BLIND SPOT THIS FIXES
#
# Pilot watched CI in two places and neither covered the branch that matters:
#
#   * PR-level: the builder labels a PR `ci:failed` and retries it, and
#     pipeline-auditor.sh flags ci:failed retry loops that stop healing.
#   * Pilot's own launchd services: health-report.sh watches their exit codes.
#
# Nothing ever looked at the TARGET repo's default branch. On 2026-08-30 that
# was found to have been red for at least 41 consecutive runs — every master CI
# run in the API's 60-run window, going back past 2026-08-20 and probably to
# 2026-05-29. `migrate-db` was failing, so no schema change reached production
# for roughly three months, and it silently disabled smoke-test-production and
# notify-deploy along with it (LIFT-1280).
#
# Nobody noticed because the failing job is gated on pushes to the default
# branch: PRs skip it and report fully green. The pipeline kept merging PRs
# into a branch whose deploy verification had been dead for months.
#
# WHY THE DIGEST AND NOT THE HEALTH REPORT
#
# health-report.sh runs weekly. A red default branch blocks deploys, so a
# week-long feedback loop is too slow — this streak would have needed six weekly
# reports to reach the length it did. digest.sh runs daily at 06:15 and is the
# thing Aaron actually reads each morning, so the streak count lands in front
# of him every day and escalates.
#
# SILENCE IS NOT SUCCESS
#
# A green branch prints nothing (the digest's house style — sections render
# only when they have something to say). But a FAILURE OF THE CHECK ITSELF is
# reported loudly rather than swallowed: a watcher that goes quiet when `gh`
# breaks recreates exactly the blindness it exists to remove.
#
# Reporter only. Never mutates an issue, a PR, or a branch.
#
# Usage:
#   ./target-ci-watch.sh                 # human-readable report
#   ./target-ci-watch.sh --slack         # emit a Slack-formatted block (digest consumes this)
#   ./target-ci-watch.sh --notify        # post to #lift-automation when not green
#   ./target-ci-watch.sh --limit 200     # runs to scan across all workflows (default 100)

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="target-ci-watch"

SLACK_MODE=""
DO_NOTIFY=""
LIMIT="${TARGET_CI_WATCH_LIMIT:-100}"
while [ $# -gt 0 ]; do
  case "$1" in
    --slack)  SLACK_MODE="1" ;;
    --notify) DO_NOTIFY="1" ;;
    --limit)  shift; LIMIT="${1:?--limit needs a count}" ;;
    *) echo "Unknown argument: $1 (valid: --slack, --notify, --limit N)" >&2; exit 1 ;;
  esac
  shift
done
case "$LIMIT" in ''|*[!0-9]*) echo "--limit must be a positive integer" >&2; exit 1 ;; esac

if [ "${TARGET_CI_WATCH_ENABLED:-1}" = "0" ]; then
  [ -z "$SLACK_MODE" ] && echo "🔭 Target-CI Watch — disabled via TARGET_CI_WATCH_ENABLED=0."
  exit 0
fi

# Declared up front for two reasons: `set -u` safety, and because
# doc-drift-audit.sh only recognises assignments at column 0 — variables first
# set inside an `if` block or by `read` look like undeclared ENV VARS to it and
# get reported as undocumented config.
ICON=""
SEV=""
RED_COUNT=""
WORST_STREAK=""
WF=""
STREAK=""
DAYS=""
SINCE=""
URL=""
EXHAUSTED=""
JOBS=""
GREEN=""

command -v gh >/dev/null 2>&1 || { echo "gh CLI not found" >&2; exit 1; }
: "${GITHUB_REPO:?GITHUB_REPO not set — run init.sh}"
BRANCH="${DEFAULT_BRANCH:-master}"

# Scan ALL workflows on the branch, not one named file: pinning a workflow name
# means a renamed or newly-added workflow silently drops out of the watch, the
# same class of blindness this script exists to fix.
#
# But streaks MUST be computed per workflow. This branch runs several (CI,
# "npm audit", "Integration Tests"), and a green npm-audit run interleaved with
# red CI runs would otherwise reset the streak to zero and report the branch
# healthy — which is precisely the LIFT-1280 failure being fixed. `workflowName`
# is what keeps them apart.
RUNS=$(gh run list --repo "$GITHUB_REPO" --branch "$BRANCH" --limit "$LIMIT" \
  --json databaseId,conclusion,status,displayTitle,createdAt,url,workflowName 2>/dev/null)

# A check that fails silently is worse than no check. Report the breakage.
if [ -z "$RUNS" ] || [ "$RUNS" = "[]" ]; then
  MSG="🔭 *Target-CI Watch could not read CI for \`${GITHUB_REPO}@${BRANCH}\`* — \`gh run list\` returned nothing. The default branch's health is currently UNKNOWN, not green."
  if [ -n "$SLACK_MODE" ]; then echo "$MSG"; else echo "$MSG"; fi
  log_warn "target-ci-watch: gh run list returned no data for $GITHUB_REPO@$BRANCH" >&2
  [ -n "$DO_NOTIFY" ] && [ -z "${_PILOT_TEST_MODE:-}" ] && bash "$NOTIFY" send-async automation "$MSG" >/dev/null 2>&1
  exit 0
fi

REPORT=$(RUNS="$RUNS" LIMIT="$LIMIT" python3 <<'PYEOF'
import json, os
from collections import OrderedDict
from datetime import datetime, timezone

# Unit separator, NOT tab. TAB is whitespace, so bash `read` collapses runs of
# it and an empty field (days-since-green when nothing is green) would shift
# every subsequent field one position left. pr-close-reconcile.sh documents the
# same trap.
US = "\x1f"

runs = json.loads(os.environ["RUNS"])
settled = [r for r in runs if r.get("status") == "completed"]
if not settled:
    raise SystemExit

by_wf = OrderedDict()
for r in settled:
    by_wf.setdefault(r.get("workflowName") or "(unnamed)", []).append(r)

# EVERY red workflow, not just the worst. Reporting one and hiding the rest is
# the same failure this script exists to fix — the deeper window turned up a
# second long-dead workflow ("Integration Tests", red since 2026-08-18) that
# nothing had ever surfaced.
rows = []
for name, rs in by_wf.items():
    if rs[0].get("conclusion") != "failure":
        continue
    streak, first_failed = 0, None
    for r in rs:
        if r.get("conclusion") == "failure":
            streak += 1
            first_failed = r
        else:
            break
    last_green = next((r for r in rs if r.get("conclusion") == "success"), None)
    days = ""
    if last_green:
        ts = datetime.fromisoformat(last_green["createdAt"].replace("Z", "+00:00"))
        days = str((datetime.now(timezone.utc) - ts).days)
    rows.append((
        name, str(streak), days,
        first_failed["createdAt"][:10] if first_failed else "",
        rs[0].get("url", ""),
        # Every run of THIS workflow in the window failed: the true streak is
        # longer than we can see, so never imply the window bounds the outage.
        "1" if streak == len(rs) else "",
    ))

rows.sort(key=lambda r: -int(r[1]))
for r in rows:
    print(US.join(r))
PYEOF
)

# Green: say nothing to Slack.
if [ -z "$REPORT" ]; then
  if [ -z "$SLACK_MODE" ]; then
    echo "🔭 Target-CI Watch — ${GITHUB_REPO}@${BRANCH}: all workflows green ✅"
  fi
  log_info "target-ci-watch: $GITHUB_REPO@$BRANCH all workflows green" >&2
  exit 0
fi

RED_COUNT=$(echo "$REPORT" | grep -c . | tr -d ' \n')
WORST_STREAK=$(echo "$REPORT" | head -1 | cut -d$'\x1f' -f2)

# Escalate on the worst streak. 1 is noise on a busy branch; 3+ means nobody is
# looking; 10+ is the shape of the LIFT-1280 outage, which reached at least 41.
if   [ "${WORST_STREAK:-0}" -ge 10 ]; then ICON="🚨"; SEV="BROKEN"
elif [ "${WORST_STREAK:-0}" -ge 3 ];  then ICON="⚠️";  SEV="failing"
else                                       ICON="🔴"; SEV="failing"
fi

LINES=""
PLAIN=""
while IFS=$'\x1f' read -r WF STREAK DAYS SINCE URL EXHAUSTED; do
  [ -z "$WF" ] && continue
  if [ -n "$DAYS" ]; then GREEN="last green ${DAYS}d ago"
  elif [ -n "$EXHAUSTED" ]; then GREEN="no green in the last ${LIMIT} runs — streak is at least this long"
  else GREEN="no green run in the scanned window"; fi

  # Name the jobs actually failing — "CI is red" alone is not actionable.
  RUN_ID=$(echo "$URL" | grep -oE '[0-9]+$' || true)
  JOBS=""
  [ -n "$RUN_ID" ] && JOBS=$(gh run view "$RUN_ID" --repo "$GITHUB_REPO" --json jobs \
      --jq '[.jobs[] | select(.conclusion=="failure") | .name] | join(", ")' 2>/dev/null || true)

  LINES+="   • \`${WF}\` — ${STREAK} consecutive, ${GREEN}, since ${SINCE:-unknown}${JOBS:+ · failing job(s): \`${JOBS}\`} · <${URL}|run>
"
  PLAIN+="   ${WF}: streak=${STREAK}, ${GREEN}, since ${SINCE:-unknown}, jobs=${JOBS:-unknown}
"
done <<< "$REPORT"

MSG="${ICON} *${GITHUB_REPO}@${BRANCH} — ${RED_COUNT} workflow(s) ${SEV}*
${LINES}   _Anything gated behind these is not landing._"

if [ -n "$SLACK_MODE" ]; then
  echo "$MSG"
else
  echo "🔭 Target-CI Watch — ${GITHUB_REPO}@${BRANCH}"
  echo "   red workflows:   $RED_COUNT"
  printf '%s' "$PLAIN"
fi

log_warn "target-ci-watch: $GITHUB_REPO@$BRANCH has $RED_COUNT red workflow(s), worst streak=$WORST_STREAK" >&2

if [ -n "$DO_NOTIFY" ] && [ -z "${_PILOT_TEST_MODE:-}" ]; then
  bash "$NOTIFY" send-async automation "$MSG" >/dev/null 2>&1 || true
fi

exit 0
