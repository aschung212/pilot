#!/bin/bash
# Lift Budget Auto-Tuner — analyzes usage history and adjusts overnight budget config.
# Runs at the end of each overnight session (called by lift-enhance-overnight.sh).
# Learns from: token efficiency, stall rate, iteration productivity, time utilization.
#
# Writes tuning decisions to a log and updates lift-budget.conf.

set -euo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
BUDGET_CONF="${SCRIPT_DIR}/../config/budget.conf"
USAGE_CSV="$OUTPUT_DIR/lift-usage-tracking.csv"
METRICS_CSV="$OUTPUT_DIR/lift-metrics.csv"
RUNTIME_CSV="$OUTPUT_DIR/lift-runtime.csv"
TUNE_LOG="$OUTPUT_DIR/lift-tune-log.csv"

# Initialize tune log if needed
if [ ! -f "$TUNE_LOG" ]; then
  echo "date,iterations_before,iterations_after,tokens_before,tokens_after,cooldown_before,cooldown_after,reasons" > "$TUNE_LOG"
fi

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"

# Need at least 3 nights of data to start tuning
NIGHTS_COUNT=$([ -f "$USAGE_CSV" ] && tail -n +2 "$USAGE_CSV" | cut -d',' -f1 | sort -u | wc -l | tr -d ' ' || echo "0")
if [ "$NIGHTS_COUNT" -lt 3 ]; then
  echo "🎛️ Auto-tuner: ${NIGHTS_COUNT}/3 nights of data collected. Skipping tuning until more data."
  bash "$NOTIFY" --as budget-tuner send automation "🎛️ *Budget Tuner* — ${NIGHTS_COUNT}/3 nights collected, skipping" 2>/dev/null
  exit 0
fi

# Source current config
source "$BUDGET_CONF"
OLD_ITERS="$MAX_ITERATIONS_PER_NIGHT"
OLD_TOKENS="$MAX_OUTPUT_TOKENS_PER_NIGHT"
OLD_COOLDOWN="$ITERATION_COOLDOWN"

