#!/bin/bash
# Weekly Health Report — aggregates metrics across all pipeline components.
# No AI tokens consumed — pure bash + python3 data analysis.
#
# Reads: lift-metrics.csv, lift-usage-tracking.csv, lift-tune-log.csv,
#        lift-discovery-metrics.csv
# Writes: lift-weekly-health-YYYY-MM-DD.md
# Posts: summary to #pilot via webhook
#
# Usage:
#   ./health-report.sh              # generate and post
#   ./health-report.sh --dry-run    # generate only, don't post

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/service-health.sh"
TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="health-report"

DATE=$(date +%Y-%m-%d)
DRY_RUN="${1:-}"
export OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
REPORT="$OUTPUT_DIR/lift-weekly-health-$DATE.md"

# CSVs
USAGE_CSV="$OUTPUT_DIR/lift-usage-tracking.csv"
METRICS_CSV="$OUTPUT_DIR/lift-metrics.csv"
TUNE_LOG="$OUTPUT_DIR/lift-tune-log.csv"
DISCOVERY_CSV="$OUTPUT_DIR/lift-discovery-metrics.csv"

echo "📊 Generating weekly health report — $DATE"

# Gather data with python
REPORT_DATA=$(python3 << 'PYEOF'
import csv, json, sys, os
from datetime import datetime, timedelta
from collections import defaultdict

output_dir = os.environ.get('OUTPUT_DIR', os.environ.get('PILOT_DIR', '') + '/data')

now = datetime.now()
week_ago = now - timedelta(days=7)
week_start = week_ago.strftime('%Y-%m-%d')

def read_csv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

# ── Builder metrics ──
# Source of truth: lift-metrics.csv. The old lift-runtime.csv was written by
# orchestrator.sh, which was decommissioned 2026-04-02 in favor of independent
# launchd services — that CSV has been frozen ever since. We derive nights_run
# and average runtime directly from the per-iteration rows now.
metrics_rows = [r for r in read_csv(f'{output_dir}/lift-metrics.csv') if r.get('date', '') >= week_start]
total_commits = sum(int(r.get('commits', 0) or 0) for r in metrics_rows)
total_iterations = len(metrics_rows)
successful = sum(1 for r in metrics_rows if r.get('success') == 'true')
stalls = sum(1 for r in metrics_rows if r.get('success') == 'stall')
failures = sum(1 for r in metrics_rows if r.get('success') == 'false')
stall_rate = stalls / total_iterations * 100 if total_iterations else 0
commits_per_iter = total_commits / successful if successful else 0

# Nights = distinct dates with at least one builder iteration.
nights_run = len({r['date'] for r in metrics_rows if r.get('date')})

# Builder staleness — computed across ALL history, not just this week, so a
# stuck builder is caught before a full week of silence. On 2026-07-09 one
# iteration's claude call hung with no timeout; because launchd will not start a
# new instance while the previous one is still alive, the builder produced no
# output for 5 days and nothing flagged it. The builder is scheduled Mon-Fri.
all_metrics = read_csv(f'{output_dir}/lift-metrics.csv')
builder_dates = [r['date'] for r in all_metrics if r.get('date')]
last_builder_date = max(builder_dates) if builder_dates else None
days_since_builder = None
if last_builder_date:
    try:
        days_since_builder = (now.date() - datetime.strptime(last_builder_date, '%Y-%m-%d').date()).days
    except ValueError:
        days_since_builder = None
# Builder runtime per night = sum of iteration durations / nights.
total_builder_sec = sum(int(r.get('duration_sec', 0) or 0) for r in metrics_rows)
avg_builder_min = (total_builder_sec / nights_run / 60) if nights_run else 0

# ── Token usage ──
usage_rows = [r for r in read_csv(f'{output_dir}/lift-usage-tracking.csv') if r.get('date', '') >= week_start]
total_output_tokens = sum(int(r.get('output_tokens', 0)) for r in usage_rows)
builder_tokens = sum(int(r.get('output_tokens', 0)) for r in usage_rows if r.get('run', '').isdigit())
discover_tokens = sum(int(r.get('output_tokens', 0)) for r in usage_rows if r.get('run') == 'discover')

# ── Discovery ──
discovery_rows = [r for r in read_csv(f'{output_dir}/lift-discovery-metrics.csv') if r.get('date', '') >= week_start]
discoveries_created = sum(int(r.get('discoveries_count', 0)) for r in discovery_rows)
discovery_runs = len(discovery_rows)

# ── Tuning ──
tune_rows = [r for r in read_csv(f'{output_dir}/lift-tune-log.csv') if r.get('date', '') >= week_start]
tune_changes = len(tune_rows)

# ── Anomalies ──
anomalies = []
if stall_rate > 40:
    anomalies.append(f'High stall rate: {stall_rate:.0f}% (target: <30%)')
if total_commits == 0 and total_iterations > 0:
    anomalies.append('Zero commits this week despite running iterations')
if discoveries_created == 0 and discovery_runs > 0:
    anomalies.append('Discovery ran but created zero issues')
if nights_run == 0:
    anomalies.append('No pipeline runs detected this week')
# Builder scheduled Mon-Fri; >=3 days since the last iteration means at least one
# weekday run was missed — the signature of a hung/blocked builder holding its
# launchd slot. 999 = never ran (no metrics history at all).
if days_since_builder is None:
    anomalies.append('Builder has no run history — has it ever run?')
elif days_since_builder >= 3:
    anomalies.append(f'Builder has not run in {days_since_builder} days (last: {last_builder_date}; expected Mon-Fri nightly) — check for a hung/blocked builder holding its launchd slot')

# ── Output ──
report = {
    'period': f'{week_start} to {now.strftime("%Y-%m-%d")}',
    'nights_run': nights_run,
    'last_builder_date': last_builder_date or 'never',
    'days_since_builder': days_since_builder if days_since_builder is not None else 999,
    'avg_builder_min': round(avg_builder_min, 1),
    'total_iterations': total_iterations,
    'successful_iterations': successful,
    'stalls': stalls,
    'failures': failures,
    'stall_rate': round(stall_rate, 1),
    'total_commits': total_commits,
    'commits_per_iter': round(commits_per_iter, 1),
    'total_output_tokens': total_output_tokens,
    'builder_tokens': builder_tokens,
    'discover_tokens': discover_tokens,
    'discovery_runs': discovery_runs,
    'discoveries_created': discoveries_created,
    'tune_changes': tune_changes,
    'anomalies': anomalies,
}
print(json.dumps(report))
PYEOF
)

