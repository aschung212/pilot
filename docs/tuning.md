# Self-Tuning

Pilot optimizes itself over time using two mechanisms: a budget tuner and a weekly health report. Together they form a feedback loop that adjusts the pipeline based on observed outcomes.

> The review tuner was removed on 2026-05-11. It was deprecated when the review system moved to inline hooks (no PR comments to learn from); see [pilot-architecture.md](pilot-architecture.md) for the current review pipeline.

## Budget Tuner

**Script:** `scripts/tune-budget.sh`
**Schedule:** Sunday 21:00
**Needs:** 3+ nights of data before first adjustment

Analyzes the last 7 nights and adjusts `config/budget.conf`:

### What it tunes

| Parameter | Default | What triggers a change |
|-----------|---------|----------------------|
| `MAX_ITERATIONS_PER_NIGHT` | 12 | Raise if hitting cap and still productive. Lower if stalling >50% of nights. |
| `MAX_OUTPUT_TOKENS_PER_NIGHT` | 600K | Set to 2x average nightly output. Floor: 200K, ceiling: 1M. |
| `ITERATION_COOLDOWN` | 30s | Raise if failure rate >30%. Lower if <5%. |

### Data sources

- `lift-usage-tracking.csv` — tokens per run
- `lift-metrics.csv` — commits, stalls, failures per iteration
- `lift-runtime.csv` — pipeline duration per night

### Runtime awareness

The tuner also checks overnight window utilization:
- If using <25% of available time and hitting iteration cap → suggests raising cap
- If per-iteration duration trends up >50% → flags possible context bloat

## Health Report

**Script:** `scripts/health-report.sh`
**Schedule:** Sunday 08:00

Weekly dashboard aggregating all pipeline metrics:

### What it reports

- **Pipeline activity** — nights run, avg runtime, iterations, stall rate
- **Token usage** — total, builder vs discovery breakdown
- **Discovery yield** — runs, issues created
- **Backlog depth** — open issues count
- **Tuning changes** — budget adjustments this week
- **Service health** — launchd services loaded check
- **Anomalies** — high stall rate, zero commits, zero discoveries, empty backlog

### Log rotation

The health report also rotates old logs:
- Files >14 days → moved to `outputs/archive/`
- Archives >60 days → deleted

## Backpressure

The builder checks unstarted issue count after each session:
- **< 3 unstarted** → writes `.lift-backlog-low` flag → discovery runs extra session
- **≥ 5 unstarted** → removes flag

This prevents the builder from starving when discovery runs less frequently than the builder.

## Evolution Path

The tuning system is designed to become more autonomous over time:

1. **Week 1-2**: Observe baseline metrics
2. **Week 3-4**: Tuners make first adjustments (iteration caps, token budgets)
3. **Month 2**: Consider automating frequency tuning (how many nights to run discovery/builder)
4. **Month 3+**: Track focus area effectiveness (which discoveries get implemented) and weight the rotation queue accordingly
