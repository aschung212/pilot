---
type: system-reference
tags:
  - pilot
  - automation
  - responsibilities
updated: 2026-04-02
---

# Aaron's Pilot Responsibilities

> [!info] This is the source of truth for what Aaron does manually vs. what is automated.
> All Claude instances are instructed to keep this updated when workflows change.
> For the full pipeline architecture and agent details, see [Pilot Architecture](pilot-architecture.md).

---

## Daily — Morning

| What | How | Where to check |
|---|---|---|
| **Check Slack** | Open #lift-automation — nightly summary categorizes PRs as "Ready to merge" (green, verdict: MERGE) or "Needs review" (yellow, verdict: REVIEW). Also check #daily-review for Linear digest. | #lift-automation, #daily-review |
| **Merge green PRs** | PRs with MERGE verdict — CI passed, 3-layer review clean. Merge directly. | github.com/aschung212/Lift/pulls |
| **Review yellow PRs** | PRs with REVIEW verdict — read review comments in PR description, decide merge/comment | github.com/aschung212/Lift/pulls |
| **Ignore failed PRs** | PRs labeled `ci:failed` auto-retry next night — no action needed | — |
| **Check per-PR review status** | Each PR has 3-layer cross-model review results in description (Gemini Flash gate → Gemini Pro architecture → Claude Sonnet self-check). Verdicts: MERGE / REVIEW / DO NOT MERGE | PR description shows review findings + resolution |
| **Test locally if needed** | `cd ~/development/lift && npm run dev` | localhost |
| **Merge or request changes** | GitHub PR UI — merge individually, each PR is self-contained | Vercel auto-deploys on merge to master |
| **Triage discovery issues** | Review new Linear issues from discovery agent, set priorities, add comments, cancel junk | linear.app/masterchung -> Lift project |
| **Run `/ai-review`** | Claude Code CLI | Posts summary + LC update to #daily-review |

## Daily — Evening

| What | How |
|---|---|
| **Fill in daily note** | Obsidian — mood, energy, Evening Wind-Down section, what you accomplished, gratitude, learnings |
| **Run `/ai-review`** (delta) | Claude Code CLI — updates action item completion, refreshes Top 3 |
| **Log LeetCode solves** | Write in daily note (e.g., "solved LC 424, sliding window, 15 min") — `/ai-review` picks it up |

## Daily — Before Bed

| What | How |
|---|---|
| **Overnight services run automatically** | Discovery (Sun/Tue/Thu 10 PM), Triage (Sun/Tue/Thu 10:30 PM), Builder (Mon-Fri 11 PM). Each is an independent launchd service. No action needed. |
| **Override if needed** | To skip builder tonight: `launchctl unload ~/Library/LaunchAgents/com.aaron.pilot-builder.plist`. To run manually: `bash ~/Documents/Scripts/lift-discover.sh` (or triage, etc). |

## Weekly / As Needed

| What | How |
|---|---|
| **Review Linear digest** | Auto-posted to #daily-review at 6:15 AM via launchd. Check it during morning Slack review. |
| **Manage Linear backlog** | Reprioritize, add comments/context to flagged issues. Completed/canceled issues and duplicates are archived automatically each night. When canceling, add a comment explaining why — discovery agent learns from this. |
| **Update product decisions** | If you reject a category of feature (not just one issue), update `Lift - Product Decisions.md` in your vault |
| **Review metrics** | `~/Documents/Claude/outputs/lift-metrics.csv` and `lift-discovery-metrics.csv` |
| **Review token usage + runtime** | `~/Documents/Claude/outputs/lift-usage-tracking.csv` and `lift-runtime.csv` — budgets auto-tune but review if unexpected |
| **Update CLAUDE.md** | If design principles or code standards evolve |

---

## One-Time Setup (pending)

- [x] Run `/github subscribe aschung212/Lift` in #lift-automation in Slack ✅ 2026-03-31
- [x] Schedule `linear-digest.sh` via cron or launchd for mornings ✅ 2026-03-31 (launchd, 6:15 AM daily)

---

## What's Fully Automated

