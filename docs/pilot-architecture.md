---
type: system-reference
tags:
  - pilot
  - architecture
  - automation
updated: 2026-04-06
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
│  └──────────┘    └──────────┘    │ Gemini   │               │
│       │               │          │ 3.1 Pro │               │
│       ▼               ▼          └──────────┘               │
│  GitHub issues   Comments with        │                      │
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
│  3. Merge green PRs directly (CI passed, Gemini  3.1 Pro    │
│     clean — verdict: MERGE)                                   │
│  4. Open yellow PRs (verdict: REVIEW), read review comments, │
│     decide                                                    │
│  5. Failed PRs auto-retry next night — ignore them           │
│  6. Glance at flagged issues — make decisions                │
│  7. Run /ai-3.1 Pro                                         │
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
- Phase 2 (Claude): Cross-references findings against the codebase, existing backlog, canceled issues, and product decisions. Creates specific, actionable GitHub issues.

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
**Model:** Claude Opus 4.8 (1M context, max effort) — pinned via `AI_CODE_MODEL`/`AI_CODE_EFFORT` in `project.env`

**What it does:**
- Picks the highest-priority triaged issue from the backlog
- Reads the triage agent's implementation plan from comments
- Creates a dedicated branch per issue: `enhance/LIFT-{id}-{date}`
- Implements the change: writes code, runs tests, commits with conventional prefixes (feat/fix/a11y/test/perf/style/refactor/chore)
- Per-iteration Gemini  cross-model review after each iteration's commits (see section 4 below)
  - Critical/high findings → Opus auto-fix attempt; if fix fails, revert + create GitHub issue
  - Medium/low findings → auto-created as Linear issues for future work
- Creates a PR per issue with structured description: issue links, test results, review status
- PRs labeled by type (type:a11y, type:test, type:bugfix, type:feature, etc.)
- Failed PR retry: PRs labeled `ci:failed` from previous nights are auto-retried
- Updates issue tracker (marks issues In Progress/Blocked; closure deferred to PR merge via "Closes #N")
- Repeats for up to 12 iterations or 500K output tokens

**Controls** (auto-tuned nightly by `lift-tune-budget.sh`):
- Max iterations per night (default: 12)
- Max output tokens per night (default: 500K)
- Cooldown between iterations (default: 30s)
- Stops on 3 consecutive failures or 2 consecutive stalls
- Runtime tracked per-iteration and per-pipeline — tuner uses utilization % to adjust caps

**Manual override:** `PICKED_ISSUE_OVERRIDE=LIFT-NNN ./scripts/builder.sh 1` forces the first iteration to work on a specific issue, skipping the pre-pick stage. Intended for one-off "fix this issue now" runs; the override is cleared after use so a multi-iteration loop falls back to normal pre-picking for subsequent iterations.

### 4. Inline Hook-Based Review
**When:** Automatically during Claude's implementation, via git pre-push hook
**Model:** Gemini 3.1 Pro (single model, adversarial review of full branch diff)
**Script:** `~/.claude/scripts/review-router.sh` (builder mode, triggered by `PILOT_BUILDER=1`)

**How it works:**
- **Primary mechanism — git pre-push hook (fires for any git operation, including headless `claude -p` mode):**
  - `.husky/pre-push`: Gemini 3.1 Pro adversarial review before push (blocks until complete)
