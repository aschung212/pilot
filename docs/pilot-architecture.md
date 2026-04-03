---
type: system-reference
tags:
  - pilot
  - architecture
  - automation
updated: 2026-04-02
---

# Pilot Architecture

> [!info] How the Pilot pipeline works end-to-end.
> For Aaron's responsibilities within this pipeline, see [Pilot Responsibilities](pilot-responsibilities.md).

---

## Pipeline Overview

Aaron's Pilot pipeline is a decomposed multi-agent pipeline that discovers, triages, implements, and reviews improvements to the Lift workout tracker. Each stage runs independently on its own schedule via launchd. The system is version controlled at [github.com/aschung212/pilot](https://github.com/aschung212/pilot).

```
┌─────────────────────────────────────────────────────────────┐
│                DECOMPOSED OVERNIGHT PIPELINE                  │
│            (independent services via launchd)                │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐               │
│  │ Discovery │───▶│  Triage  │───▶│  Builder │               │
│  │ (Gemini  │    │ (Gemini  │    │  (Opus)  │               │
│  │ + Claude)│    │  Flash)  │    │    +     │               │
│  └──────────┘    └──────────┘    │ 3-layer  │               │
│       │               │          │ review   │               │
│       ▼               ▼          └──────────┘               │
│  Linear issues   Comments with       │                      │
│  created         impl. plans    Per-issue PRs               │
│                                 (branch per issue,          │
│                                  inline review)             │
│                                       │                      │
│                                  ┌────┴─────┐               │
│                                  │Auto-Tuners│               │
│                                  │(budget +  │               │
│                                  │ reviews)  │               │
│                                  └────┬─────┘               │
│                                       │                      │
│                                  ┌────┴─────┐               │
│                                  │  Cleanup  │               │
│                                  │ (archive  │               │
│                                  │ + dedup)  │               │
│                                  └──────────┘               │
└─────────────────────────────────────────────────────────────┘
                          │
                    6:15 AM ─ Linear digest posted
                          │
                    6:30 AM ─ Aaron's day starts
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    AARON'S MORNING                           │
│                   (~15 min total)                            │
│                                                              │
│  1. Open Slack #lift-automation                               │
│  2. Read nightly summary — PRs as "Ready to merge" or        │
│     "Needs review"                                            │
│  3. Merge green PRs directly (CI passed, 3-layer review      │
│     clean — verdict: MERGE)                                   │
│  4. Open yellow PRs (verdict: REVIEW), read review comments, │
│     decide                                                    │
│  5. Failed PRs auto-retry next night — ignore them           │
│  6. Glance at flagged issues — make decisions                │
│  7. Run /ai-review                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Agents

### 1. Discovery Agent
**Script:** `~/Documents/Scripts/lift-discover.sh`
**Schedule:** Nightly at 11 PM (first stage of overnight pipeline)
**Models:** Gemini 2.5 Flash (web research) + Claude Opus (analysis)

**What it does:**
- Phase 1 (Gemini): Searches the web for the current focus area — competitors, UI trends, performance, accessibility, testing, SEO, data viz, onboarding, DX/CI, PWA patterns, security, monetization
- Phase 2 (Claude): Cross-references findings against the codebase, existing backlog, canceled issues, and product decisions. Creates specific, actionable Linear issues.

**Focus area rotation:** 12 focus areas in a weighted 19-slot cycle (~3 weeks). High-value areas (competitors, UI trends) run every ~6 days. Slow-moving areas (security, monetization) run every ~19 days.

**Self-improvement:** Reads [product decisions](pilot-responsibilities.md#product-decisions) and canceled issues to avoid recreating rejected features.

### 2. Triage Agent
**Script:** `~/Documents/Scripts/lift-triage.sh`
**Schedule:** Nightly after discovery (second stage)
**Model:** Gemini 2.5 Flash (with Claude Sonnet fallback)

**What it does:**
- Reviews every untriaged backlog issue
- Gathers context: issue details, relevant source files, product decisions, dependencies
- For each issue, outputs a verdict:
  - **APPROVE** — adds implementation plan as a Linear comment
  - **ENHANCE** — refines scope, adds plan, adjusts priority
  - **SKIP** — deprioritizes with explanation (Aaron can override)
  - **FLAG** — marks for Aaron's manual decision
  - **RESCOPE** — splits oversized issues into 2-4 focused sub-issues and cancels the original
- Marks issues as triaged so they aren't re-reviewed

**Why it matters:** The builder (Opus) reads these comments before implementing. Better plans = stronger implementations. Aaron spends less time triaging raw issues.

### 3. Overnight Builder
**Script:** `~/development/pilot/scripts/builder.sh`
**Shared lib:** `~/development/pilot/lib/builder-utils.sh` (budget guards, verdict logic, review formatting)
**Schedule:** Nightly after triage (third stage, runs until 7 AM)
**Model:** Claude Opus 4.6

**What it does:**
- Picks the highest-priority triaged issue from Linear
- Reads the triage agent's implementation plan from comments
- Creates a dedicated branch per issue: `enhance/MAS-{id}-{date}`
- Implements the change: writes code, runs tests, commits with conventional prefixes (feat/fix/a11y/test/perf/style/refactor/chore)
- Per-iteration 3-layer cross-model review after each iteration's commits (see section 4 below)
  - Critical/high findings → Opus auto-fix attempt; if fix fails, revert + create Linear issue
  - Medium/low findings → auto-created as Linear issues for future work
- Creates a PR per issue with structured description: Linear links, test results, review status
- PRs labeled by type (type:a11y, type:test, type:bugfix, type:feature, etc.)
- Failed PR retry: PRs labeled `ci:failed` from previous nights are auto-retried
- Updates Linear (marks issues Done/In Progress/Blocked)
- Repeats for up to 12 iterations or 500K output tokens

**Controls** (auto-tuned nightly by `lift-tune-budget.sh`):
- Max iterations per night (default: 12)
- Max output tokens per night (default: 500K)
- Cooldown between iterations (default: 30s)
- Stops on 3 consecutive failures or 2 consecutive stalls
- Runtime tracked per-iteration and per-pipeline — tuner uses utilization % to adjust caps

### 4. 3-Layer Cross-Model Review (inline)
**When:** After each iteration's commits (integrated into builder loop, not a separate stage)
**Models:** Gemini 2.5 Flash (L1) → Gemini 2.5 Pro (L2) → Claude Sonnet 4.6 (L3)

**What it does:**
- 3-layer review of the diff produced by the current iteration, using cross-model validation:
  - **Layer 1 — Gemini Flash (mechanical gate):** Bugs, types, CSS, security. Runs on every iteration. Fast (~30s).
  - **Layer 2 — Gemini Pro (architecture):** Cross-component issues, edge cases, missed scenarios. Runs conditionally — only when L1 has findings OR the change is a feat/fix category.
  - **Layer 3 — Claude Sonnet (self-check):** Known Opus failure patterns, validates Gemini findings, catches what Gemini misses. Runs conditionally (same trigger as L2).
- **Conditional deep review:** Clean low-risk PRs get Layer 1 only (~1 min). High-risk or flagged PRs get all 3 layers (~5 min). This saves time and tokens on routine changes.
- **Failover chains** (build never blocks on failed review):
  - L1: Flash → Sonnet → skip
  - L2: Pro → Flash (deeper prompt) → skip
  - L3: Sonnet → Haiku → skip
- **Verdicts:** MERGE (green) / REVIEW (yellow) / DO NOT MERGE (red)
- **Finding statuses:** Fixed (auto-fixed by Opus) / Deferred (Linear issue created) / Noted (informational)
- **Auto-fix cycle:** Critical/high findings trigger an Opus fix attempt before PR creation. If fix fails, changes are reverted and a Linear issue is created.
- Medium/low findings → auto-created as Linear issues for future work (does not block PR)
- Review verdicts and findings included in structured PR description so Aaron sees status at a glance

**Self-improvement:** All review layers receive a learnings file (`lift-review-learnings.md`) that accumulates patterns from Aaron's past PR feedback. The review tuner (`lift-tune-reviews.sh`) analyzes merged PRs to detect what reviewers miss and injects those patterns into future prompts.

> **Note:** The previous single-layer Sonnet review has been replaced by the 3-layer cross-model system. Different models catch different classes of issues, and conditional execution keeps review fast for clean changes.

### 5. Auto-Tuners
**Scripts:** `lift-tune-budget.sh` + `lift-tune-reviews.sh`
**When:** After each overnight session completes

**Budget tuner:**
- Analyzes last 7 nights of token usage and runtime
- Adjusts iteration cap, token cap, and cooldown based on productivity patterns
- Raises caps when consistently productive, lowers when stalling
- Runtime-aware: if pipeline uses <25% of the overnight window, suggests raising iteration cap
- Detects context bloat: flags when per-iteration duration trends up >50%

**Review tuner:**
- Analyzes merged PRs: what reviewers flagged vs. what Aaron caught
- Tracks clean merge rate (goal: 100%)
- Builds custom rules from Aaron's corrections
- Injects learnings into future review prompts

### 6. Linear Cleanup
**Script:** `~/Documents/Scripts/lift-linear-cleanup.sh`
**When:** After each overnight session (final stage of pipeline)

**What it does:**
- Archives all completed and canceled issues via Linear GraphQL API
- Detects duplicate issues by title (keeps oldest, cancels+archives newer copies)
- Preserves free tier capacity — Linear free plan has issue limits

---

## Testing Infrastructure

The pipeline has a bats-core test suite with **113 tests across 16 test files** in `~/development/pilot/tests/`. Tests use two-tier execution to balance speed with thoroughness:

**Fast tier (109 tests) — pre-commit hook:**
- Runs before every commit via `.githooks/pre-commit`
- Covers: unit tests, adapter contract tests, argument parsing, error handling, log formatting
- Builder tests source real functions from `lib/builder-utils.sh` (not copies of logic)
- Parallel execution via GNU parallel (`bats -j 8`)
- Blocks commit if any test fails

**Full tier (113 tests) — GitHub Actions CI:**
- Runs on every push via `.github/workflows/test.yml`
- Includes everything in the fast tier plus integration-level tests (CSV analysis, full script invocations)
- Test paths resolve dynamically (no hardcoded local paths) for CI runner compatibility

**Key testing patterns:**
- **Auto-discovery smoke tests:** Automatically detect new scripts in `scripts/` and `adapters/` that lack corresponding test files. These tests fail when coverage is missing, ensuring the test suite grows with the codebase.
- **Adapter contract tests:** Verify that all swappable adapters (tracker, notify, ai-code, ai-research, ai-review) conform to their expected interface — correct flags, exit codes, and output formats.
- **PATH-based mocking:** Mock commands (claude, gemini, linear, curl, gh) are injected via PATH so scripts under test call mocks instead of real external services. No network calls during tests.
- **Test mode guard:** All scripts check `_PILOT_TEST_MODE=1` and skip `project.env` sourcing when set, allowing tests to run in isolation without Lift-specific configuration.

---

## Scheduled Tasks

Pipeline is fully decomposed — each service has its own launchd plist. No orchestrator.

| Time | Service | Schedule | Plist |
|---|---|---|---|
| 10:00 PM | Discovery | Sun/Tue/Thu | `com.aaron.pilot-discover` |
| 10:30 PM | Triage | Sun/Tue/Thu | `com.aaron.pilot-triage` |
| 11:00 PM | Builder + Cleanup | Mon-Fri | `com.aaron.pilot-builder` |
| 9:00 PM Sun | Budget Tuner | Weekly | `com.aaron.pilot-tune-budget` |
| 9:15 PM Sun | Review Tuner | Weekly | `com.aaron.pilot-tune-reviews` |
| 8:00 AM Sun | Health Report | Weekly | `com.aaron.pilot-health` |
| 6:15 AM | Linear Digest | Daily | `com.aaron.linear-digest` |

---

## Model Allocation

| Agent | Model | Rationale |
|---|---|---|
| Discovery (research) | Gemini 2.5 Flash | Native Google Search, saves Claude tokens |
| Discovery (analysis) | Claude Opus 4.6 | Best at codebase reasoning + issue creation |
| Triage | Gemini 2.5 Flash (Claude Sonnet fallback) | Good at planning, uses Google AI Plus (free) |
| Builder | Claude Opus 4.6 | Best coding model, complex multi-file changes |
| Review L1 (mechanical gate) | Gemini 2.5 Flash | Fast, cheap, good at mechanical checks (bugs, types, CSS, security). Runs every iteration. Fallback: Sonnet → skip |
| Review L2 (architecture) | Gemini 2.5 Pro | Deep architectural reasoning, cross-component analysis. Conditional (L1 findings or feat/fix). Fallback: Flash (deeper prompt) → skip |
| Review L3 (self-check) | Claude Sonnet 4.6 | Catches known Opus failure patterns, validates Gemini findings. Conditional (same as L2). Fallback: Haiku → skip |
| Cover letter review | Gemini 2.5 Flash | Second opinion, zero extra cost |

---

## Slack Channels

| Channel | What posts there |
|---|---|
| #lift-automation | Build iterations, discovery digests, triage summaries, PR reviews, auto-tuner decisions |
| #daily-review | Linear digest (6:15 AM), AI review summaries, LeetCode updates |
| #system-changelog | Workflow changes — posted automatically when scripts or responsibilities change |

**Slack bot identities:** Each agent posts with a distinct username and emoji avatar for visual distinction. The `notify.sh` adapter supports `--as <identity>` flag to set username/icon_emoji per agent. Falls back to Bot API when webhook fails.

| Identity | Username | Avatar |
|---|---|---|
| Builder | Lift Builder | :robot_face: |
| Discovery | Lift Discovery | :globe_with_meridians: |
| Triage | Lift Triage | :vertical_traffic_light: |
| Review Tuner | Lift Review Tuner | :control_knobs: |
| Budget Tuner | Lift Budget Tuner | :control_knobs: |
| Health | Lift Health | :hospital: |

---

## Data Flow

```
Gemini (web research)
    ↓