- Decomposed pipeline — 6 independent services, each with own launchd plist:
  - Discovery (Sun/Tue/Thu 10 PM): finds improvements, creates Linear issues (Gemini + Claude)
  - Triage (Sun/Tue/Thu 10:30 PM): reviews issues, adds implementation plans (Gemini, Claude fallback)
  - Builder (Mon-Fri 11 PM): implements per-issue branches (`enhance/MAS-{id}-{date}`), per-issue PRs with 3-layer cross-model review (Gemini Flash gate → Gemini Pro architecture → Claude Sonnet self-check) + auto-fix cycle, CI check. Uses git worktree for isolation. Failed PRs (`ci:failed`) auto-retried next night. Conditional deep review: Layers 2+3 only run when needed (L1 findings or high-risk category).
  - Cleanup: runs at end of builder — archives completed/canceled, deduplicates backlog
  - Budget Tuner (Sunday 9 PM): adjusts iteration/token caps based on week's data
  - Review Tuner (Sunday 9:15 PM): learns from PR feedback
  - Health Report (Sunday 8 AM): weekly metrics dashboard, log rotation, anomaly detection
- Version controlled at [github.com/aschung212/pilot](https://github.com/aschung212/pilot)
- Swappable components via adapter scripts (tracker, notify, AI models)
- Structured logging via `lib/log.sh` — unified daily log, error alerting to Slack
- Backpressure: builder signals discovery when backlog is low
- Branch protection on master: requires build-and-test CI to pass before merge
- Vercel preview deploys per PR; auto-merge available (GitHub setting enabled)
- Post-merge CI failure → Slack notification
- Slack threading: one parent message per night, all updates threaded (updated for multi-PR output)
- `/ai-review`: syncs LC log, syncs Linear (LC + applications), updates Obsidian temporal notes, posts to Slack
- Slack webhooks: all notifications are token-free (no Claude instances spawned)
- Test suite (bats-core, 105 tests across 16 files): fast tier (101 tests) runs on every commit via pre-commit hook, full tier (105 tests) runs on push via GitHub Actions CI
- Auto-discovery smoke tests: fail when new scripts lack test coverage — enforces that every new script gets tests
- Gmail draft: morning digest email drafted at end of overnight run
- Linear digest: posts board snapshot to #daily-review at 6:15 AM daily (launchd)
- Overnight runner: discovery → triage → builder chain starts at 11 PM nightly (launchd)

## What's NOT Automated

- **~~Starting scripts~~** — ✅ Now automated via launchd at 11 PM nightly (`com.aaron.lift-overnight`)
- **Merging PRs** — intentionally manual (review first)
- **Daily notes** — Aaron writes the content, AI reviews it
- **Linear triage** — discovery creates issues, Aaron prioritizes and adds context
- **LeetCode solving** — Aaron solves, notes it in daily note, automation tracks it
- **Adding tests for manual script changes** — when editing pilot scripts by hand, add/update corresponding bats tests in `~/development/pilot/tests/`. Pre-commit hook will catch missing coverage for new scripts.

---

## Key Files

| File | Purpose |
|---|---|
| `~/development/pilot/` | Pipeline repo — all scripts, adapters, config, docs ([GitHub](https://github.com/aschung212/pilot)) |
| `~/Documents/Scripts/lift-*.sh` | Symlinks to `~/development/pilot/scripts/` — launchd points here |
| `~/development/pilot/adapters/` | Swappable adapters: tracker, notify, ai-code, ai-research, ai-review |
| `~/development/pilot/lib/log.sh` | Shared structured logging (unified log, error alerting) |
| `~/development/lift/CLAUDE.md` | Lift project standards (design, code, workflow) |
| `~/.claude/commands/ai-review.md` | Daily review slash command |
| `~/.claude/CLAUDE.md` | Global Claude instructions |
| `~/development/pilot/tests/` | bats-core test suite — 16 test files, 105 tests (fast tier: 101, full tier: 105) |
| `~/development/pilot/.github/workflows/test.yml` | GitHub Actions CI — runs full test suite on push |
| `~/development/pilot/.githooks/pre-commit` | Git pre-commit hook — runs fast test tier before every commit |
| `~/Documents/Scripts/lift-triage.sh` | Gemini issue triage — reviews, enhances, and plans before builder runs |
| `~/Documents/Scripts/review-cover-letter.sh` | Gemini cover letter reviewer — run before sending applications |
| `~/Documents/Scripts/lift-budget.conf` | Token budget config — auto-tuned nightly by `lift-tune-budget.sh` |
| `~/Documents/Scripts/lift-tune-budget.sh` | Auto-tuner — analyzes usage + runtime history and adjusts budget config |
| `~/Documents/Scripts/lift-linear-cleanup.sh` | Linear cleanup — archives done/canceled issues, deduplicates backlog |
| `~/Documents/Claude/outputs/` | Logs, metrics, digests, cost tracking |
| `Obsidian: 20_Learning/Vibe Coding Projects/Lift - Product Decisions.md` | Product direction — rejected concepts, approved direction. Discovery agent reads this. |

## Slack Channels

| Channel | What posts there |
|---|---|
| #lift-automation | Overnight build iterations, discovery digests, GitHub activity (pending setup) |
| #daily-review | AI review summary, LeetCode updates, Linear digest |
| #system-changelog | Pilot changelog — what changed, new responsibilities |

## Environment Variables (`~/.zshenv`)

| Var | Purpose |
|---|---|
| `SLACK_WEBHOOK_URL` | Webhook for #lift-automation |
| `SLACK_WEBHOOK_DAILY_REVIEW` | Webhook for #daily-review |
| `SLACK_WEBHOOK_CHANGELOG` | Webhook for #system-changelog |

---

## Changelog

### 2026-03-31
- Replaced all Slack notifications with webhooks (zero tokens)
- Added discovery digest to #lift-automation
- Created `linear-digest.sh` for board snapshots to #daily-review
- Added LeetCode Slack updates to `/ai-review`
- Moved `/ai-review` source of truth to `~/.claude/commands/ai-review.md`
- Created this responsibilities document
- Created global `~/.claude/CLAUDE.md`
- Discovery agent now reads canceled issues with full details and a product decisions file to understand approved vs rejected product direction
- New file: `~/Documents/Claude/outputs/lift-product-decisions.md` — Aaron should update this when rejecting categories of features
- New responsibility: when canceling Linear issues, add a comment explaining why (discovery agent reads this)
- Added #system-changelog Slack channel — all workflow changes are now posted there automatically
- All Claude instances instructed to post changelogs via `~/.claude/CLAUDE.md`
- Scheduled `linear-digest.sh` via launchd at 6:15 AM daily — no longer needs manual runs
- Updated app icon to gold barbell + arrow design, removed old SVG icon
- Redesigned Aaron theme to match new icon (charcoal-navy + gold palette)
- Automated overnight scripts via launchd at 11 PM nightly — discovery + builder chain runs without manual start
- New file: `~/Documents/Scripts/lift-overnight.sh` — wrapper that chains discover → builder
- New launchd: `com.aaron.lift-overnight` — starts at 11 PM, runs until 7 AM
- **Removed responsibility:** no longer need to manually start overnight scripts before bed
- Added token usage monitoring to overnight builder and discovery agent (Claude Max = no $ cost, rate limits matter)
- New file: `~/Documents/Scripts/lift-budget.conf` — iteration cap (8/night), token cap (500K output/night), cooldown (30s)
- Usage tracking CSV: `~/Documents/Claude/outputs/lift-usage-tracking.csv`
- Auto-stops overnight builder when iteration or token cap reached
- Slack alerts at 80% of token cap and when caps are hit
- Morning digest includes token usage summary and per-night averages
- Auto-tuner (`lift-tune-budget.sh`) runs after each overnight session — analyzes usage history and adjusts budget.conf
  - Raises iteration cap if consistently productive, lowers if stalling
  - Adjusts token cap to 2x average nightly usage
  - Tunes cooldown based on failure rate
  - Needs 3+ nights of data before it starts tuning
  - Tuning log: `~/Documents/Claude/outputs/lift-tune-log.csv`
  - Posts tuning decisions to #lift-automation
- 2-layer automated PR review added to overnight builder:
  - Layer 1: Claude adversarial review (bugs, security, performance, accessibility)
  - Layer 2: Gemini review via CLI (architecture, UX, edge cases, what's missing) — uses Google AI Plus subscription
  - Both posted as PR comments + appended to morning digest
  - Aaron's morning review: read two AI summaries instead of line-by-line diff
- Review auto-tuner (`lift-tune-reviews.sh`) runs after each overnight session:
  - Analyzes merged PRs: what reviewers flagged vs. what Aaron caught
  - Tracks clean merge rate (reviewers caught everything) vs. misses
  - Builds custom rules from patterns Aaron catches that reviewers miss
  - Injects learnings into future review prompts — reviewers get smarter over time
  - History: `~/Documents/Claude/outputs/lift-review-history.json`
  - Learnings: `~/Documents/Claude/outputs/lift-review-learnings.md`
- Discovery agent now uses Gemini for web research (Phase 1) + Claude for analysis/issue creation (Phase 2)
  - Gemini has native Google Search — better research results
  - Saves Claude tokens by offloading the search-heavy phase
  - Pro with Flash fallback
- New script: `review-cover-letter.sh` — Gemini reviews cover letters before sending (zero extra cost)

### 2026-04-01
- Pipeline expanded to 4 stages: discover → triage → builder → **cleanup**
- New script: `lift-linear-cleanup.sh` — archives completed/canceled issues, deduplicates backlog by title (preserves Linear free tier)
- Builder now detects merged PRs and creates fresh branches instead of pushing to stale ones
- Runtime tracking added: per-stage timing in `lift-runtime.csv`, builder runtime in digest + Slack
- Budget tuner now analyzes runtime: raises iteration cap when using <25% of overnight window, flags context bloat when per-iteration duration trends up
- Fixed builder loop crash: test count parsing returned multi-line output, breaking arithmetic
- Fixed triage Slack: issue title extraction used wrong format (`Title:` vs `# MAS-XXX: Title`)
- Fixed discovery Slack: links now include MAS-XXX ID, not just description
- Fixed usage stats: avg tokens/night was always 0 due to `int()` crash on "discover" run labels
- Fixed PR trophy bug: tied e1RM no longer shows trophy on both dates (only earliest)
- Muscle group chart now uses theme accent color instead of hardcoded rainbow colors
- Removed Lighthouse CI job (SPA hits NO_FCP in headless Chrome — never passes)
- Fixed CI TypeScript errors in test files (useAnalytics, useSwipeToDismiss, tagColors)
- **Reduced responsibility:** Linear cleanup is now automated — Aaron only needs to prioritize and make design decisions on flagged issues

### 2026-04-02 — Builder Overhaul: Branch-per-Issue + 3-Layer Review
- **MAJOR CHANGE:** Builder switched from single nightly branch/PR to branch-per-issue (`enhance/MAS-{id}-{date}`) with individual PRs
- **MAJOR CHANGE:** Per-iteration review upgraded from single Sonnet review to 3-layer cross-model review system:
  - Layer 1 (Gemini Flash): Mechanical gate — bugs, types, CSS, security. Runs every iteration.
  - Layer 2 (Gemini Pro): Architecture — cross-component, edge cases. Runs conditionally (L1 findings OR feat/fix category).
  - Layer 3 (Claude Sonnet): Self-check — known Opus failure patterns, validates Gemini findings. Runs conditionally (same as L2).
  - Clean low-risk PRs get Layer 1 only (~1 min vs ~5 min for full review)
  - Failover chains: L1 Flash → Sonnet → skip | L2 Pro → Flash (deeper) → skip | L3 Sonnet → Haiku → skip
  - Verdicts: MERGE / REVIEW / DO NOT MERGE (replaces GO/NO-GO)
  - Finding statuses: Fixed / Deferred (Linear issue) / Noted
- Critical/high findings trigger Opus auto-fix attempt before PR creation
- Medium/low findings → auto-created as Linear issues for future work
- Structured PR descriptions with Linear links, test results, review verdicts
- Conventional commit messages: feat/fix/a11y/test/perf/style/refactor/chore prefixes
- PR labeling by type (type:a11y, type:test, type:bugfix, type:feature, type:perf, type:style)
- Failed PR retry: PRs labeled `ci:failed` from previous nights auto-retried
- Budget increased: MAX_ITERATIONS_PER_NIGHT from 8 → 12
- Removed: final 2-layer batch review (replaced by per-iteration 3-layer review)
- Slack bot identities: Builder (robot), Discovery (globe), Triage (traffic light), Review Tuner (knobs), Budget Tuner (knobs), Health (hospital)
- `notify.sh` gained `--as <identity>` flag; falls back to Bot API when webhook fails
- Branch protection on master: requires build-and-test CI to pass
- Vercel preview deploys working per PR; auto-merge available (GitHub setting enabled)
- CI workflow enhanced with Slack notification on post-merge failure
- **Changed responsibility:** Morning PR review is now N small PRs (one per issue) instead of 1 large PR. Each has 3-layer review results inline — green PRs can be merged immediately, yellow PRs need a quick look at review comments. Failed PRs auto-retry next night.

### 2026-04-02 — Pipeline Decomposition (Phases 1-9)
- **MAJOR CHANGE:** Monolithic orchestrator (`lift-overnight.sh`) retired. Pipeline decomposed into 6 independent launchd services.
- All scripts version controlled at [github.com/aschung212/pilot](https://github.com/aschung212/pilot)
- Project config extracted into `project.env` — scripts no longer hardcode Lift-specific values
- Swappable adapters: `tracker.sh` (Linear), `notify.sh` (Slack), `ai-code.sh`, `ai-research.sh`, `ai-review.sh`
- Builder uses git worktree (`~/development/lift-builder`) — Aaron can work on repo simultaneously
- Slack threading: one parent message per night, all updates threaded. Requires `SLACK_BOT_TOKEN` in `~/.zshenv`
- CI status check: builder polls GitHub Actions after push, reports pass/fail in Slack thread
- Backpressure: builder writes `.lift-backlog-low` flag when < 3 unstarted issues, discovery runs extra
- Linear labels: 6 area labels created (Performance, Accessibility, UI/UX, Testing, Security, PWA). Discovery auto-labels by focus area.
- Structured logging: `lib/log.sh` (info/warn/error), unified daily log (`pilot-YYYY-MM-DD.log`), error → Slack alerting
- New metrics: triage CSV (verdicts per run), cleanup CSV (archives per run)
- Log rotation: health report archives files > 14 days weekly
- Triage comments now show actual model used (not always "Gemini")
- Silent AI failures now surface via Slack alerts
- Health report: weekly dashboard with pipeline metrics, anomaly detection, service health check
- `init.sh`: interactive setup wizard for new projects
- Full documentation: architecture.md, adapters.md, tuning.md, deployment.md
- **New schedule:** Discovery Sun/Tue/Thu 10 PM | Triage Sun/Tue/Thu 10:30 PM | Builder Mon-Fri 11 PM | Tuners Sunday 9 PM | Health Sunday 8 AM
- **Reduced responsibility:** No orchestrator to manage. Services are independent — if one fails, others continue. Override individual services with `launchctl unload/load`.

### 2026-04-02 — Test Suite + RESCOPE Verdict
- Added 105-test bats-core suite with two-tier execution across 16 test files in `~/development/pilot/tests/`
- Fast tier (101 tests): runs on every commit via git pre-commit hook (`.githooks/pre-commit`)
- Full tier (105 tests): runs on push via GitHub Actions CI (`.github/workflows/test.yml`)
- Auto-discovery smoke tests: fail when new scripts lack test coverage — enforces that every new script gets tests
- Adapter contract tests: verify interface stability across swappable adapters
- PATH-based mocking for external commands (claude, gemini, linear, curl, gh)
- `_PILOT_TEST_MODE=1` guard added to all scripts to skip `project.env` sourcing during tests
- GNU parallel for parallel test execution (`bats -j 8`)
- Added RESCOPE verdict to triage agent: splits oversized issues into 2-4 sub-issues and cancels the original
- **New responsibility:** When making manual changes to pilot scripts, add/update corresponding bats tests. Pre-commit hook will catch missing coverage for new scripts.