# Analyze history and compute new values
TUNING=$(python3 << 'PYEOF'
import csv, json, sys
from collections import defaultdict
from datetime import datetime

usage_csv = sys.argv[1] if len(sys.argv) > 1 else ""
metrics_csv = sys.argv[2] if len(sys.argv) > 2 else ""
runtime_csv = sys.argv[3] if len(sys.argv) > 3 else ""
old_iters = int(sys.argv[4]) if len(sys.argv) > 4 else 8
old_tokens = int(sys.argv[5]) if len(sys.argv) > 5 else 500000
old_cooldown = int(sys.argv[6]) if len(sys.argv) > 6 else 30

# Parse usage data per night
nights = defaultdict(lambda: {
    'iterations': 0, 'total_output': 0, 'total_input': 0,
    'total_cache_read': 0, 'total_duration': 0, 'per_iter_output': [],
    'per_iter_duration': []
})

try:
    with open(usage_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            d = row['date']
            run = row.get('run', 'discover')
            if run == 'discover':
                continue  # skip discovery runs for builder tuning
            out = int(row.get('output_tokens', 0))
            inp = int(row.get('input_tokens', 0))
            cache = int(row.get('cache_read_tokens', 0))
            dur = int(row.get('duration_sec', 0))
            nights[d]['iterations'] = max(nights[d]['iterations'], int(run))
            nights[d]['total_output'] += out
            nights[d]['total_input'] += inp
            nights[d]['total_cache_read'] += cache
            nights[d]['total_duration'] += dur
            nights[d]['per_iter_output'].append(out)
            nights[d]['per_iter_duration'].append(dur)
except FileNotFoundError:
    pass

# Parse runtime data (pipeline-level timings)
runtime_data = {}
try:
    with open(runtime_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            d = row['date']
            runtime_data[d] = {
                'total_sec': int(row.get('total_sec', 0)),
                'discover_sec': int(row.get('discover_sec', 0)),
                'triage_sec': int(row.get('triage_sec', 0)),
                'builder_sec': int(row.get('builder_sec', 0)),
            }
except FileNotFoundError:
    pass

# Parse metrics data for productivity signals
night_productivity = defaultdict(lambda: {'commits': 0, 'stalls': 0, 'failures': 0, 'successes': 0})
try:
    with open(metrics_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            d = row['date']
            commits = int(row.get('commits', 0))
            success = row.get('success', '')
            night_productivity[d]['commits'] += commits
            if success == 'true':
                night_productivity[d]['successes'] += 1
            elif success == 'stall':
                night_productivity[d]['stalls'] += 1
            elif success == 'false':
                night_productivity[d]['failures'] += 1
except FileNotFoundError:
    pass

# Only analyze last 7 nights
sorted_dates = sorted(nights.keys())[-7:]
if len(sorted_dates) < 3:
    print(json.dumps({'skip': True, 'reason': 'insufficient data'}))
    sys.exit(0)

reasons = []
new_iters = old_iters
new_tokens = old_tokens
new_cooldown = old_cooldown

# ── Analysis 1: Iteration productivity ──────────────────────────────────────
# If most nights finish early (hit stall/no-work before cap), lower the cap
# If most nights hit the cap and are still productive, raise it
nights_hit_cap = 0
nights_stalled_early = 0
avg_productive_iters = 0

for d in sorted_dates:
    n = nights[d]
    p = night_productivity.get(d, {'commits': 0, 'stalls': 0, 'successes': 0})
    if n['iterations'] >= old_iters:
        nights_hit_cap += 1
    if p['stalls'] >= 2 or (p['commits'] == 0 and n['iterations'] >= 2):
        nights_stalled_early += 1
    avg_productive_iters += p['successes']

avg_productive_iters = avg_productive_iters / len(sorted_dates)

if nights_hit_cap >= len(sorted_dates) * 0.7 and nights_stalled_early == 0:
    # Consistently hitting cap and still productive — raise by 2
    new_iters = min(old_iters + 2, 15)  # hard max 15
    if new_iters != old_iters:
        reasons.append(f"iterations {old_iters}->{new_iters}: hitting cap {nights_hit_cap}/{len(sorted_dates)} nights, still productive")

elif nights_stalled_early >= len(sorted_dates) * 0.5:
    # Frequently stalling — lower cap to save tokens
    new_iters = max(int(avg_productive_iters + 2), 3)  # at least 3
    if new_iters < old_iters:
        reasons.append(f"iterations {old_iters}->{new_iters}: stalling {nights_stalled_early}/{len(sorted_dates)} nights, avg productive={avg_productive_iters:.0f}")

# ── Analysis 2: Token efficiency ────────────────────────────────────────────
# Track output tokens per productive iteration — if increasing, we may be
# hitting harder problems or context is bloating
avg_output_per_iter = []
for d in sorted_dates:
    for out in nights[d]['per_iter_output']:
        if out > 0:
            avg_output_per_iter.append(out)

if avg_output_per_iter:
    median_output = sorted(avg_output_per_iter)[len(avg_output_per_iter) // 2]
    total_nightly_avg = sum(nights[d]['total_output'] for d in sorted_dates) / len(sorted_dates)

    # Set token cap to 2x the average nightly usage (headroom for variation)
    suggested_tokens = int(total_nightly_avg * 2)
    suggested_tokens = max(suggested_tokens, 200000)  # floor 200K
    suggested_tokens = min(suggested_tokens, 1000000)  # ceiling 1M
    # Round to nearest 50K
    suggested_tokens = round(suggested_tokens / 50000) * 50000

    if abs(suggested_tokens - old_tokens) >= 50000:
        new_tokens = suggested_tokens
        reasons.append(f"tokens {old_tokens}->{new_tokens}: avg nightly output={int(total_nightly_avg)}, median/iter={int(median_output)}")

# ── Analysis 3: Cooldown tuning ─────────────────────────────────────────────
# If we see no rate limit issues (no failures that look rate-related),
# we can reduce cooldown. If we see clustered failures, increase it.
total_failures = sum(night_productivity.get(d, {}).get('failures', 0) for d in sorted_dates)
total_runs = sum(nights[d]['iterations'] for d in sorted_dates)

if total_runs > 0:
    failure_rate = total_failures / total_runs
    if failure_rate > 0.3 and old_cooldown < 120:
        new_cooldown = min(old_cooldown + 15, 120)
        reasons.append(f"cooldown {old_cooldown}s->{new_cooldown}s: failure rate {failure_rate:.0%}")
    elif failure_rate < 0.05 and old_cooldown > 15:
        new_cooldown = max(old_cooldown - 10, 15)
        reasons.append(f"cooldown {old_cooldown}s->{new_cooldown}s: low failure rate {failure_rate:.0%}")

# ── Analysis 4: Runtime efficiency ──────────────────────────────────────────
# Track total pipeline runtime and per-iteration duration trends.
# If builder consistently finishes well before stop time with spare capacity,
# iterations can be raised. If per-iteration time is trending up, flag bloat.
runtime_stats = {}
runtime_dates = [d for d in sorted_dates if d in runtime_data]
if runtime_dates:
    builder_runtimes = [runtime_data[d]['builder_sec'] for d in runtime_dates]
    total_runtimes = [runtime_data[d]['total_sec'] for d in runtime_dates]
    avg_builder_min = sum(builder_runtimes) / len(builder_runtimes) / 60
    avg_total_min = sum(total_runtimes) / len(total_runtimes) / 60
    # Available window is 11 PM to 7 AM = 480 min
    available_min = 480
    utilization_pct = (avg_total_min / available_min) * 100 if available_min > 0 else 0

    runtime_stats = {
        'avg_builder_min': round(avg_builder_min, 1),
        'avg_total_min': round(avg_total_min, 1),
        'utilization_pct': round(utilization_pct, 1),
        'nights_with_runtime': len(runtime_dates),
    }

    # If using <25% of available time and hitting iteration cap, raise cap
    if utilization_pct < 25 and nights_hit_cap >= len(sorted_dates) * 0.5:
        headroom_iters = int(old_iters * (available_min / avg_total_min) * 0.5) if avg_total_min > 0 else old_iters
        suggested_iters = min(headroom_iters, 15)
        if suggested_iters > new_iters:
            new_iters = suggested_iters
            reasons.append(f"iterations {old_iters}->{new_iters}: only using {utilization_pct:.0f}% of overnight window ({avg_total_min:.0f}m/{available_min}m), room for more")

    # If per-iteration duration is trending up (last 3 nights vs first 3), flag context bloat
    if len(runtime_dates) >= 4:
        iter_durations_all = []
        for d in sorted_dates:
            iter_durations_all.extend(nights[d]['per_iter_duration'])
        if len(iter_durations_all) >= 6:
            first_half = iter_durations_all[:len(iter_durations_all)//2]
            second_half = iter_durations_all[len(iter_durations_all)//2:]
            avg_first = sum(first_half) / len(first_half)
            avg_second = sum(second_half) / len(second_half)
            if avg_first > 0 and avg_second / avg_first > 1.5:
                reasons.append(f"⚠️ iteration duration trending up: {avg_first:.0f}s -> {avg_second:.0f}s avg (possible context bloat)")

# ── Output ──────────────────────────────────────────────────────────────────
result = {
    'skip': len(reasons) == 0,
    'new_iters': new_iters,
    'new_tokens': new_tokens,
    'new_cooldown': new_cooldown,
    'reasons': reasons,
    'stats': {
        'nights_analyzed': len(sorted_dates),
        'nights_hit_cap': nights_hit_cap,
        'nights_stalled': nights_stalled_early,
        'avg_productive_iters': round(avg_productive_iters, 1),
        'avg_nightly_output': int(sum(nights[d]['total_output'] for d in sorted_dates) / len(sorted_dates)) if sorted_dates else 0,
        'failure_rate': round(failure_rate, 2) if total_runs > 0 else 0,
        **runtime_stats,
    }
}
print(json.dumps(result))
PYEOF
"$USAGE_CSV" "$METRICS_CSV" "$RUNTIME_CSV" "$OLD_ITERS" "$OLD_TOKENS" "$OLD_COOLDOWN")

# Parse tuning result
SKIP=$(echo "$TUNING" | python3 -c "import json,sys; print(json.load(sys.stdin).get('skip', True))")

if [ "$SKIP" = "True" ]; then
  echo "🎛️ Auto-tuner: no adjustments needed."
  bash "$NOTIFY" --as budget-tuner send automation "🎛️ *Budget Tuner* — analyzed $NIGHTS_COUNT nights, no adjustments needed ✅" 2>/dev/null
  exit 0
fi

# Extract new values
NEW_ITERS=$(echo "$TUNING" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_iters'])")
NEW_TOKENS=$(echo "$TUNING" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_tokens'])")
NEW_COOLDOWN=$(echo "$TUNING" | python3 -c "import json,sys; print(json.load(sys.stdin)['new_cooldown'])")
REASONS=$(echo "$TUNING" | python3 -c "import json,sys; print('; '.join(json.load(sys.stdin)['reasons']))")
STATS=$(echo "$TUNING" | python3 -c "
import json,sys
d=json.load(sys.stdin)['stats']
parts = [f\"nights={d['nights_analyzed']}\", f\"cap_hits={d['nights_hit_cap']}\", f\"stalls={d['nights_stalled']}\", f\"avg_iters={d['avg_productive_iters']}\", f\"avg_output={d['avg_nightly_output']}\", f\"fail_rate={d['failure_rate']}\"]
if 'avg_total_min' in d:
    parts.append(f\"avg_runtime={d['avg_total_min']}m\")
    parts.append(f\"utilization={d['utilization_pct']}%\")
print(' '.join(parts))
")

echo "📊 Auto-tuner adjustments:"
echo "  $REASONS"
echo "  Stats: $STATS"

# Log the tuning decision
DATE=$(date +%Y-%m-%d)
echo "$DATE,$OLD_ITERS,$NEW_ITERS,$OLD_TOKENS,$NEW_TOKENS,$OLD_COOLDOWN,$NEW_COOLDOWN,\"$REASONS\"" >> "$TUNE_LOG"

# Update budget.conf
cat > "$BUDGET_CONF" << CONF
# Lift Overnight Budget Configuration
# Claude Max plan — no per-token cost, but rate limits apply.
# Controls here prevent overnight runs from consuming capacity
# that Aaron needs for interactive use during the day.
#
# Auto-tuned on $DATE: $REASONS

# Max iterations per night — hard cap on builder loop
MAX_ITERATIONS_PER_NIGHT=$NEW_ITERS

# Max output tokens per night — stops builder if cumulative output exceeds this
MAX_OUTPUT_TOKENS_PER_NIGHT=$NEW_TOKENS

# Cooldown between iterations (seconds) — prevents rate limit spikes
ITERATION_COOLDOWN=$NEW_COOLDOWN

# Alert threshold — sends Slack alert when token usage exceeds this % of nightly cap
ALERT_THRESHOLD_PCT=80

# Stop time — builder stops at this time (overridden by CLI arg)
DEFAULT_STOP_TIME=07:00
CONF

echo "  ✅ Updated lift-budget.conf"

# Slack notification via adapter
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
bash "$NOTIFY" --as budget-tuner send automation "🎛️ *Budget Auto-Tuner*
$REASONS
Stats: $STATS" 2>/dev/null