Claude (analysis) → Linear issues created
    ↓
Gemini (triage) → Implementation plans added as comments
    ↓
Claude Opus (builder) → Per-issue branch + code committed
    ↓
3-Layer Cross-Model Review (per iteration):
    L1: Gemini Flash (mechanical gate — every iteration)
    L2: Gemini Pro (architecture — conditional: L1 findings or feat/fix)
    L3: Claude Sonnet (self-check — conditional: same as L2)
    → Critical/high: Opus auto-fix attempt → if fail, revert + Linear issue
    → Medium/low: Linear issues created (non-blocking)
    → Verdicts: ✅ MERGE | ⚠️ REVIEW | 🚫 DO NOT MERGE
    ↓
Per-issue PR created with structured description (Linear links, test results, review verdicts)
    ↓
CI runs (branch protection requires build-and-test to pass)
    ↓
Auto-tuners → Budget + review prompts adjusted
    ↓
Linear cleanup → Completed/canceled archived, duplicates removed
    ↓
Aaron (morning) → Merges green PRs directly, reviews yellow PRs, ignores failed (auto-retry next night)
    ↓
Feedback loop → Aaron's corrections improve future reviews + discovery
```

---

## Key Files

| File | Purpose |
|---|---|
| `~/development/pilot/` | Version-controlled repo for all pipeline code ([GitHub](https://github.com/aschung212/pilot)) |
| `~/development/pilot/scripts/` | All pipeline scripts (symlinked to `~/Documents/Scripts/`) |
| `~/development/pilot/adapters/` | Swappable tool adapters (tracker, notify, ai-code, ai-research, ai-review) |
| `~/development/pilot/lib/log.sh` | Shared structured logging library |
| `~/development/pilot/config/budget.conf` | Budget config (auto-tuned) |
| `~/development/pilot/tests/` | bats-core test suite (105 tests, 16 files, two-tier execution) |
| `~/development/pilot/.github/workflows/test.yml` | GitHub Actions CI — full test suite on push |
| `~/development/pilot/.githooks/pre-commit` | Pre-commit hook — fast test tier on every commit |
| `~/development/pilot/project.env` | Lift-specific configuration (git-ignored) |
| `~/development/pilot/init.sh` | Interactive setup wizard |
| `~/Documents/Claude/outputs/` | All logs, metrics, usage tracking, learnings |
| `~/Documents/Claude/outputs/pilot-YYYY-MM-DD.log` | Unified structured log (all components) |

See [Pilot Responsibilities](pilot-responsibilities.md) for the complete list of Aaron's manual tasks, automated tasks, environment variables, and changelog.

---

## Changelog

### 2026-04-02 — Builder Overhaul: Branch-per-Issue + 3-Layer Review
- Builder switched from single nightly branch/PR to branch-per-issue (`enhance/MAS-{id}-{date}`) with individual PRs
- Per-iteration review upgraded to 3-layer cross-model system:
  - L1 (Gemini Flash): Mechanical gate — bugs, types, CSS, security. Every iteration.
  - L2 (Gemini Pro): Architecture — cross-component, edge cases. Conditional (L1 findings or feat/fix).
  - L3 (Claude Sonnet): Self-check — Opus failure patterns, validates Gemini. Conditional (same as L2).
  - Failover chains: each layer has primary → fallback → skip (build never blocks)
  - Verdicts: MERGE / REVIEW / DO NOT MERGE; Finding statuses: Fixed / Deferred / Noted
- Conditional deep review: clean low-risk PRs get L1 only (~1 min); high-risk get all 3 layers (~5 min)
- Critical/high findings trigger Opus auto-fix before PR creation
- Conventional commit messages, PR labeling by type, structured PR descriptions
- Failed PRs (`ci:failed`) auto-retried next night
- MAX_ITERATIONS_PER_NIGHT increased from 8 → 12
- Slack bot identities added with specific usernames + emoji avatars per agent
- `notify.sh` gained `--as <identity>` flag; falls back to Bot API when webhook fails
- Branch protection on master: requires build-and-test CI to pass
- Vercel preview deploys per PR; auto-merge enabled
- CI workflow enhanced with Slack notification on post-merge failure
- Aaron's morning workflow simplified: merge green PRs directly, review yellow PRs, ignore failed (auto-retry)

### 2026-04-02 — Test Suite + RESCOPE Verdict
- Added 105-test bats-core suite with two-tier execution (fast: 101 tests pre-commit, full: 105 tests CI on push)
- 16 test files covering scripts, adapters, library functions, and auto-discovery smoke tests
- Auto-discovery smoke tests enforce test coverage for new scripts — suite grows with codebase
- Adapter contract tests verify interface stability across swappable components
- PATH-based mocking (claude, gemini, linear, curl, gh) — no network calls during tests
- `_PILOT_TEST_MODE=1` guard on all scripts for test isolation
- GNU parallel for parallel execution (`bats -j 8`)
- GitHub Actions CI at `.github/workflows/test.yml`; pre-commit hook at `.githooks/pre-commit`
- Added RESCOPE verdict to triage agent: splits oversized issues into 2-4 sub-issues, cancels original
- Added Testing Infrastructure section to this document

### 2026-04-02 — Builder Decomposition
- Extracted 8 utility functions from builder.sh into `lib/builder-utils.sh` (1 new file)
- Functions: `parse_usage`, `usage_check`, `should_continue`, `parse_stop_time`, `pick_worst_verdict`, `verdict_emoji`, `format_review_findings`, `format_review_crosschecks`
- Builder tests now source and test real functions (not inline copies of logic)
- Test count: 105 → 113 (builder tests: 12 → 20)
- Fixed CI: test helper resolves PILOT_DIR dynamically for GitHub Actions runner compatibility

### 2026-04-02 — Full Audit & Parameterization
- **Critical bug fix:** builder.sh was reading budget.conf from ~/Documents/Scripts/ while tune-budget.sh wrote to config/ — tuner updates were being ignored
- Removed all hardcoded `/Users/aaron/development/lift` fallback paths — scripts now fail fast with clear error
- Parameterized all AI prompts: `$PROJECT_NAME`, `$TECH_STACK`, `$PROJECT_DESC` replace hardcoded Lift/Vue/workout references
- Bot identities now use `${PROJECT_NAME:-Pilot}` instead of hardcoded "Lift"
- init.sh updated: 3-layer review config, budget.conf creation, git hooks setup, discovery queue init, bats/parallel/gtimeout checks, digest.sh plist
- project.env.example now documents all 30+ variables
- README, docs/architecture.md, docs/adapters.md updated for 3-layer review, RESCOPE, test suite, bot identities
- Removed 2 orphaned launchd plists, fixed script paths in remaining 6
- Pilot is now fully project-agnostic — configure for any repo via `init.sh`
