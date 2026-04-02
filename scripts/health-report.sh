#!/bin/bash
# Weekly Health Report — aggregates metrics across all pipeline components.
# No AI tokens consumed — pure bash + python3 data analysis.
#
# Reads: lift-runtime.csv, lift-usage-tracking.csv, lift-metrics.csv,
#        lift-tune-log.csv, lift-discovery-metrics.csv
# Writes: lift-weekly-health-YYYY-MM-DD.md
# Posts: summary to #system-changelog via webhook
#
# Usage:
#   ./health-report.sh              # generate and post
#   ./health-report.sh --dry-run    # generate only, don't post

set -uo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"

DATE=$(date +%Y-%m-%d)
DRY_RUN="${1:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
REPORT="$OUTPUT_DIR/lift-weekly-health-$DATE.md"

# CSVs
RUNTIME_CSV="$OUTPUT_DIR/lift-runtime.csv"
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

output_dir = os.environ.get('OUTPUT_DIR', os.path.expanduser('~/Documents/Claude/outputs'))

now = datetime.now()
week_ago = now - timedelta(days=7)
week_start = week_ago.strftime('%Y-%m-%d')

def read_csv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

# ── Runtime ──
runtime_rows = [r for r in read_csv(f'{output_dir}/lift-runtime.csv') if r.get('date', '') >= week_start]
total_pipeline_min = sum(int(r.get('total_sec', 0)) for r in runtime_rows) / 60
avg_pipeline_min = total_pipeline_min / len(runtime_rows) if runtime_rows else 0
nights_run = len(runtime_rows)

# ── Builder metrics ──
metrics_rows = [r for r in read_csv(f'{output_dir}/lift-metrics.csv') if r.get('date', '') >= week_start]
total_commits = sum(int(r.get('commits', 0)) for r in metrics_rows)
total_iterations = len(metrics_rows)
successful = sum(1 for r in metrics_rows if r.get('success') == 'true')
stalls = sum(1 for r in metrics_rows if r.get('success') == 'stall')
failures = sum(1 for r in metrics_rows if r.get('success') == 'false')
stall_rate = stalls / total_iterations * 100 if total_iterations else 0
commits_per_iter = total_commits / successful if successful else 0

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

# ── Output ──
report = {
    'period': f'{week_start} to {now.strftime("%Y-%m-%d")}',
    'nights_run': nights_run,
    'avg_pipeline_min': round(avg_pipeline_min, 1),
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
AVG_MIN=$(echo "$REPORT_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin)['avg_pipeline_min'])")
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
BACKLOG_COUNT=$(bash "$TRACKER" list backlog unstarted started 2>/dev/null | grep -c "${LINEAR_TEAM}-" || echo "0")

# Check launchd services are loaded
LOADED_SERVICES=$(launchctl list 2>/dev/null || true)
MISSING_SERVICES=""
for svc in pilot-discover pilot-triage pilot-builder; do
  if ! echo "$LOADED_SERVICES" | grep -q "com.aaron.$svc"; then
    MISSING_SERVICES+="
  ⚠️ launchd service $svc is not loaded"
  fi
done
if [ -n "$MISSING_SERVICES" ]; then
  ANOMALIES+="$MISSING_SERVICES"
fi
SERVICES_OK=$([ -z "$MISSING_SERVICES" ] && echo true || echo false)

# Write report
cat > "$REPORT" << REPORT_EOF
# Weekly Health Report — $DATE

**Period:** $PERIOD
**Generated:** $(date)

## Pipeline Activity
- **Nights run:** $NIGHTS
- **Avg pipeline runtime:** ${AVG_MIN}m
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

## Backlog
- **Open issues:** $BACKLOG_COUNT

## Tuning
- **Budget adjustments:** $TUNE_CHANGES

## Services
$(if $SERVICES_OK; then echo "✅ All launchd services loaded"; else echo "⚠️ Some services missing — check launchctl"; fi)

## Anomalies
$ANOMALIES
REPORT_EOF

echo "📋 Report saved: $REPORT"
cat "$REPORT"

# Post to Slack
if [ "$DRY_RUN" != "--dry-run" ]; then
  bash "$NOTIFY" send changelog "📊 *Weekly Health Report — $DATE*
*$PERIOD*

*Pipeline:* $NIGHTS nights | ${AVG_MIN}m avg | $COMMITS commits | ${STALL_RATE}% stall rate
*Tokens:* $TOKENS output (builder: $BUILDER_TOKENS, discovery: $DISCOVER_TOKENS)
*Discovery:* $DISC_RUNS runs, $DISC_CREATED issues created
*Backlog:* $BACKLOG_COUNT open issues
*Tuning:* $TUNE_CHANGES adjustments

$ANOMALIES"
  echo "📨 Posted to #system-changelog"
fi