# Parse JSON into bash variables
PERIOD=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['period'])")
NIGHTS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['nights_run'])")
LAST_BUILDER=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['last_builder_date'])")
DAYS_SINCE_BUILDER=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['days_since_builder'])")
AVG_MIN=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['avg_builder_min'])")
ITERATIONS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_iterations'])")
SUCCESSFUL=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['successful_iterations'])")
STALLS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['stalls'])")
STALL_RATE=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['stall_rate'])")
COMMITS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_commits'])")
COMMITS_PER=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['commits_per_iter'])")
TOKENS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_output_tokens'])")
BUILDER_TOKENS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['builder_tokens'])")
DISCOVER_TOKENS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['discover_tokens'])")
DISC_RUNS=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['discovery_runs'])")
DISC_CREATED=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['discoveries_created'])")
TUNE_CHANGES=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['tune_changes'])")
ANOMALIES=$(echo "$REPORT_DATA" | python3 -c "import json,sys; a=json.load(sys.stdin)['anomalies']; print('\n'.join(f'  ⚠️ {x}' for x in a) if a else '  ✅ No anomalies')")

# Current backlog depth
BACKLOG_COUNT=$({ bash "$TRACKER" list backlog unstarted started 2>/dev/null | grep -c "${ISSUE_PREFIX}-" || echo "0"; } | head -1)

# ── Delivery / flow metrics ──────────────────────────────────────────────────
# The activity metrics above measure effort (iterations, commits, tokens).
# These measure outcomes: PRs merged, merge rate, time-to-merge, review-queue
# aging, and tokens per merged PR — the numbers that say whether the pipeline
# is actually delivering, not just running. Pure gh + python (no AI tokens);
# every failure path degrades to zeros so the report still renders when gh is
# unavailable or the repo var is unset (e.g. test mode).
FLOW_DATA=$(gh pr list --repo "${GITHUB_ISSUES_REPO:-}" --state all --limit 200 \
  --json number,createdAt,closedAt,mergedAt,state 2>/dev/null \
  | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
zeros = {'merged': 0, 'closed_unmerged': 0, 'merge_rate': 0, 'avg_ttm_h': 0, 'open_prs': 0, 'oldest_open_days': 0}
try:
    prs = json.load(sys.stdin)
    assert isinstance(prs, list)
except Exception:
    print(json.dumps(zeros)); sys.exit(0)
now = datetime.now(timezone.utc)
week_ago = now - timedelta(days=7)

def ts(s):
    try:
        return datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except Exception:
        return None

merged = [p for p in prs if isinstance(p, dict) and ts(p.get('mergedAt')) and ts(p['mergedAt']) >= week_ago]
closed_unmerged = [p for p in prs if isinstance(p, dict) and not p.get('mergedAt')
                   and ts(p.get('closedAt')) and ts(p['closedAt']) >= week_ago]
open_prs = [p for p in prs if isinstance(p, dict) and p.get('state') == 'OPEN']
ttm = [(ts(p['mergedAt']) - ts(p['createdAt'])).total_seconds() / 3600
       for p in merged if ts(p.get('createdAt'))]
decided = len(merged) + len(closed_unmerged)
print(json.dumps({
    'merged': len(merged),
    'closed_unmerged': len(closed_unmerged),
    'merge_rate': round(len(merged) / decided * 100) if decided else 0,
    'avg_ttm_h': round(sum(ttm) / len(ttm), 1) if ttm else 0,
    'open_prs': len(open_prs),
    'oldest_open_days': max(((now - ts(p['createdAt'])).days for p in open_prs if ts(p.get('createdAt'))), default=0),
}))
" 2>/dev/null || echo '{"merged":0,"closed_unmerged":0,"merge_rate":0,"avg_ttm_h":0,"open_prs":0,"oldest_open_days":0}')
MERGED=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['merged'])" 2>/dev/null || echo "0")
CLOSED_UNMERGED=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['closed_unmerged'])" 2>/dev/null || echo "0")
MERGE_RATE=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['merge_rate'])" 2>/dev/null || echo "0")
AVG_TTM_H=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['avg_ttm_h'])" 2>/dev/null || echo "0")
OPEN_PRS=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['open_prs'])" 2>/dev/null || echo "0")
OLDEST_OPEN_DAYS=$(echo "$FLOW_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['oldest_open_days'])" 2>/dev/null || echo "0")

