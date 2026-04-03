# Architecture

## Design Principles

Pilot applies distributed systems patterns to a local automation pipeline:

1. **Service decomposition** — Each pipeline stage runs independently on its own schedule via launchd. No stage blocks another.
2. **Eventual consistency** — Stages communicate through the issue tracker's state machine (Backlog → Unstarted → Done). Discovery creates issues today; the builder implements them tomorrow. No tight coupling.
3. **Backpressure** — When the builder runs low on work, it signals discovery to run an extra session via a flag file.
4. **Idempotency** — Every script is safe to re-run. Triage skips already-triaged issues. Cleanup skips already-archived issues. The builder skips completed work.
5. **Graceful degradation** — If discovery fails, triage still works (processes existing backlog). If Gemini is down, triage falls back to Claude. If Slack is down, builds still run.
6. **Observability** — Structured logging (`lib/log.sh`), per-component metrics CSVs, weekly health reports, and Slack alerting on errors.

## Pipeline Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    OVERNIGHT PIPELINE                        │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐               │
│  │ Discovery │───▶│  Triage  │───▶│ Builder  │               │
│  │ (research │    │ (review  │    │ (code    │               │
│  │ + issues) │    │ + plan)  │    │ + ship)  │               │
│  └──────────┘    └──────────┘    └──────────┘               │
│  3x/week          3x/week        Mon-Fri                    │
│       │               │               │                      │
│       ▼               ▼               ▼                      │
│  Issues created  Impl. plans     Commits, PRs,              │
│  in tracker      added           tracker updated             │
│                                       │                      │
│                              ┌────────┴────────┐            │
│                              │ PR Review        │            │
│                              │ + CI Check       │            │
│                              │ + Cleanup        │            │
│                              └────────┬────────┘            │
│                                       │                      │
│                              ┌────────┴────────┐            │
│                              │ Backpressure     │            │
│                              │ Signal           │            │
│                              └─────────────────┘            │
└─────────────────────────────────────────────────────────────┘

Weekly (Sunday):
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ Budget   │  │ Review   │  │ Health   │
  │ Tuner    │  │ Tuner    │  │ Report   │
  └──────────┘  └──────────┘  └──────────┘
```

## Data Flow

```
Discovery (Gemini research + Claude analysis)
    ↓
Issue tracker: new issues in Backlog state
    ↓
Triage (Gemini/Claude review) → issues APPROVED, ENHANCED, RESCOPED, SKIPPED, or FLAGGED → approved move to Unstarted with impl. plans
    ↓
Builder (Claude Opus) → code committed, PR created, issues marked Done
    ↓
PR Review (3-layer: Flash gate → Pro architecture → Sonnet self-check) → review comments posted
    ↓
CI Check → pass/fail reported in Slack thread
    ↓
Cleanup → completed/canceled issues archived, duplicates removed
    ↓
Backpressure → if backlog low, flag file triggers extra discovery
    ↓
You (morning) → review PR, merge, triage flagged issues
    ↓
Feedback loop → your corrections improve future reviews + triage
```

## Shared State

The issue tracker (default: Linear) acts as the message queue between stages:

- **Backlog** — Discovery creates issues here
- **Unstarted** — Triage promotes approved issues here (builder picks from this state)
- **Started** — Builder marks issues in progress
- **Done** — Builder marks completed work
- **Canceled** — Cleanup archives these

Stages don't communicate directly — they read/write tracker state independently.

## Scheduling

Each stage runs on its own launchd schedule:

| Service | Schedule | Script |
|---------|----------|--------|
| Discovery | Sun/Tue/Thu 22:00 | `scripts/discover.sh` |
| Triage | Sun/Tue/Thu 22:30 | `scripts/triage.sh` |
| Builder | Mon-Fri 23:00 | `scripts/builder.sh` |
| Budget Tuner | Sunday 21:00 | `scripts/tune-budget.sh` |
| Review Tuner | Sunday 21:15 | `scripts/tune-reviews.sh` |
| Health Report | Sunday 08:00 | `scripts/health-report.sh` |

Schedules are configurable in `project.env` and generated by `init.sh`.

## Self-Tuning

See [tuning.md](tuning.md) for details on how the pipeline optimizes itself.

## Review Pipeline

PR reviews use a 3-layer cross-model system with failover chains:

| Layer | Model | Purpose | Failover |
|-------|-------|---------|----------|
| Layer 1 | Gemini Flash | Mechanical gate — lint, types, test coverage, naming | Gemini Pro |
| Layer 2 | Gemini Pro | Architecture review — design patterns, coupling, scalability | Claude Sonnet |
| Layer 3 | Claude Sonnet | Self-check — the builder model reviews its own work for blind spots | Gemini Pro |

Each layer produces a structured verdict. Results are combined into a `REVIEW_CROSSCHECK` output that flags disagreements between reviewers. If a layer's primary model fails, it falls back to the failover model automatically.

## Triage Verdicts

Triage evaluates each discovered issue and assigns one of:

- **APPROVED** — ready to implement as-is
- **ENHANCED** — approved with modifications to scope or approach
- **RESCOPED** — issue is valid but needs to be broken into smaller pieces or redirected
- **SKIPPED** — not worth implementing (duplicate, out of scope, too risky)
- **FLAGGED** — needs human review before proceeding

## Test Suite

The pipeline includes 113 bats tests validating adapter contracts and pipeline logic:

- **Two-tier execution** — fast unit tests run on every commit via pre-commit hook; slower integration tests run on demand
- **Pre-commit hook** — blocks commits that break adapter contracts or core pipeline functions
- Tests cover: adapter interface compliance, state machine transitions, error handling, log formatting

## Bot Identity System

The `notify.sh` adapter supports an `--as <identity>` flag that changes the bot name and icon in Slack messages. This lets each pipeline stage post as a distinct identity (e.g., builder, reviewer, triage) for easier scanning of notification channels.

## Isolation

The builder uses a **git worktree** (`$REPO-builder`) so it never touches your working directory. You can work on the same repo simultaneously without conflicts.