- **No post-commit hook** — removed 2026-04-06. Gemini Flash had a 71% false positive rate, generating noise that trained developers to ignore review output.
- **No Codex (GPT-5.4)** — removed 2026-04-06. Head-to-head testing showed Gemini 3.1 Pro matched or exceeded Codex on all findings (8 bugs found vs Codex's 5 on the same diff).
- **Builder prompt references Gemini 3.1 Pro pre-push hook** — Claude sees review findings and fixes before push completes.
- **Claude fixes issues naturally:** Findings appear inline; builder prompt instructs Claude to fix before pushing. No separate fix iteration needed.
- **No PR comments:** Issues resolved before PR creation. PRs that reach morning triage are already reviewed.
- **Audit trail:** Output logged to `$OUTPUT_DIR/lift-review-$DATE-run${RUN}.log`.
- **Graceful degradation:** If Gemini is unavailable, review is skipped and build continues.

**Secondary mechanism — builder-side pattern scan (`lib/security-scan.sh`):** Before the builder pushes an iteration branch (`scripts/builder.sh`, after commit detection), it greps the full `master...HEAD` diff for prompt-injection / exfiltration signatures: network calls, non-public env access, dynamic code execution (`eval`/`exec`/`spawn`/`Function`), base64/charcode obfuscation, crypto-mining strings, and image-beacon exfiltration. A hit blocks the push for that iteration (`continue`) and posts to Slack. This is a regex heuristic, so it carries false-positive risk and the patterns are tuned narrowly: the `Function` arm is case-sensitive (lowercase `function ()` IIFEs are fine — LIFT-545, 2026-05-12) and the `exec` arm excludes method calls so `RegExp.prototype.exec()` is not flagged (LIFT-653, 2026-05-27). Regression-tested by `tests/security-scan.bats`.

> **Note:** The review pipeline has been progressively simplified: Gemini  review (Flash → Pro → Sonnet) was replaced with inline hooks on 2026-04-06, then further simplified to Gemini 3.1 Pro only on 2026-04-06 after head-to-head testing showed Flash's 71% false positive rate and Gemini 3.1 Pro matching/exceeding Codex. The old adapter (`adapters/ai-review.sh`) is deprecated; the review tuner was removed on 2026-05-11.

### 5. Auto-Tuners
**Scripts:** `lift-tune-budget.sh`
**When:** After each overnight session completes

**Budget tuner:**
- Analyzes last 7 nights of token usage and runtime
- Adjusts iteration cap, token cap, and cooldown based on productivity patterns
- Raises caps when consistently productive, lowers when stalling
- Runtime-aware: if pipeline uses <25% of the overnight window, suggests raising iteration cap
- Detects context bloat: flags when per-iteration duration trends up >50%

> **Removed 2026-05-11:** The review tuner (`scripts/tune-reviews.sh`, weekly at Sun 21:15) was deleted. It was deprecated 2026-04-06 when the review system moved to inline hooks (no PR comments to learn from). The frozen `lift-review-learnings.md` data file is retained for the deprecated `adapters/ai-review.sh`.

### 6. Issue Cleanup
**Script:** `cleanup.sh`
**When:** After each overnight session (final stage of pipeline)

**What it does:**
- Closes completed/canceled issues that are still open on GitHub via the tracker adapter — issues already closed in a prior session are skipped (checked via `tracker.sh state`), so no redundant `gh issue close` writes are fired
- Detects duplicate issues by title (keeps oldest, cancels+archives newer copies)
- Keeps issue list clean — closes resolved/duplicate issues
- Reports `N closed` (real open→closed transitions only) and `K already closed, skipped`

---

## Testing Infrastructure

The pipeline has a bats-core test suite with **199 tests across 22 test files** in `~/development/pilot/tests/`. Tests use two-tier execution to balance speed with thoroughness:

**Fast tier (196 tests) — pre-commit hook:**
- Runs before every commit via `.githooks/pre-commit`
- Covers: unit tests, adapter contract tests, argument parsing, error handling, log formatting
- Builder tests source real functions from `lib/builder-utils.sh` (not copies of logic)
- Parallel execution via GNU parallel (`bats -j 8`)
- Blocks commit if any test fails

**Full tier (199 tests) — GitHub Actions CI:**
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
| 8:00 AM Sun | Health Report | Weekly | `com.aaron.pilot-health` |
| 6:15 AM | Issue Digest | Daily | `com.aaron.linear-digest` |

---

## Model Allocation

| Agent | Model | Rationale |
|---|---|---|
| Discovery (research) | Gemini 2.5 Flash | Native Google Search, saves Claude tokens |
| Discovery (analysis) | Claude Opus 4.8 (1M, max effort) | Best at codebase reasoning + issue creation |
| Triage | Gemini 2.5 Flash (Claude Sonnet fallback) | Good at planning, uses Google AI Plus (free) |
| Builder | Claude Opus 4.8 (1M, max effort) | Best coding model, complex multi-file changes |
| Review (push) | Gemini 3.1 Pro | Inline via pre-push hook — adversarial review of full branch diff. Single model, single pass. Paid via Google AI Pro ($20/mo). |
| Cover letter review | Gemini 2.5 Flash | Second opinion, zero extra cost |

---

## Slack Channels

| Channel | What posts there |
|---|---|
| #lift-automation | Build iterations, discovery digests, triage summaries, PR reviews, auto-tuner decisions |
| #daily-review | Issue digest (6:15 AM), AI review summaries, LeetCode updates |
| #pilot | Workflow changes — posted automatically when scripts or responsibilities change |

**Slack bot identities:** Each agent posts with a distinct username and emoji avatar for visual distinction. The `notify.sh` adapter supports `--as <identity>` flag to set username/icon_emoji per agent. Falls back to Bot API when webhook fails.

| Identity | Username | Avatar |
|---|---|---|
| Builder | Lift Builder | :robot_face: |
| Discovery | Lift Discovery | :globe_with_meridians: |
| Triage | Lift Triage | :vertical_traffic_light: |
| Budget Tuner | Lift Budget Tuner | :control_knobs: |
| Health | Lift Health | :hospital: |

---

## Data Flow

```
Gemini (web research)
    ↓
Claude (analysis) → GitHub issues created
    ↓
Gemini (triage) → Implementation plans added as comments
    ↓
Claude Opus (builder) → Per-issue branch + code committed
    ↓
Gemini 3.1 Pro adversarial review (pre-push hook):
    → Single model, single pass — reviews full branch diff
    → Claude sees findings inline and fixes before push completes
    → No PR comments — issues resolved before PR creation
    ↓
Per-issue PR created with structured description (Linear links, test results, review verdicts)
    ↓
CI runs (branch protection requires build-and-test to pass)
    ↓
Auto-tuners → Budget + review prompts adjusted
    ↓
Issue cleanup → Completed/canceled closed, duplicates removed
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
| `~/development/pilot/tests/` | bats-core test suite (199 tests, 22 files, two-tier execution) |
| `~/development/pilot/.github/workflows/test.yml` | GitHub Actions CI — full test suite on push |
| `~/development/pilot/.githooks/pre-commit` | Pre-commit hook — fast test tier on every commit |
| `~/development/pilot/project.env` | Lift-specific configuration (git-ignored) |
| `~/development/pilot/init.sh` | Interactive setup wizard |
| `pilot/data/` | All logs, metrics, usage tracking, learnings |
| `pilot/data/pilot-YYYY-MM-DD.log` | Unified structured log (all components) |

See [Pilot Responsibilities](pilot-responsibilities.md) for the complete list of Aaron's manual tasks, automated tasks, environment variables, and changelog.

---

## Changelog

### 2026-06-25 — Builder commit co-author trailer pinned to the configured model

**Problem.** Lift PR commits carried inconsistent attribution — `Co-Authored-By: Claude Opus 4.6`, `Co-authored-by: Claude Opus 4.6` (lowercase), and occasionally `Claude Opus 4.8 (1M context)` — even though the builder runs `claude-opus-4-8[1m]`. The 2026-05-28 model pin assumed the trailer would follow `--model`, but the builder prompt never specified one. In headless `claude -p` mode the model **self-reports** the trailer from its training-cutoff self-knowledge (it identifies as "Opus 4.6"), so the `--model` flag had no effect on attribution.

**Fix.** Attribution is now derived from `AI_CODE_MODEL` (single source of truth) and instructed explicitly:
- New tested helper `model_display_name()` in `lib/builder-utils.sh` converts the model ID to a display name (`claude-opus-4-8[1m]` → `Claude Opus 4.8`; strips `[1m]` and trailing date snapshots; degrades to `Claude` for a bare alias).
- `scripts/builder.sh` computes `COAUTHOR_TRAILER` once from `AI_CODE_MODEL` and injects an explicit "use exactly this trailer, do not self-report a version" instruction into all three committing prompts (main build, merge-conflict fix, CI-fix).
- Because it derives from `AI_CODE_MODEL`, the trailer follows future model bumps automatically — no second edit needed.
- 6 regression tests added in `tests/builder.bats` (18 total, all green), including an assertion that the output never contains the stale `4.6`.

**No model allocation change.** The builder still runs `claude-opus-4-8[1m]` at max effort; only the self-reported attribution string is corrected.

### 2026-05-28 — Centralized agent-tuning knobs in project.env

Extended the centralized-config pattern beyond models. Hardcoded per-agent tunables are now `project.env` vars (with safe `${VAR:-default}` fallbacks at every call site, so test mode and partial configs still work):

- **Turn caps (cost/performance):** `BUILDER_MAX_TURNS` (100), `BUILDER_FIX_MAX_TURNS` (30), `BUILDER_PREPICK_MAX_TURNS` (2), `DISCOVER_MAX_TURNS` (30), `ARCHITECT_MAX_TURNS` (40), `TRIAGE_MAX_TURNS` (6), `ROADMAP_MAX_TURNS` (3).
- **Builder resilience (behavior):** `MAX_CONSECUTIVE_FAILURES` (3), `MAX_STALLS` (2), `MAX_FIX_ATTEMPTS` (1) — previously hardcoded at the top of `builder.sh`.
- **Creativity/quality:** new `AI_TRIAGE_EFFORT` / `AI_ROADMAP_EFFORT` (default `high`) add `--effort` to the Sonnet planning agents. (Opus effort remains `AI_CODE_EFFORT`.)
- Nightly cost/rate knobs continue to live in `config/budget.conf` (auto-tuned by `tune-budget.sh`); they're now also documented in `project.env.example` for discoverability.
- No CLI exposes temperature/top_p, so `--effort` is the only creativity lever.

### 2026-05-28 — Opus-tier calls pinned to Claude Opus 4.8 (1M context) at max effort

All Opus-tier agents now run **`claude-opus-4-8[1m]`** with **`--effort max`**, replacing the bare `opus` alias (which had been resolving to 4.6/4.7 and could not request the 1M-context variant). Centralized via two `project.env` vars consumed everywhere: `AI_CODE_MODEL="claude-opus-4-8[1m]"` and `AI_CODE_EFFORT="max"`.

- **Builder** (`scripts/builder.sh`): main build, merge-conflict fix, and CI-fix calls all get `--model`+`--effort`. The pre-pick stage gets the model pin but **not** max effort — picking one issue from titles is trivial and max effort would only add cost/latency per iteration.
- **Discovery** (`scripts/discover.sh`) and **Architect** (`scripts/architect.sh`): analysis calls get `--model`+`--effort` (architect's hardcoded `--model opus` removed).
- **Adapter** (`adapters/ai-code.sh`): default model bumped, new `--effort` passthrough + `AI_CODE_EFFORT` default.
- All call sites use `${AI_CODE_MODEL:-claude-opus-4-8[1m]}` / `${AI_CODE_EFFORT:-max}` fallbacks so they stay valid even when `project.env` is not sourced (e.g. test mode).
- Model string verified against the live CLI (`contextWindow: 1000000`) — not assumed.
- **Cost note:** a max-effort 1M call carries higher per-iteration cost (cache-creation heavy). Watch `data/lift-usage-tracking.csv`; dial `AI_CODE_EFFORT` down to `high` if nightly spend climbs.
- Commit-trailer attribution in Lift PRs (`Co-Authored-By: Claude Opus 4.x`) was self-reported by the builder at this point and continued to read 4.6/4.7 inconsistently — fixed deterministically on 2026-06-25 (see entry above).

### 2026-05-21 — Builder: deterministic backlog filter + Stage 2 NO_IMPROVEMENTS gate

**Problem.** The 2026-05-20 night ran only 2 iterations and produced nothing. The 2026-05-20 pre-pick parsing fix (below) made Stage 1 functional again — and that immediately surfaced a latent bug: the pre-pick stage does not reliably honor its "do not pick" lists. Both runs pre-picked **LIFT-591**, which already had open PR #596. Stage 2 correctly skipped the duplicate both times (no commits → stalls), and run 2's Stage 2 emitted `NO_IMPROVEMENTS_REMAINING` — which the script interpreted as backlog exhaustion and ended the night.

Two distinct failures:
1. **Pre-pick ignores exclusion lists.** The pre-pick is a cheap, fast call (`--max-turns 2`, no issue bodies) asked to mentally diff a ~26-item backlog against a ~13-item open-PR list. It picked an excluded issue on two consecutive runs. The exclusion lists (`OPEN_PR_ISSUES`, `NIGHTLY_ATTEMPTED_ISSUES`, etc.) were passed correctly — the model just didn't apply them.
2. **Stage 2's `NO_IMPROVEMENTS_REMAINING` ended the night.** The night-end check greps the run log for that token. When Stage 2 has an *assigned* issue it only assessed that one issue — its verdict says nothing about the backlog — but the script treated it as global exhaustion.

**Fix (`scripts/builder.sh`).**
- **Deterministic backlog filter.** Before the pre-pick prompt is built, the script now strips every excluded issue (open-PR, attempted/skipped tonight, in-progress) out of `BACKLOG_ISSUES` itself. The pre-pick physically cannot pick a dup because it is no longer in the list. Same philosophy as the 2026-05-08 deterministic state-flip: don't trust the model to do set arithmetic the script can do exactly.
- **Pre-pick validation guard.** After parsing `ISSUE_PICKED:`, if the chosen issue is not a line in the filtered `BACKLOG_ISSUES`, the pick is discarded (`PICKED_ISSUE=""`) and Stage 2 free-picks instead of burning the iteration.
- **NO_IMPROVEMENTS gate.** The night-end check now fires only when `PICKED_ISSUE` is empty (Stage 2 was free-picking and genuinely surveyed the backlog). Genuine exhaustion is detected by the pre-pick stage, which sees the whole (filtered) backlog.

**Verified.** Against tonight's live data the filter takes the pickable pool 26 → 22, removing LIFT-591 and 17 other open-PR / in-progress issues; `bash -n` clean; filter logic unit-tested under bash 3.2.

### 2026-05-20 — Builder PR-pipeline fix: pre-pick parsing, branch-scoped commit detection, stray-branch reconcile

**Problem.** The 2026-05-19 overnight run started 12 iterations, 11 produced commits, but only ONE (`enhance/run3` → PR #604) became a real PR. The other 10 `enhance/runN` branches were pushed to the remote as empty refs identical to `master`. Three compounding bugs:

1. **Pre-pick parsing broken by a Bun stderr warning.** Stage 1's result is captured with `2>&1`; on this machine Bun prepends a `warn: CPU lacks AVX support` line to stdout. The parser fed the whole stream to `json.loads()`, which threw, and the `except: pass` silently dropped the result. All 12 pre-pick stages on 2026-05-19 (and the 2026-05-14 runs) logged "no parseable ISSUE_PICKED marker" even though Stage 1 had correctly returned `ISSUE_PICKED:LIFT-591`. With no parsed pick, Stage 2 ran in free-pick mode with no issue steering.

2. **No cross-run dedupe.** `NIGHTLY_ATTEMPTED_ISSUES` is populated from the pre-pick result and from `git log master..ITER_BRANCH`. Bug #1 killed the first source; bug #3 killed the second (commits were on stray branches, so `ITER_BRANCH` showed nothing). The list stayed empty all night → the builder redid LIFT-589 four times and LIFT-520 three times.

3. **`HEAD`-based commit detection masked stray branches.** The builder Claude sometimes runs `git checkout -b <its-own-name>` and commits there instead of on `ITER_BRANCH`. `COMMITS_AFTER` was measured with `git rev-list --count HEAD`, which counted whatever branch HEAD wandered to — so a run that left `ITER_BRANCH` empty was still scored a success. The pipeline then pushed the empty `ITER_BRANCH` and `gh pr create` produced nothing.

**Fix (`scripts/builder.sh`).**
- **Pre-pick parsing** scans for the JSON line (skips Bun's warning) instead of parsing the whole stream, with a raw-`grep` fallback for `ISSUE_PICKED:` / `NO_IMPROVEMENTS_REMAINING`.
- **Commit detection** measures `git rev-list --count $DEFAULT_BRANCH..$ITER_BRANCH` (both `COMMITS_BEFORE` and `COMMITS_AFTER`) — branch-scoped, not `HEAD`.
- **Stray-branch reconcile**: after Stage 2, if `HEAD` is off `ITER_BRANCH` with more commits ahead of `master` than `ITER_BRANCH` has, the script `git branch -f`'s `ITER_BRANCH` onto that work and checks it back out — so the push + PR pipeline sees the real commits. A run that strayed and cannot be reconciled is now correctly scored as a stall instead of a false success.
- **Stage 2 prompt** now names the exact branch (`$ITER_BRANCH`), hard-prohibits `git checkout`/`switch`/`branch`, and pushes by branch name instead of `HEAD`.

**Note — bash 3.2 landmine.** The Stage 2 prompt is a `$(cat <<PROMPT …)` heredoc. macOS system bash (3.2.57) mis-parses an odd apostrophe count inside such a heredoc; an added `iteration's` broke `bash -n`. Keep apostrophes out of that heredoc's prose.

**Failure mode this updates.** The 2026-05-08 two-stage entry below lists "Stage 1 returns garbage / no marker → fall through to Stage 2." That fallthrough is now rare (parsing is robust) and, when it does happen, the reconcile + branch-scoped counting keep the run honest.

### 2026-05-12 — Triage FLAG parks issues on `state:needs-input`; pickable + triageable exclude it

**Problem.** The 2026-05-11 overnight builder picked up issue #550 and shipped PR #556 — but triage had already FLAGged #550 as NEEDS INPUT on 2026-05-10. The FLAG verdict only added a comment; it did not change state. #550 stayed on `state:unstarted`, which is exactly the bucket `list pickable` includes. Eight currently-open issues had the same pattern (#306, #308, #309, #533, #546, #547, #550, #551) — every triage FLAG since the GitHub migration was a no-op against the picking pool. The 2026-05-08 `list pickable` exclusion fix excluded `{triage, backlog, started, blocked, canceled}` but had no signal for "triage said wait."

Second problem on the same FLAG verdict: the comment Aaron saw on #550 was effectively blank — `**Triaged by claude-sonnet** — 🚩 NEEDS INPUT` followed by an empty REASON. The triage prompt asked the model for a 1-2 sentence reason and nothing else; Sonnet returned no `REASON:` line and the parser silently fell through. Even when the parse worked, a single sentence is not enough for Aaron to make a decision in 30 seconds — he needs options, tradeoffs, and a recommendation.

**Fix (`adapters/tracker.sh`).** Both `pickable` and `triageable` jq predicates now also `not` against `state:needs-input`:

```jq
(.labels | map(.name)) as $l
  | ($l | index("state:triage")       | not)
    and ($l | index("state:backlog")     | not)
    and ($l | index("state:started")     | not)
    and ($l | index("state:blocked")     | not)
    and ($l | index("state:needs-input") | not)
    and ($l | index("state:canceled")    | not)
```

`triageable` also excludes `state:needs-input` so that already-FLAGged issues do not get re-triaged each cycle, which would overwrite the existing options analysis. The agent's own `"Triaged by"` idempotency check is independent — this is a second defense.

**Fix (`scripts/triage.sh`).** The FLAG case now (a) flips the issue to `state:needs-input` via `tracker.sh update`, and (b) renders a structured comment with `**Question:**`, `**Option N:**` blocks (each with pros/cons bulleted lists), and `**Recommendation:**`. The triage prompt was rewritten to require those fields on every FLAG, with explicit guidance: FLAG is for product decisions, not implementation fuzziness — fuzzy implementation goes to ENHANCE. Pros/cons are pipe-separated in the model output and split into bullets at render time. If the model regresses and omits the structured fields, the fallback path logs a warning and surfaces the raw REASON so the comment is never blank.

**Repo prerequisite.** Added the `state:needs-input` GitHub label to `aschung212/Lift` (color F9D0C4, "Triage flagged — waiting on human decision"). The `tracker.sh update --state needs-input` call needs an existing label — `gh issue edit --add-label` does not auto-create.

**Aaron's resolution flow.** When triage parks an issue on `state:needs-input`:
1. Aaron reads the options + recommendation in the issue comment.
2. Aaron edits the issue body (or replies in a comment) with the chosen direction.
3. Aaron flips `state:needs-input` → `state:unstarted`, which puts the issue back in the picking pool. The builder picks it up next iteration with Aaron's answer baked into the body.

**Issue lifecycle (updated).**

```
discover     ─→ state:triage
triage APPROVE/ENHANCE ─→ state:unstarted
triage FLAG  ─→ state:needs-input   ← NEW (was: no state change, comment only)
triage RESCOPE ─→ state:canceled + N new state:unstarted children
triage SKIP  ─→ priority:4-low (state unchanged)
architect    ─→ (intended state:unstarted; orphan-tolerant via list pickable)
builder pick ─→ state:started        (deterministic at pre-pick stage)
builder done ─→ state:started        (PR opened; closure deferred to PR merge)
PR merge     ─→ closed               (GitHub auto-closes via "Closes #N")
human unblock ─→ state:unstarted    ← Aaron clears state:needs-input by hand
stalled      ─→ state:started        (lingers; manual triage)
```

**Locked in via tests.** `tests/tracker.bats` adds a new test asserting the `pickable` jq output contains `state:needs-input` (i.e. it's in the exclusion chain). The `triageable` test grew the same assertion. `tests/triage.bats` adds three FLAG-output parsing tests: FLAG_QUESTION + RECOMMENDATION extraction, OPTION_N counting across the loop, and the pipe-to-bullet pros rendering.

**Single source of truth per question (updated).**

| Question | Answer |
|---|---|
| What can builder pick next? | `tracker.sh list pickable` (now excludes `state:needs-input`) |
| What's waiting on Aaron? | `gh issue list --label state:needs-input` |
| Who is working on this? | `state:started` label |
| Is there a PR for this? | `gh pr list` (OPEN_PR_ISSUES filter) |
| What did builder attempt this run? | `NIGHTLY_ATTEMPTED_ISSUES` |

### 2026-05-08 — Single source of truth for "pickable": exclusion-based query in tracker.sh

**Why this is its own entry.** The two-stage pre-pick fix earlier today narrowed the picking pool to whatever `tracker.sh list unstarted` returned (4 issues). That accidentally cut off the side channel that was rescuing architect-created issues — they lack `state:unstarted` due to a separate labeling bug, but Claude's main builder call had `Bash(gh:*)` and was finding them via direct `gh issue list` queries. Locking stage 1 to `Read,Glob,Grep` made the picking deterministic but also made the builder blind to those orphans. A 9-issue pool effectively shrank to 4.

**The structural problem.** Picking eligibility was determined by an **inclusion** query (`--label state:unstarted`). One agent's omission silently removed an issue from the pool. Every issue-creating agent became a single point of failure for the builder's input.

**Fix.** `adapters/tracker.sh` `gh_list` now accepts a pseudo-state `pickable`:

```
gh issue list --state open --json number,title,labels --jq '
  .[] | select((.labels | map(.name)) as $l |
    ($l | index("state:triage")   | not) and
    ($l | index("state:backlog")  | not) and
    ($l | index("state:started")  | not) and
    ($l | index("state:blocked")  | not) and
    ($l | index("state:canceled") | not)
  ) | "LIFT-\(.number) \(.title)"'
```

Exclusion-based: every open issue NOT in {triage, backlog, started, blocked, canceled} is pickable. Issues with no `state:*` label at all are pickable by default — a single label-omitting agent cannot silently drop issues.

**`scripts/builder.sh`** stage 1 now calls `tracker.sh list pickable` (was `list unstarted`). Other call sites (the backpressure signal at end-of-night that asks "should discovery run extra?") still use `list unstarted` because that one specifically measures discovery-pipeline output.

**Issue lifecycle.**

```
discover     ─→ state:triage
triage       ─→ state:backlog | state:unstarted | (closed canceled)
architect    ─→ (intended state:unstarted, currently no label — separate bug)
builder pick ─→ state:started     (deterministic at pre-pick stage)
builder done ─→ state:started     (PR opened; closure deferred to PR merge)
PR merge     ─→ closed            (GitHub auto-closes via "Closes #N")
stalled      ─→ state:started     (lingers; manual triage)
```

Closure is GitHub-driven, not pipeline-driven: the builder requires Claude to include `Closes #N` in at least one commit body, and GitHub auto-closes the issue when the PR merges. The pipeline never calls `gh issue close` for an `ISSUE_DONE` marker — that produced orphaned closures when the PR failed CI (PR #467 / LIFT-436, 2026-04-30: PR stayed open with typecheck errors, but the issue closed on a subsequent night via `cleanup.sh` after the builder's `--state Done` flip).

**Single source of truth per question.**

| Question | Answer |
|---|---|
| What can builder pick next? | `tracker.sh list pickable` |
| Who is working on this? | `state:started` label |
| Is there a PR for this? | `gh pr list` (OPEN_PR_ISSUES filter) |
| What did builder attempt this run? | `NIGHTLY_ATTEMPTED_ISSUES` |

**Locked in via test.** `tests/tracker.bats` now asserts that `list pickable` hits `--state open` and does NOT regress to `--label state:unstarted` (the pattern this fix replaces).

### 2026-05-08 — Two-stage builder: pre-pick stage flips state BEFORE implementation

**Problem.** The commit-driven In-Progress flip (landed earlier today) only fires after Claude's main session ends. If iteration N stalls without commits — the 2026-05-07 pattern, where Claude exits terse after the pre-push review hook fires — no commits exist, the state never flips, and iteration N+1 within the same nightly run re-picks the same issue.

The script cannot flip state mid-session because it is blocked on the synchronous `claude -p` call. The flip has to happen INSIDE Claude's session, which means either (a) instructing Claude to run `gh issue edit` early in its main call, or (b) splitting the Claude invocation into two stages and flipping between them. Option (a) is fragile — Claude's compliance with prompt instructions has been ~50% in practice (the 2026-04-29 marker losses, the 2026-05-07 stall pattern, the multiple ignored "do not create PRs" rules). Option (b) is deterministic: the script controls when the flip happens, and Claude's mid-session behavior cannot prevent it.

**Fix.** Two-stage Claude invocation per iteration in `scripts/builder.sh`:

- **Stage 1 — pre-pick (~30s, ~$0.05–0.20)**: a tightly-scoped Claude call (`--allowedTools "Read,Glob,Grep" --max-turns 2`) whose only job is to pick the next issue from the unstarted backlog. Stage 1 sees the same do-not-pick lists as the main prompt (`IN_PROGRESS_ISSUES`, `OPEN_PR_ISSUES`, `NIGHTLY_ATTEMPTED_ISSUES`, `SKIPPED_ISSUES`) but no full issue bodies — just titles and priorities. The required output format is a single line: `ISSUE_PICKED:LIFT-<n>` or `NO_IMPROVEMENTS_REMAINING`. The script parses that line and calls `tracker.sh update --state "In Progress"` BEFORE stage 2 starts.

- **Stage 2 — implementation (unchanged cost)**: the existing main builder call, with the prompt enriched by an `## ASSIGNED ISSUE FOR THIS ITERATION` block when stage 1 succeeded. Step 2 of "Your job" becomes "Implement \`LIFT-<n>\`" instead of "Pick exactly ONE issue". Stage 2 is allowed to refuse the assignment via `ISSUE_SKIPPED:<id>:<reason>` plus a label-revert command, but is forbidden from picking a different issue in the same iteration.

**Failure modes and fallbacks.**
- Stage 1 returns garbage / no marker: script logs a warning and falls through to stage 2 with the original "pick from backlog" instruction. Commit-driven flip still catches anything that gets committed.
- Stage 1 returns `NO_IMPROVEMENTS_REMAINING`: the nightly loop breaks early, no further iterations.
- Stage 2 picks a different issue than stage 1 assigned: stage 1's pick stays In Progress with no PR (visible in next night's audit). Stage 2's pick gets caught by commit-driven flip. The mismatch shows up in audit reports for follow-up.

**Cost.** ~$0.60–2.40 per nightly run (12 iterations × stage-1 cost). Trade-off accepted: deterministic state-flip-on-pick beats prompt-instructed compliance.

**Model allocation unchanged.** Stage 1 and stage 2 both use Opus 4.6 1M context. Stage 1's small token budget keeps cost low — it does not warrant a smaller model since the picking quality matters and Opus is already cached.

### 2026-05-08 — Builder marks issues "In Progress" when commits land

**Problem.** Even with the picking-time dedupe and `gh pr create` lockdown landed earlier the same day, an issue could still be re-picked across nights because the tracker rarely flipped state. State changes were marker-driven (`ISSUE_PROGRESS:` / `ISSUE_DONE:` from Claude's structured response), and the 2026-05-07 stall pattern showed Claude exiting terse without emitting any markers — so the `state:started` label was rare in practice. The pickable backlog (`tracker.sh list unstarted started`) kept surfacing the same issue across runs.

**Fix.** State change is now commit-driven. As soon as commits with `#NNN` / `LIFT-NNN` refs land on the iteration branch, the script calls `tracker.sh update <id> --state "In Progress"` for each ref. The label flips even when Claude exits without markers.

**Picking query split.**
- `BACKLOG_ISSUES`: `tracker.sh list unstarted` (was `list unstarted started`) — only truly-pickable issues appear in the prompt's primary backlog.
- `IN_PROGRESS_ISSUES` (new): `tracker.sh list started` — surfaced separately under `## Issues already IN PROGRESS — DO NOT PICK`. Tells Claude what is in flight without making it pickable. Stalled work can be flagged via `ISSUE_SKIPPED:<id>:looks stalled, needs human review`.

**Race avoidance.** The new "mark In Progress" loop short-circuits when Claude has already emitted an `ISSUE_DONE:<id>` marker — the existing close handler at line ~620 will run a moment later and we want the issue to land in Done, not bounce through In Progress first.

**Trade-off.** Issues that get committed against but never finish now stay in `state:started` until manually triaged. This is intentional — silent re-picking was the failure mode. Aaron has a (light) new responsibility: periodically scan `state:started` issues that linger and either revert to `unstarted` (retry) or move to `blocked`.

### 2026-05-08 — Builder picking-time dedupe + `gh pr create` lockdown

**Problem.** The 2026-05-07 overnight produced PRs #515 and #517 for issue #501 — same content, two PRs. Two of the three "real" runs (6 and 11) emitted duplicates despite the post-PR dedupe guard that landed 2026-05-06. Six of twelve runs that night were stalls. Combined waste: ~25 minutes of compute and a duplicate to clean up by hand.

**Why the post-PR guard didn't help.** The guard fires after Claude's session ends, right before the script's own `gh pr create`. But Claude was opening the PR itself inside the iteration (`gh:*` was in the allowlist, so `gh pr create` was reachable despite the prompt saying "do NOT create pull requests"). By the time the guard ran, the dup PR was already on GitHub. There was also no signal at issue-pick time pointing Claude away from issues that already had open PRs from previous nights or earlier iterations.

**Fix in three layers (`scripts/builder.sh`).**

1. **Picking-time dedupe (new).** Before each iteration's prompt is rendered, the script runs `gh pr list --state open --json title --limit 100` and extracts every `#NNN` / `LIFT-NNN` ref from the titles. The deduped list is injected into the prompt under `## Issues with EXISTING OPEN PRs — DO NOT PICK` (above the existing "ATTEMPTED tonight" section). The same set is merged into `NIGHTLY_ATTEMPTED_ISSUES` so run 1 of the night isn't blind to previous nights' open PRs.

2. **`gh pr create` lockdown.** Added `Bash(gh pr create:*)` to `BUILDER_DISALLOWED_TOOLS`. Claude can still push branches, list issues, and read PR state; only PR opening is the script's job. Even if the prompt rules are ignored, the tool simply isn't available.

3. **Post-work guard hardened.** The existing dedupe guard at line ~700 (script-side `gh pr create`) now falls back to `PRIMARY_ISSUE` and then to a full-branch commit-message scan when `FIRST_COMMIT_MSG` lacks an issue ref. Logs the issue number it checked and what it found in the run log, so silent regressions surface in audit reports.

**No model allocation change.** The Builder model (Opus 4.6 1M) is unchanged. The review pipeline (Gemini 3.1 Pro pre-push) is unchanged. The prompt and the tool allowlist are the only behavioral edges.

### 2026-05-06 — Auditor detector split + builder early-exit prompt fix

**Auditor detectors (`scripts/pipeline-auditor.sh`):** the `num_turns_one_spike` detector was conflating two distinct failure modes. Split into:
- `subagent_delegation` — fires when num_turns=1, parent_out<100, AND a non-opus model (haiku/sonnet) appears in `modelUsage`. Remediation lives in `--disallowedTools` configuration.
- `early_exit_no_markers` — fires when num_turns=1, parent_out<100, opus-only modelUsage, AND opus_outputTokens ≥ 500. Indicates the parent did real work but exited before emitting the structured response. Remediation lives in the builder prompt.

The `marker_emission_collapse` finding now points readers to whichever of the two companion findings actually fired, rather than asserting "subagent delegation drift" as the cause.

**Builder prompt (`scripts/builder.sh`):** two changes to address the early-exit pattern:
- **Step 4** rewritten from "After your final push, you are done" to "Output structured response, THEN exit" — explicitly forbids the chatty one-liner exit pattern that was producing 80% of marker losses in the 04-30..05-06 window.
- **New Rule:** `CRITICAL — DO NOT BACKGROUND GIT OPERATIONS`. The trigger for early exit was always a `run_in_background:true` git push completing — when the bash result returned, the agent treated the iteration as done and skipped the structured output.

**Auditor label bootstrap (`lib/auditor-utils.sh`):** added `ensure_audit_labels` helper that idempotently creates `audit` and `severity:p1/p2/p3` labels in the pilot repo at audit start. This unblocks `gh issue create` calls that were failing silently when labels didn't exist (root cause of the 2026-05-06 missing-issue incident).

### 2026-04-24 — Health report data sources rewired
- `nights_run` and average runtime now derived from `lift-metrics.csv` instead of the orphaned `lift-runtime.csv` (the latter was only written by the decommissioned orchestrator). New formula: `nights_run = len(set(dates))`, `avg_builder_min = sum(duration_sec) / nights / 60`.
- Renamed metric "Avg pipeline runtime" → "Avg builder runtime" — accurate to what's actually measured (builder iteration time, not discovery+triage).
- Fixed `grep -c PATTERN file 2>/dev/null || echo "0"` idiom in 6 places (builder.sh, health-report.sh, digest.sh). The fallback fired even on legitimate-zero matches, appending an extra "0\n" that corrupted the metrics CSV across multiple lines. Wrapped each call in `{ ...; } | head -1`.
- Repaired `lift-metrics.csv` one-shot to rejoin 46 split rows; backup retained at `data/lift-metrics.csv.bak-*`.

### 2026-04-24 — PR screenshot capture
- Added a post-PR screenshot capture step to the builder loop. Affected routes are declared by builder Claude (`SCREENSHOT_ROUTE:/path` markers in the run log); after `gh pr create`, the pipeline boots a temporary `npm run dev` in the worktree on a free port, signs in via the dev button, and uses the project's existing Playwright install to capture each route at iPhone 14 Pro viewport (390×844).
- Screenshots land at `$OUTPUT_DIR/pr-screenshots/pr-{NUM}-{ISSUE}-{slug}/` with an `INDEX.md`. Path is surfaced in the per-iteration Slack thread.
- Best-effort: capture failures (Playwright missing, dev server timeout, route 404) are logged and skipped — never block the PR.
- New scripts: `capture-pr-screenshots.sh` (dev-server lifecycle), `capture-pr-screenshots.mjs` (Playwright capture). Module resolution uses `createRequire` against the target repo's `package.json` so the `.mjs` can live in pilot while Playwright lives in the project repo.

### 2026-04-02 — Builder Overhaul: Branch-per-Issue + 3-Layer Review
- Builder switched from single nightly branch/PR to branch-per-issue (`enhance/LIFT-{id}-{date}`) with individual PRs
- Per-iteration review upgraded to Gemini  cross-model system:
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
- init.sh updated: Gemini  review config, budget.conf creation, git hooks setup, discovery queue init, bats/parallel/gtimeout checks, digest.sh plist
- project.env.example now documents all 30+ variables
- README, docs/architecture.md, docs/adapters.md updated for Gemini  review, RESCOPE, test suite, bot identities
- Removed 2 orphaned launchd plists, fixed script paths in remaining 6
- Pilot is now fully project-agnostic — configure for any repo via `init.sh`

### 2026-04-06 — Review Pipeline Reliability Fixes
- **Bug fix:** Gemini rate limits (`MODEL_CAPACITY_EXHAUSTED`) caused 57% L1 skip rate. `run_gemini()` now retries 3x with exponential backoff (10s → 20s → 40s) before falling to fallback chain.
- **Bug fix:** Claude Sonnet fallback in `run_claude()` never successfully ran (all `.json` files were 0 bytes). Root causes:
  - `--max-turns 15` let Sonnet attempt tool use and file reads instead of single-turn review → timeouts
  - Missing `< /dev/null` caused potential stdin hang
  - No stderr capture made failures silent
- `run_claude()` now uses `--max-turns 1`, closes stdin, captures stderr to `.err` file for diagnostics
- Python JSON parser reports specific failure reason (invalid JSON, empty result, Claude error)
- All 9 ai-review.bats tests pass
- **No change to Aaron's workflow** — fixes are internal to overnight pipeline

### 2026-04-06 — Replace 3-Layer Review with Inline Hook-Based Review
- **MAJOR CHANGE:** Removed ~300 lines of review orchestration from builder.sh
- Review now happens inline via `~/.claude/scripts/review-router.sh` (PostToolUse hook):
  - Every commit: Gemini Flash review (free, inline — Claude sees and acts on findings)
  - On push: Gemini Flash + Gemini Pro architectural review (for high-risk changes)
  - Claude fixes issues naturally from hook feedback — no separate fix iteration
- Removed: Gemini  ai-review.sh adapter calls, fix iteration logic, revert-on-failure, PR comment posting, composite verdict computation, deferred issue creation
- Removed 4 helper functions from builder-utils.sh: `pick_worst_verdict`, `verdict_emoji`, `format_review_findings`, `format_review_crosschecks`
- Deprecated: `adapters/ai-review.sh`, `scripts/tune-reviews.sh` (retained 30 days for rollback; tuner deleted 2026-05-11)
- Commented out review env vars in project.env (AI_REVIEW_MODEL_L1/L2/L3, etc.)
- Updated builder prompt with review feedback instructions
- Fixed 3 Codex-identified bugs in tracker.sh: `create` now routes by TRACKER_ADAPTER, `gh_create` outputs issue ID for callers, `close` works for Linear via state update
- Tests updated: removed 8 verdict helper tests from builder.bats, removed ai-review contract tests
- **No change to Aaron's workflow** — reviews happen automatically, PRs arrive clean

### 2026-04-06 — Builder Hardening, Git Hook Reviews, Preview Mode
- **Builder script fixes:**
  - Fixed backtick command substitution bug in heredoc prompt (shell was executing `git push` as commands)
  - Fixed `<branch-name>` placeholder — changed to `HEAD` for reliable pushing
  - Changed from relying on PostToolUse hooks to explicit `bash review-router.sh` calls in prompt (hooks don't fire in headless `claude -p` mode)
  - Added CI validation step: after push, runs build + test; auto-fixes merge conflicts and build/test errors before creating PR
  - Removed Gmail draft summary (Slack notifications sufficient)
  - Added Verification section to Claude's output format (steps to test, expected behavior, risk assessment)
  - Builder extracts verification section and includes it in PR description
  - Added Vercel preview URL fetching: polls GitHub deployments API after PR creation, adds preview URL to PR body and Slack message
  - Condensed risk/confidence + preview link in Slack thread messages
- **Review system moved to git hooks (primary mechanism):**
  - `.husky/post-commit` — Gemini Flash review after every commit (non-blocking)
  - `.husky/pre-push` — Gemini Flash + Pro/Codex review before push (blocks until complete)
  - Git hooks fire at the git level regardless of caller (Claude, builder, manual)
  - PostToolUse hooks in settings.json kept as belt-and-suspenders backup
- **Preview mode for Vercel deploy testing:**
  - Detects Vercel preview deployments via hostname check in `src/lib/supabase.ts` and `src/App.vue`
  - Blocks Supabase writes by default (syncQueue + direct inserts skip when isPreviewMode is true)
  - Shows blue "Preview mode" banner with "Enable writes" toggle
  - Allows safe testing with real Google account (reads work, writes blocked)
  - Test account created in Supabase (test@lift.local / LiftTest2026!) for full write-path testing
- **Supabase auth redirect fix:** Added wildcard redirect URL for all Vercel preview deployments
- **TypeScript fix:** Removed unused `updateSW` variable in App.vue that was failing typecheck across all PRs; rebased all 3 open PRs onto master
- **New responsibility for Aaron:** PRs now include Verification sections and Vercel preview URLs — use these for faster morning review. Preview mode available for safe manual testing on preview deploys.

### 2026-04-06 — Review Pipeline Simplified to Gemini 3.1 Pro Only
- **Removed Gemini Flash** from post-commit hook — 71% false positive rate (5/7 reviews wrong), generated noise that trained developers to ignore output
- **Removed Codex (GPT-5.4)** from pre-push — Gemini 3.1 Pro matched or exceeded Codex on all findings in head-to-head testing (8 bugs vs 5 on same diff, LIFT-127)
- **Removed post-commit hook entirely** — no review on commit, only on push
- **Pre-push hook now runs Gemini 3.1 Pro only** — adversarial review of full branch diff before push completes
- `review-router.sh` rewritten — single model (`gemini-3.1-pro-preview`), single mode (push only)
- Builder prompt updated to reference Gemini 3.1 Pro pre-push hook
- Model allocation: review rows consolidated from 2 (Flash + Pro) to 1 (Gemini 3.1 Pro)
- Cost: Gemini 3.1 Pro covered by existing Google AI Pro subscription ($20/mo) — no additional cost
- SWE-bench Verified scores: Gemini 3.1 Pro (80.6%) vs GPT-5.4 Codex (80.0%)
- **No change to Aaron's workflow** — reviews remain fully automated inline