# Tokens per merged PR — the cost-of-delivery number that ties the token budget
# to actual output. "n/a" when nothing merged this week.
TOKENS_PER_PR=$(python3 -c "
m = int('${MERGED:-0}' or 0); t = int('${TOKENS:-0}' or 0)
print(f'{t // m:,}' if m else 'n/a')
" 2>/dev/null || echo "n/a")

# Flow anomalies. Guard: python's anomaly list prints '  ✅ No anomalies' when
# empty — replace that placeholder instead of appending after it.
append_anomaly() {
  if echo "$ANOMALIES" | grep -q "No anomalies"; then
    ANOMALIES="  ⚠️ $1"
  else
    ANOMALIES+="
  ⚠️ $1"
  fi
}
if [ "${OLDEST_OPEN_DAYS:-0}" -ge 7 ] 2>/dev/null; then
  append_anomaly "Review queue aging: oldest open PR is ${OLDEST_OPEN_DAYS}d old ($OPEN_PRS open) — merge or close it; the builder gates new work at MAX_OPEN_PRS"
fi
DECIDED=$((MERGED + CLOSED_UNMERGED))
if [ "$DECIDED" -ge 4 ] 2>/dev/null && [ "${MERGE_RATE:-100}" -lt 50 ] 2>/dev/null; then
  append_anomaly "Low merge rate: ${MERGE_RATE}% of decided PRs merged this week — check data/lift-build-learnings.md for the rejection pattern"
fi

# ── GA release burndown ──────────────────────────────────────────────────────
# The 2026-08-21 GA shift re-aimed the whole pipeline at stabilization, but
# stabilization needs a termination condition. Convention: a GitHub milestone
# (default 'GA', override via GA_MILESTONE) holds the release-blocking issues;
# this reports progress toward closing it out.
GA_MILESTONE="${GA_MILESTONE:-GA}"
GA_LINE=$(gh api "repos/${GITHUB_ISSUES_REPO:-}/milestones?state=all" 2>/dev/null \
  | GA_MILESTONE="$GA_MILESTONE" python3 -c "
import json, sys, os
title = os.environ.get('GA_MILESTONE', 'GA')
try:
    ms = json.load(sys.stdin)
    assert isinstance(ms, list)
except Exception:
    sys.exit(0)
for m in ms:
    if isinstance(m, dict) and m.get('title') == title:
        o, c = int(m.get('open_issues') or 0), int(m.get('closed_issues') or 0)
        total = o + c
        pct = round(c / total * 100) if total else 0
        print(f'{c}/{total} closed ({pct}%) — {o} open issue(s) to GA')
        break
" 2>/dev/null || true)
[ -z "$GA_LINE" ] && GA_LINE="milestone \"$GA_MILESTONE\" not found — create it in ${GITHUB_ISSUES_REPO:-the project repo} and tag GA-blocking issues to track release burndown"

# ── launchd service health ───────────────────────────────────────────────────
# Was a hardcoded three-service loaded/not-loaded check until 2026-08-28, which
# is why `tune-budget` (exit 126 since its first run) and `roadmap-synth`
# (exit 1 every week since 2026-05-06) stayed broken for months: neither was in
# the list, and the check never looked at exit codes anyway. Now derived from
# the committed plists, so a new service is covered the moment it is added.
LC_SNAPSHOT="$OUTPUT_DIR/.launchctl-list.txt"
launchctl list > "$LC_SNAPSHOT" 2>/dev/null || true
SERVICE_FINDINGS=$(service_health_check \
  "$LC_SNAPSHOT" \
  "$SCRIPT_DIR/../launchd" \
  "${LAUNCHD_LOG_DIR:-$HOME/Documents/Claude/outputs}" || true)
rm -f "$LC_SNAPSHOT"

if [ -n "$SERVICE_FINDINGS" ]; then
  # append_anomaly (defined above) replaces the "✅ No anomalies" placeholder on
  # the first finding instead of listing warnings underneath it.
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    append_anomaly "$_f"
  done <<< "$SERVICE_FINDINGS"
fi
SERVICES_OK=$([ -z "$SERVICE_FINDINGS" ] && echo true || echo false)

# Write report
cat > "$REPORT" << REPORT_EOF
# Weekly Health Report — $DATE

**Period:** $PERIOD
**Generated:** $(date)

## Pipeline Activity
- **Nights run:** $NIGHTS
- **Last builder run:** $LAST_BUILDER (${DAYS_SINCE_BUILDER}d ago)
- **Avg builder runtime:** ${AVG_MIN}m
- **Builder iterations:** $ITERATIONS ($SUCCESSFUL successful, $STALLS stalls)
- **Stall rate:** ${STALL_RATE}%
- **Commits:** $COMMITS (${COMMITS_PER}/iteration)

## Token Usage
- **Total output tokens:** $TOKENS
- **Builder:** $BUILDER_TOKENS
- **Discovery:** $DISCOVER_TOKENS

## Discovery
- **Runs:** $DISC_RUNS
- **Issues created:** $DISC_CREATED

## Delivery
- **PRs merged (7d):** $MERGED
- **PRs closed unmerged (7d):** $CLOSED_UNMERGED
- **Merge rate:** ${MERGE_RATE}%
- **Avg time-to-merge:** ${AVG_TTM_H}h
- **Open PRs:** $OPEN_PRS (oldest: ${OLDEST_OPEN_DAYS}d)
- **Output tokens per merged PR:** $TOKENS_PER_PR

## GA Burndown
- $GA_LINE

## Backlog
- **Open issues:** $BACKLOG_COUNT

## Tuning
- **Budget adjustments:** $TUNE_CHANGES

## Services
$(if $SERVICES_OK; then
    echo "✅ All $(ls "$SCRIPT_DIR/../launchd"/*.plist 2>/dev/null | wc -l | tr -d ' ') launchd services loaded and last exited cleanly"
  else
    echo "$SERVICE_FINDINGS" | sed 's/^/- ⚠️ /'
  fi)

## Anomalies
$ANOMALIES
REPORT_EOF

echo "📋 Report saved: $REPORT"
cat "$REPORT"

# Post to Slack
if [ "$DRY_RUN" != "--dry-run" ]; then
  # Determine trend indicators
  STALL_EMOJI=$(python3 -c "print('🟢' if $STALL_RATE < 20 else '🟡' if $STALL_RATE < 40 else '🔴')" 2>/dev/null)
  COMMITS_EMOJI=$(python3 -c "print('🟢' if $COMMITS > 10 else '🟡' if $COMMITS > 3 else '🔴')" 2>/dev/null)

  HEALTH_MSG="🏥 *Weekly Health Report — $DATE*
_${PERIOD}_

*Pipeline*
  • Nights run: *$NIGHTS*
  • Avg builder runtime: *${AVG_MIN}m*
  • Iterations: *$ITERATIONS* ($SUCCESSFUL successful, $STALLS stalls)
  • ${STALL_EMOJI} Stall rate: *${STALL_RATE}%*
  • ${COMMITS_EMOJI} Commits: *$COMMITS* (${COMMITS_PER}/iteration)

*Tokens*
  • Total output: *$TOKENS*
  • Builder: $BUILDER_TOKENS | Discovery: $DISCOVER_TOKENS

*Delivery*
  • Merged: *$MERGED* | Closed unmerged: $CLOSED_UNMERGED | Merge rate: *${MERGE_RATE}%*
  • Avg time-to-merge: ${AVG_TTM_H}h | Open PRs: $OPEN_PRS (oldest ${OLDEST_OPEN_DAYS}d)
  • Tokens per merged PR: $TOKENS_PER_PR

*GA burndown*
  • $GA_LINE

*Discovery & Backlog*
  • Discovery: $DISC_RUNS runs → $DISC_CREATED issues created
  • Open backlog: *$BACKLOG_COUNT* issues
  • Budget adjustments: $TUNE_CHANGES

*Status*
$ANOMALIES

<$(bash "$TRACKER" board-url)|Issue Board>"
  bash "$NOTIFY" --as health send changelog "$HEALTH_MSG"
  bash "$NOTIFY" --as health send automation "$HEALTH_MSG"
  echo "📨 Posted to #pilot and #lift-automation"
fi

# Log rotation — archive files older than 14 days
log_rotate
