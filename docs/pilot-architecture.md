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
**Models:** Gemini 2.5 Flash (web research, via the Gemini REST API + Google Search grounding) + Claude Opus (analysis)

**What it does:**
- Phase 1 (Gemini): Searches the web for the current focus area. Runs through the `ai-research.sh` adapter, which calls the Gemini API with the `GEMINI_API_KEY` (Flash is free-tier; the retired OAuth CLI is no longer used). If research fails it **alerts loudly** and Claude self-researches instead of degrading silently.
- Phase 2 (Claude): Cross-references findings against the codebase, existing backlog, canceled issues, and product decisions. Creates specific, actionable GitHub issues.

**Focus area rotation (GA-readiness mode, since 2026-08-21):** Lift is feature-complete and in beta; discovery now hunts only stabilization work. Six focus areas in a weighted 20-slot cycle (~6.5 weeks at 3 runs/week): `bug-hunt` ×5 (codebase bug hunting: races, unhandled rejections, data loss, edge cases), `performance` ×4, `ux-polish` ×4 (refinement of existing flows — states, consistency, friction), `accessibility` ×3, `pwa-reliability` ×2 (offline sync correctness, SW update flow), `security-deps` ×2. The discovery prompt forbids net-new feature and test-only issues, requires every finding to cite a code location, and caps output at 2–6 discoveries (zero is valid — no quota padding). Retired feature-research areas (competitors, ui-trends, testing, seo-aso, data-viz, onboarding, dx-cicd, monetization, marketing, growth, pwa-patterns) keep their prompts for manual runs (`discover.sh <focus>`) but never enter the rotation. A `QUEUE_VERSION` stamp (`data/lift-discovery-queue.version`) discards any queue written by an older rotation, so stale focus areas can't run after a rotation change ships.

**Self-improvement:** Reads [product decisions](pilot-responsibilities.md#product-decisions) and canceled issues to avoid recreating rejected features.

### 2. Triage Agent
**Script:** `~/Documents/Scripts/lift-triage.sh`
**Schedule:** Nightly after discovery (second stage)
**Model:** Gemini 2.5 Flash (via the Gemini REST API, no grounding — reasons over the prompt) with Claude Sonnet fallback

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

**GA-readiness gate (since 2026-08-21):** the triage prompt carries a standing policy — Lift is stabilizing for GA, so only bug fixes, performance, UX refinement, accessibility, and security work passes. Net-new features and monetization/growth/marketing issues get SKIP with "deferred until post-GA"; test-only additions get SKIP (tests ship only as regression proof inside bug fixes); refactors pass only when they unblock a fix.

**In-flight deferral (since 2026-08-28):** before reviewing anything, triage drops every issue that already has an **open PR**. Triage was the last stage that never consulted pull requests — `triageable` is label-based and excludes only `{started, blocked, needs-input, canceled}`, so an issue whose PR was open but whose state label had never been flipped to `state:started` looked like untouched backlog. A RESCOPE verdict then forked live, already-implemented work into brand-new issue numbers that every issue-identity-keyed dedupe downstream waved through. This is a **deferral, not a skip**: the issue is left completely untouched and returns to triage scope the moment its PR merges or closes, so a false positive costs one triage cycle and can never drop an issue. The check fails open — if the `gh` call errors, nothing is deferred. Deferrals are printed to the triage log and posted to the run's Slack thread.

**Re-triage sweep:** `triage.sh --re-triage` re-reviews ALL triageable issues (including already-triaged ones) under the current policy — a one-shot re-baseline for policy changes like the GA shift. Comments are marked "Re-triaged by …", which the nightly idempotency grep already accepts, so swept issues aren't re-reviewed every night. Parked issues (needs-input / blocked / started) are untouched. Combinable with `--dry-run`.

**Acceptance criteria (since 2026-08-28):** APPROVE/ENHANCE verdicts also emit `ACCEPTANCE_CRITERIA` — 2–4 testable, user-observable criteria (pipe-separated in the model output), rendered into the triage comment as a definition-of-done checklist. The builder treats them as binding: each criterion is verified before push and confirmed explicitly in the PR's Verification section. This gives every issue an explicit Definition of Ready/Done instead of an implied one.

**Why it matters:** The builder (Opus) reads these comments before implementing. Better plans = stronger implementations. Aaron spends less time triaging raw issues.

### 3. Overnight Builder
**Script:** `~/development/pilot/scripts/builder.sh`
**Shared lib:** `~/development/pilot/lib/builder-utils.sh` (budget guards, verdict logic, review formatting)
**Schedule:** Nightly after triage (third stage, runs until 7 AM)
**Model:** Claude Opus 5 (1M context, max effort) — pinned via `AI_CODE_MODEL`/`AI_CODE_EFFORT` in `project.env`

**What it does:**
- **Auth preflight (before the loop):** one cheap `claude` probe down the real code path. If the keychain OAuth token is expired/logged-out, every iteration would 401; rather than burn the loop silently, the builder aborts immediately and alerts #lift-automation. Auth failures are classified by `is_auth_failure()` in `builder-utils.sh`; transient/network errors are *not* auth signatures and fall through to normal per-iteration handling. Skippable with `SKIP_AUTH_PREFLIGHT=1`. (Added 2026-06-23 after two silent zero-PR nights.)
- **WIP limit (since 2026-08-28):** before each iteration the loop counts open PRs; at `MAX_OPEN_PRS` (default 8, `0` disables) it stops for the night with a Slack notice instead of growing Aaron's review queue — Kanban backpressure pointed at the human constraint. Retry iterations for `ci:failed` PRs are exempt (their old PR is closed at startup, so they don't grow the queue). Decision logic: `wip_gate_active` in `lib/builder-utils.sh`.
- **Rejection learnings (since 2026-08-28):** every iteration's prompt carries the tail of `data/lift-build-learnings.md` — Aaron's closing comments on PRs he closed unmerged, harvested nightly by cleanup — as binding do-not-repeat guidance. This restores the human-feedback loop that died with the review tuner (2026-05-11).
- Picks the highest-priority triaged issue from the backlog (GA tie-break since 2026-08-21: at equal priority, user-facing bug fixes > performance/reliability > UX/a11y polish; refactors, test-only work, and feature-shaped issues last). The per-iteration inline discovery follows the same GA rules — defects and refinements only, no feature or test-coverage issues.
- Reads the triage agent's implementation plan from comments
- Creates a dedicated branch per issue: `enhance/LIFT-{id}-{date}`
- Implements the change: writes code, runs tests, commits with conventional prefixes (feat/fix/a11y/test/perf/style/refactor/chore)
- Per-iteration Gemini  cross-model review after each iteration's commits (see section 4 below)
  - Critical/high findings → Opus auto-fix attempt; if fix fails, revert + create GitHub issue
  - Medium/low findings → auto-created as Linear issues for future work
- Creates a PR per issue with structured description: issue links, test results, review status
- PRs labeled by type (type:a11y, type:test, type:bugfix, type:feature, etc.)
- Failed PR retry: PRs labeled `ci:failed` from previous nights are auto-retried
- Updates issue tracker (marks issues In Progress/Blocked; closure deferred to PR merge via "Closes #N"). Post-run marker parsing goes through `_marker_lines` in `builder-utils.sh`, which accepts every separator the agent actually emits (`ISSUE_DONE:LIFT-N:summary`, `|`, em dash, or a bare marker) and normalizes them to a single pipe. The parsers previously required the pipe form the prompt asks for, which the agent had never once emitted — see the 2026-08-28 changelog entry.
- Repeats for up to 12 iterations or 500K output tokens

**Controls** (auto-tuned **weekly**, Sunday 21:00, by `tune-budget.sh`; `--dry-run` reports what it would change without writing):
- Max iterations per night (default: 12)
- Max output tokens per night (default: 500K)
- Cooldown between iterations (default: 30s)
- Stops on 3 consecutive failures or 2 consecutive stalls
- Runtime tracked per-iteration and per-pipeline — tuner uses utilization % to adjust caps

**Manual override:** `PICKED_ISSUE_OVERRIDE=LIFT-NNN ./scripts/builder.sh 1` forces the first iteration to work on a specific issue, skipping the pre-pick stage. Intended for one-off "fix this issue now" runs; the override is cleared after use so a multi-iteration loop falls back to normal pre-picking for subsequent iterations.

### 4. Inline Hook-Based Review
**When:** Automatically during Claude's implementation, after each commit via git post-commit hook
**Model:** Claude Sonnet (single model, adversarial review of the full branch diff, independent from the Opus builder). Overridable via `PILOT_REVIEW_MODEL`.
**Script:** `~/.claude/scripts/review-router.sh` (builder mode, triggered by `PILOT_BUILDER=1`)

**How it works:**
- **Primary mechanism — git post-commit hook (fires for any git operation, including headless `claude -p` mode):**
  - `.husky/post-commit`: after each commit, sends the full branch diff (vs master) + changed files + resolved imports + CLAUDE.md to a headless `claude -p` reviewer (default Sonnet) for an adversarial audit. Blocks until complete.
- **Same Claude auth that powers the builder** — a different model (Sonnet) than the Opus author, so it's genuinely adversarial, with no external vendor and no extra billing. Replaced the Gemini CLI on 2026-07-16 (see Note below).
- **No Codex (GPT-5.4)** — removed 2026-04-06 as a distinct reviewer; the broken `codex review` fallback was dropped in the 2026-07-16 migration.
- **Builder prompt references the post-commit Claude review** — Claude sees findings inline right after committing and fixes them in follow-up commits before pushing. No separate fix iteration needed.
- **No PR comments:** Issues resolved before PR creation. PRs that reach morning triage are already reviewed.
- **Audit trail:** Output logged to `$OUTPUT_DIR/lift-review-$DATE-run${RUN}.log`.
- **Fails loud (not silently):** if the reviewer errors or times out, the hook emits a `REVIEW FAILED` marker and (in builder mode) posts a Slack alert to #lift-automation, then lets the build continue — it never blocks the push, but the failure is visible. This replaced the old silent-skip behavior that hid a ~2.5-week Gemini outage.

**Secondary mechanism — builder-side pattern scan (`lib/security-scan.sh`):** Before the builder pushes an iteration branch (`scripts/builder.sh`, after commit detection), it greps the full `master...HEAD` diff for prompt-injection / exfiltration signatures: network calls, non-public env access, dynamic code execution (`eval`/`exec`/`spawn`/`Function`), base64/charcode obfuscation, crypto-mining strings, and image-beacon exfiltration. A hit blocks the push for that iteration (`continue`) and posts to Slack. This is a regex heuristic, so it carries false-positive risk and the patterns are tuned narrowly: the `Function` arm is case-sensitive (lowercase `function ()` IIFEs are fine — LIFT-545, 2026-05-12) and the `exec` arm excludes method calls so `RegExp.prototype.exec()` is not flagged (LIFT-653, 2026-05-27). Regression-tested by `tests/security-scan.bats`.

> **Note:** The review pipeline has been progressively simplified, then re-platformed off Google. Gemini review (Flash → Pro → Sonnet) was replaced with inline hooks on 2026-04-06, simplified to Gemini 3.1 Pro only, then **migrated to a headless Claude reviewer on 2026-07-16**. Google retired the free "Gemini Code Assist for individuals" OAuth tier on 2026-06-18 — the `gemini` CLI began returning `IneligibleTierError` / `UNSUPPORTED_CLIENT` ("migrate to Antigravity"), which silently broke every review from ~2026-06-30 on. Google AI Pro/Ultra grant no Gemini API or CLI access, and the Gemini API free tier excludes all Pro models (`limit: 0`), so restoring Gemini would require enabling paid Cloud billing. The reviewer is now a `claude -p` call (Sonnet by default, `PILOT_REVIEW_MODEL` overridable) on the same auth as the builder. The old adapter (`adapters/ai-review.sh`) was deprecated 2026-04-06 and **deleted 2026-07-17** — it had no callers, and its `gemini` CLI calls would have failed the same way; the review tuner was removed on 2026-05-11. There is deliberately no review adapter: review is a hook, not a swappable backend.

### 5. Auto-Tuners
**Scripts:** `tune-budget.sh`
**When:** Sunday 21:00, weekly (`com.aaron.pilot-tune-budget`)

**Budget tuner:**
- Analyzes last 7 nights of token usage and runtime
- Adjusts iteration cap, token cap, and cooldown based on productivity patterns
- Raises caps when consistently productive, lowers when stalling
- Runtime-aware: if pipeline uses <25% of the overnight window, suggests raising iteration cap
- Detects context bloat: flags when per-iteration duration trends up >50%

> **Removed 2026-05-11:** The review tuner (`scripts/tune-reviews.sh`, weekly at Sun 21:15) was deleted. It was deprecated 2026-04-06 when the review system moved to inline hooks (no PR comments to learn from). Its `lift-review-learnings.md` data file had one remaining reader, `adapters/ai-review.sh`; that adapter was deleted 2026-07-17, so nothing reads the learnings file now.

> **Was inert until 2026-08-28.** The tuner never adjusted a single value in its life. Its Python heredoc had the positional arguments on the line *after* the `PYEOF` terminator, so `python3` ran with an empty argv — every CSV path defaulted to `""`, it found no data, and it always returned `skip: True`. Bash then tried to *execute* the CSV path as a command: "Permission denied", exit **126**, which is what `launchctl list` had been reporting. Five unit tests passed throughout, because each one re-implements the Python inside the test file and none ever ran the real script. A second bug hid behind the first: `int(row.get('commits', 0))` returns `None` on a short row (`csv.DictReader` fills missing columns with `None`, so the `get` default never applies), which crashed on the 30 ragged rows in `lift-metrics.csv`. Both fixed; the end-to-end tests now drive the real script.

### 6. Service Health (inside the Health Report)
**Library:** `lib/service-health.sh` — pure function, called by `scripts/health-report.sh`
**When:** Sunday 08:00, with the weekly Health Report

Until 2026-08-28 nothing in the pipeline read launchd exit codes. That is how two agents stayed broken in plain sight for months: `tune-budget` had reported **exit 126** since its very first run, and `roadmap-synth` **exit 1** every week since 2026-05-06. Both were one column of `launchctl list` away from being obvious. The check that existed was hardcoded to three services (discover / triage / builder) and only asked whether they were *loaded* — never how they *exited* — so neither failure was reachable by it.

The service list is now **derived from the committed plists**, so a new service is covered the moment it is added rather than when someone remembers to extend a list. Three questions, ordered by how long each failure can hide:

| Question | Failure it catches |
|---|---|
| Is a committed plist not loaded? | It never runs, and nothing says so |
| Did a loaded service exit non-zero? | It runs and fails, silently |
| Is its log older than its own cadence? | Loaded, but never actually firing |

Exit codes 126 ("command found but not executable") and 127 ("command not found") get an explanatory hint, since those two are what a broken invocation looks like — 126 is precisely what the tuner's malformed heredoc produced.

Cadence for the staleness check is derived from each plist's own `StartCalendarInterval` (weekday present ⇒ weekly, else daily), with a generous `2× + 1 day` threshold so one skipped run is not noise. A plist younger than one full cadence is exempt entirely — otherwise every newly loaded service reads as broken, which is exactly what happened to the two plists loaded on 2026-08-28 before the exemption was added.

Findings land in both the report's **Services** section and its **Anomalies** list, so they reach Slack. Half the tests assert it stays *quiet*: a weekly report that cries wolf gets skimmed, then ignored.

### 7. Stale-PR Audit
**Script:** `stale-pr-audit.sh`
**Schedule:** Sunday 08:15, weekly (`com.aaron.pilot-stale-pr-audit`) — right after the Health Report, and ~14h before Sunday's Discovery so anything it flags can be closed or landed before the next build cycle picks work up
**Model:** none — pure git/gh analysis, no AI call

Every other dedupe guard in the pipeline is keyed on issue *identity*: "does this issue already have an open PR?" That question cannot see work rebuilt under a **different** issue number, which is exactly what produced the LIFT-783 / LIFT-1039 duplicate. This audit asks the other question, against the codebase rather than the tracker: **does merging this PR still change anything?**

| Check | Method | Catches |
|---|---|---|
| No-op merge | `git merge-tree --write-tree` vs master; flags when the merged tree equals master's | A PR that is wholly redundant and can just be closed |
| Duplicate migration | Every `ADD COLUMN` the PR introduces that master's migrations already add | The #1041 shape — a redundant migration inside an otherwise non-empty PR, invisible to the no-op check |
| Column collision | Two **open** PRs adding the same column | The pre-merge form of the above; fires while both are still open, when the duplicate is cheapest to kill |

Read-only against Lift: it fetches refs and uses `merge-tree`, never checking anything out. Writes `data/lift-stale-pr-audit-YYYY-MM-DD.md` and, with `--notify`, posts findings to #lift-automation. The scheduled run passes `--notify`; a clean week posts a one-line "clean" so silence always means a broken job, never a passing one.

**Why not a freshness check at build time.** Verified against the incident: when PR #1041 was opened, its "duplicate" column was not yet in master — it lived only in the still-open PR #1032, and master stayed clean for six more days. Checking the codebase at build time would have found nothing. The signal existed only in the open-PR set, which is why the collision check is the one that fires (retro-validated: it reports `exercises.plate_count_mode added by PRs [1032, 1041]` on the day #1041 was created).

### 8. Doc-Drift Audit
**Script:** `doc-drift-audit.sh` (checks live in `lib/doc-drift-check.py`)
**Schedule:** Sunday 09:00, **biweekly** (`com.aaron.pilot-doc-drift`)
**Model:** none — pure filesystem/plist analysis, no AI call

The documentation mandate says docs ship with the change. They drift anyway, and silently. On 2026-08-28 the responsibilities doc still listed a Review Tuner deleted 3.5 months earlier, claimed "6 independent services" when there were 9, cited a retired orchestrator plist, and reported test counts less than half the real number — none of it visible without reading the docs against the filesystem line by line.

This does that mechanically. It is a **reporter, never an editor**: every finding needs a human call about which side is wrong, and sometimes the doc is right and the code is the bug.

| # | Check | Catches |
|---|---|---|
| 1 | Scripts absent from README / architecture doc | New scripts that never got written up |
| 2 | A `*.sh` named in the docs that no longer exists | The Review Tuner class of decay |
| 3 | Plists missing from, or disagreeing with, the schedule tables | The Wednesday-trio omission; wrong times |
| 4 | Plist `ProgramArguments` pointing at a missing script | A service that silently never runs |
| 5 | Test counts claimed vs. the real suite (both tiers) | Stale numbers after adding tests |
| 6 | Adapters absent from CLAUDE.md | Undocumented backends |
| 7 | Pilot env vars read by scripts but undocumented | The env-var half of the mandate |
| 8 | Obsidian vault paths Pilot depends on that don't resolve | Silent degradation of discovery/triage |

**Two design rules keep it trustworthy.** Changelog sections are excluded from every check — history is *supposed* to describe the past. And doc **tombstones** ("the old `ai-review.sh` was deleted 2026-07-17") are recognized as the docs doing their job, not as drift; a line announcing a removal suppresses the finding. Both are pinned by tests, along with scripts that legitimately live outside the repo (`~/Documents/Scripts/set-claude-token.sh`) and counts that quote either test tier. Without those exemptions the report cries wolf, and a report that cries wolf gets ignored.

**Vault scope.** Only the vault files Pilot itself reads or names are checked — `PRODUCT_DECISIONS_FILE`, `PRODUCT_FEATURES_FILE`, and vault paths cited in Pilot docs. Aaron's vault workflows are a separate domain and are not audited. A broken path here is a *Pilot* bug: discovery and triage degrade silently without it.

**Biweekly cadence.** launchd cannot express "every two weeks", so the plist fires weekly and the script no-ops on odd ISO weeks (`--biweekly`). Calendar-anchored, so it cannot drift the way a 1,209,600-second `StartInterval` would.

### 9. Issue Cleanup
**Script:** `cleanup.sh`
**When:** After each overnight session (final stage of pipeline)

**What it does:**
- Closes completed/canceled issues that are still open on GitHub via the tracker adapter — issues already closed in a prior session are skipped (checked via `tracker.sh state`), so no redundant `gh issue close` writes are fired
- **Recycles abandoned in-progress issues** (added 2026-07-27) — see below
- **Snapshots the needs-your-call list + harvests rejection learnings** (step 2b, added 2026-08-28) — see below
- Detects duplicate issues by title (keeps oldest, cancels+archives newer copies)
- **Expires stale priority-4 backlog issues** (step 4, added 2026-08-28) — see below
- Keeps issue list clean — closes resolved/duplicate issues
- Reports `N closed`, `D deduped`, `R recycled`, `E expired`, `H learnings harvested`, and `K already closed, skipped`

**Backlog recycling.** The builder's pre-pick flips an issue to `state:started` *before* implementation. If that iteration then dies before opening a PR (auth blip, CI failure, context exhaustion, killed run), nothing clears the label — and because `tracker.sh list pickable` is exclusion-based, a `state:started` issue is removed from the picking pool permanently. This leaks the backlog one issue at a time until the builder starves.

Cleanup now sorts every `state:started` issue into four buckets by cross-referencing PR titles (three `gh pr list` calls, not a per-issue search):

| Bucket | Condition | Action |
|---|---|---|
| Recycle | no PR of **any** state references it | auto-reset to `state:unstarted` |
| In flight | has an **open** PR | none (normal state) |
| Done, awaiting close | has a **merged** PR | reported as a count |
| Needs your call | every PR was **closed unmerged** | reported by ID — never auto-recycled |

The rule is deliberately conservative: only the "no PR ever" case is unambiguous. A closed-unmerged PR may have been a deliberate rejection, so auto-recycling it would rebuild work Aaron already declined — those are surfaced for a human decision instead.

Recycled counts are appended to `data/lift-cleanup-metrics.csv` as a fourth `recycled` column; `expired` was added as a fifth on 2026-08-28. Rows written earlier have three or four fields, so parsers must tolerate all widths.

**Needs-your-call snapshot + rejection-learnings harvest (step 2b, since 2026-08-28).** The "closed unmerged — needs your call" bucket used to live only in an overnight log; now it feeds two consumers:
- `data/lift-needs-decision.txt` — a nightly overwrite of the current rejected-PR issue IDs. The morning digest reads it and renders the "⚖️ Needs your call" line, so these decisions surface in the daily standup instead of rotting.
- `data/lift-build-learnings.md` — for every PR closed *without* merging in the last 14 days, cleanup appends one entry (`## PR #N — title (closed unmerged date)`) containing the closing comment: the repo owner's last comment wins, other human comments count, bot comments are ignored, and a missing comment is recorded as a nudge to leave one. Entries are keyed by `## PR #N ` so re-runs are idempotent. The builder injects the tail of this file into every iteration prompt — Aaron's merge/reject decisions finally train the pipeline again (the review tuner that used to do this was removed 2026-05-11).

**Backlog expiry (step 4, since 2026-08-28).** Triage SKIP demotes issues to `priority:4-low` and nothing ever revisited them — they accumulate forever and creep toward the adapter's silent `--limit 200` truncation cliff. Any open `priority:4-low` issue untouched for `BACKLOG_EXPIRY_DAYS` (default 56, `0` disables) is closed as not planned with a reopen invitation. Parked issues (`state:started` / `state:blocked` / `state:needs-input`) never expire — those are waiting on a human, not forgotten.

> **Adapter query limits.** Every open-issue query in `tracker.sh` shares a single cap, `GH_OPEN_LIMIT` (default **1000**, overridable by env). Truncation here fails *silently* — `gh issue list` just returns a short list with no error — so a stale cap hides issues from every consumer at once. This has bitten twice: `list <state>` was capped at 100 until 2026-07-27, hiding 31 `state:started` issues from the recycler; the 200 cap that replaced it was found on 2026-08-28 hiding **8 of 10** triageable issues and **3 of 5** pickable ones behind 265 open issues, leaving the builder to choose from a pool of 2. `gh_list` now also warns on stderr when an open-issue query comes back at exactly the cap, which is the only externally visible symptom of truncation. Keep `GH_OPEN_LIMIT` comfortably above the real open-issue count.

### 10. PR-Close Reconcile
**Script:** `pr-close-reconcile.sh`
**When:** Automatically, as the first step of every Triage run — immediately before its `list triageable` query, so an issue released from `state:started` is triaged in the same run. Triage passes `--apply` (or `--dry-run` when triage is dry-run) and treats a failure as non-fatal. Kill switch: `PR_RECONCILE_ENABLED=0`. Also runnable by hand.

**The leak.** An issue flips to `state:started` when its PR opens. When that PR is closed **unmerged**, nothing resets the label, so the issue keeps `state:started` forever — and `tracker.sh`'s `triageable` query excludes `state:started`, so the issue becomes permanently invisible to Triage. Nothing re-examines it, while the builder keeps seeing a backlog entry whose implementation was already rejected.

Measured 2026-08-28: **74 of 107 open Lift issues carried `state:started` with zero open PRs** — 69% of the backlog unreachable by the pipeline's own self-cleaning stage. The audit that day closed 149 issues, 41 of them "PR closed, issue left open".

**What it does.** For each unmerged PR closed inside the lookback window (`--since`, default 14d) whose linked issue is still open:

| Signal | Action |
|---|---|
| Title and body issue links **agree**, and the closing comment carries a rejection verdict | close the issue `not planned`, quoting the verdict |
| Link from only one source, or no verdict | reset `state:started` → `state:triage` — never closed |
| Title and body links **disagree** | reported for a human; nothing is touched |

`state:triage` rather than `state:unstarted` is deliberate: triageable but **not** pickable, so a reconciled issue is re-examined before the builder can spend a run on it.

**Trust model.** PR link metadata in the Lift repo is unreliable — PR #1065 is titled `feat: add superset/circuit grouping for exercises (#616)` while its body reads `Issue: LIFT-1064`, an unrelated manifest issue, because the builder reused a body template. Trusting either source alone would have closed a legitimate issue. Closing therefore requires two agreeing signals; anything weaker downgrades to the safe action.

**Relationship to Issue Cleanup (section 9).** `cleanup.sh` already derives this bucket and deliberately refuses to act on it ("a closed-unmerged PR may have been a deliberate rejection … surfaced for a human decision instead"). This script does not repeal that rule — it resolves only the subset where the decision is **already recorded** as a verdict on the PR. Everything else still reaches Aaron through cleanup's `data/lift-needs-decision.txt` and the digest's "⚖️ Needs your call" line. The rule failed in practice not because it was wrong but because the list was never worked: it reached 74.

> **Divergence risk.** cleanup.sh independently derives the same bucket and harvests the same closing comments (into `data/lift-build-learnings.md`). Two derivations of one fact drift — change the bucket rule in both files or collapse them.

Defaults to a dry run when invoked bare; Triage passes `--apply`. Writes `data/lift-pr-close-reconcile-YYYY-MM-DD.md`; `--notify` posts a summary to #lift-automation. If the candidate extractor fails it **aborts** rather than reporting an empty result set, because a crash that looks like a clean run is the failure mode the script exists to prevent.

---

## Testing Infrastructure

The pipeline has a bats-core test suite with **307 tests across 24 test files** in `~/development/pilot/tests/`. Tests use two-tier execution to balance speed with thoroughness:

**Fast tier (288 tests) — pre-commit hook:**
- Runs before every commit via `.githooks/pre-commit`
- Covers: unit tests, adapter contract tests, argument parsing, error handling, log formatting
- Builder tests source real functions from `lib/builder-utils.sh` (not copies of logic)
- Parallel execution via GNU parallel (`bats -j 8`)
- Blocks commit if any test fails

**Full tier (307 tests) — GitHub Actions CI:**
- Runs on every push via `.github/workflows/test.yml`
- Includes everything in the fast tier plus integration-level tests (CSV analysis, full script invocations)
- Test paths resolve dynamically (no hardcoded local paths) for CI runner compatibility

**Key testing patterns:**
- **Auto-discovery smoke tests:** Automatically detect new scripts in `scripts/` and `adapters/` that lack corresponding test files. These tests fail when coverage is missing, ensuring the test suite grows with the codebase.
- **Adapter contract tests:** Verify that all swappable adapters (tracker, notify, ai-code, ai-research) conform to their expected interface — correct flags, exit codes, and output formats.
- **PATH-based mocking:** Mock commands (claude, gemini, linear, curl, gh) are injected via PATH so scripts under test call mocks instead of real external services. No network calls during tests.
- **Test mode guard:** All scripts check `_PILOT_TEST_MODE=1` and skip `project.env` sourcing when set, allowing tests to run in isolation without Lift-specific configuration.

---

## Scheduled Tasks

Pipeline is fully decomposed — each service has its own launchd plist. No orchestrator.

| Time | Service | Schedule | Plist |
|---|---|---|---|
| 6:15 AM | Issue Digest | Daily | `com.aaron.linear-digest` |
| 8:00 AM Sun | Health Report | Weekly | `com.aaron.pilot-health` |
| 8:15 AM Sun | Stale-PR Audit | Weekly | `com.aaron.pilot-stale-pr-audit` |
| 9:00 AM Sun | Doc-Drift Audit | Biweekly (even ISO weeks) | `com.aaron.pilot-doc-drift` |
| 6:00 PM Wed | Auditor | Weekly | `com.aaron.pilot-auditor` |
| 7:00 PM Wed | Roadmap Synth | Weekly | `com.aaron.pilot-roadmap` |
| 8:00 PM Wed | Architect | Weekly | `com.aaron.pilot-architect` |
| 9:00 PM Sun | Budget Tuner | Weekly | `com.aaron.pilot-tune-budget` |
| 10:00 PM | Discovery | Sun/Tue/Thu | `com.aaron.pilot-discover` |
| 10:30 PM | Triage | Sun/Tue/Thu | `com.aaron.pilot-triage` |
| 11:00 PM | Builder + Cleanup | Mon-Fri | `com.aaron.pilot-builder` |

> The Wednesday trio (auditor / roadmap / architect) and the Issue Digest were missing from this table until 2026-08-28; it is now generated from the plists' actual `StartCalendarInterval` values.

---

## Model Allocation

| Agent | Model | Rationale |
|---|---|---|
| Discovery (research) | Gemini 2.5 Flash (Gemini API + Google Search grounding) | Grounded web search returns real URLs/versions, saves Claude tokens. Free tier via `GEMINI_API_KEY`. |
| Discovery (analysis) | Claude Opus 5 (1M, max effort) | Best at codebase reasoning + issue creation |
| Triage | Gemini 2.5 Flash via Gemini API (Claude Sonnet fallback) | Good at planning; free-tier Flash via `GEMINI_API_KEY`. **Not** Google AI Pro — that consumer subscription grants no API access. |
| Builder | Claude Opus 5 (1M, max effort) | Best coding model, complex multi-file changes |
| Architect | Claude Fable 5 (1M default, max effort) — `AI_ARCHITECT_MODEL`, falls back to `AI_CODE_MODEL` | Deepest whole-codebase reasoning in the pipeline; weekly cadence bounds the 2× price |
| Review (commit) | Claude Sonnet (`PILOT_REVIEW_MODEL` overridable) | Inline via post-commit hook — adversarial review of full branch diff, independent from the Opus builder. Single model, single pass. Re-platformed off the retired Gemini CLI on 2026-07-16; uses the builder's Claude auth (no extra billing). |
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
Gemini Flash (web research — grounded Google Search via Gemini API)
    ↓
Claude (analysis) → GitHub issues created
    ↓
Gemini Flash (triage — via Gemini API, Claude Sonnet fallback) → Implementation plans added as comments
    ↓
Claude Opus (builder) → Per-issue branch + code committed
    ↓
Claude adversarial review (post-commit hook, review-router.sh):
    → Single model (Sonnet), single pass — reviews full branch diff, independent from the Opus author
    → Claude sees findings inline after each commit and fixes before pushing
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
Feedback loop → canceled issues + product decisions steer discovery;
    closing comments on PRs Aaron rejects are harvested nightly (cleanup)
    into lift-build-learnings.md and fed back into the builder prompt
```

---

## Key Files

| File | Purpose |
|---|---|
| `~/development/pilot/` | Version-controlled repo for all pipeline code ([GitHub](https://github.com/aschung212/pilot)) |
| `~/development/pilot/scripts/` | All pipeline scripts (symlinked to `~/Documents/Scripts/`) |
| `~/development/pilot/adapters/` | Swappable tool adapters (tracker, notify, ai-code, ai-research) |
| `~/development/pilot/lib/log.sh` | Shared structured logging library |
| `~/development/pilot/config/budget.conf` | Budget config (auto-tuned) |
| `~/development/pilot/scripts/stale-pr-audit.sh` | Weekly audit: open PRs whose work has already shipped (no-op merges, duplicate/colliding migrations) |
| `~/development/pilot/scripts/pr-close-reconcile.sh` | Closes/re-triages issues whose PR was closed unmerged — the state:started leak that hid 69% of the backlog from Triage |
| `~/development/pilot/scripts/doc-drift-audit.sh` | Biweekly audit: docs vs. the repo's actual state (checks in `lib/doc-drift-check.py`) |
| `~/development/pilot/tests/` | bats-core test suite (307 tests, 23 files, two-tier execution) |
| `~/development/pilot/.github/workflows/test.yml` | GitHub Actions CI — full test suite on push |
| `~/development/pilot/.githooks/pre-commit` | Pre-commit hook — fast test tier on every commit |
| `~/development/pilot/project.env` | Lift-specific configuration (git-ignored) |
| `~/development/pilot/init.sh` | Interactive setup wizard |
| `pilot/data/` | All logs, metrics, usage tracking, learnings |
| `pilot/data/pilot-YYYY-MM-DD.log` | Unified structured log (all components) |
| `pilot/data/lift-build-learnings.md` | Aaron's closing comments on rejected (closed-unmerged) PRs — harvested nightly by cleanup, injected into the builder prompt |
| `pilot/data/lift-needs-decision.txt` | Nightly snapshot of rejected-PR issues awaiting Aaron's call — surfaced by the morning digest |

See [Pilot Responsibilities](pilot-responsibilities.md) for the complete list of Aaron's manual tasks, automated tasks, environment variables, and changelog.

---

## Changelog

### 2026-08-28 — Backlog audit (149 issues closed) + PR-close reconcile

A full audit of the Lift backlog closed **149 of 255 open issues** — 58%. Breakdown: 34 already shipped on master, 36 whose PR was closed unmerged (rejection, stale, or silent), 19 in the dead Supporter/monetization thread, 11 duplicates, 2 obsolete, plus a bloat pass closing 41 more (7 chart affordances, 10 coverage-chasing tests, 7 architect refactor churn, 6 speculative perf, and overlapping onboarding/share items).

**Root cause 1 — the `state:started` leak.** `triageable` in `tracker.sh` excludes `state:started`, so an issue whose PR closed unmerged became permanently invisible to Triage. 74 of 107 open issues carried it with **zero** open PRs. All 74 were repaired to `state:triage`. New `scripts/pr-close-reconcile.sh` (agent section 10, +8 bats tests) prevents recurrence.

**Root cause 2 — retired discovery focuses are reachable with no guard.** The GA shift (`da78cc4`, 2026-08-21) correctly removed the feature-hunting focuses from the rotation: the queue is now `bug-hunt / performance / ux-polish / accessibility / pwa-reliability / security-deps`, stamped `2026-08-21-ga`. But "retired from rotation" is enforced by nothing — `discover.sh <focus>` accepts any name still present in the `case` block, and those retired prompts are unchanged since 2026-04-01, still soliciting exactly what the GA rules forbid (`competitors` still reads "Find features users love that Lift is missing").

`data/lift-discovery-log.md` shows it happening: **`[testing]` ran 2026-08-23 and `[monetization]` ran 2026-08-25**, producing #1188–#1191 and the #1201–#1205 Supporter cluster — 9 of the issues this audit closed, and monetization is banned outright by the GA rules. **Fix pending:** gate the retired focuses behind an explicit opt-in so a bare `discover.sh testing` refuses.

[pilot#28](https://github.com/aschung212/pilot/issues/28) tracks the filing-side guards (filed during this audit as LIFT-1263 and relocated the same day — it is a Pilot defect, not a Lift one) (dedupe against open issues, grep master before filing, check closed/rejected, honour settled patterns in CLAUDE.md).

### 2026-08-28 — Pilot's own issue queue: defects-only contract, working dedupe, and a consumer

The Pilot repo's issue queue was write-only: the auditor filed there, and nothing — no agent, no digest, no human surface — ever read it. Nine stale `[Audit P1]` issues sat unread for months. Worse, they were **two** findings re-filed weekly: the auditor's idempotency search (`find_existing_audit_issue`) matches the stable finding ID against the *title*, but the ID only ever appeared in the *body*, so the dedupe had never fired once. Three changes, plus a queue purge:

- **Merge-bandwidth metrics no longer file issues** (`audit_issue_worthy` in `lib/auditor-utils.sh`, consulted in `pipeline-auditor.sh`'s filing loop). Aaron's ruling closing pilot#9–#19: `cost_per_pr_drift` and `time_to_merge_regression` both have *merged* PRs in the denominator, so they measure his review bandwidth, not pipeline health. Their legitimate use is backpressure (the builder's `MAX_OPEN_PRS` WIP gate); they still appear in the audit report, Slack digest, and history CSV — they just never escalate to an issue.
- **Auditor issue titles now embed the finding ID** — `[Audit P1] [<finding_id>] <title>` — so the existing title-search dedupe actually works. Repeat findings get a comment on the standing issue instead of a weekly duplicate.
- **The morning digest is the queue's consumer** (`digest.sh`): a "⚙️ Pilot pipeline" section lists open Pilot-repo issues with links, rendered only when the count is nonzero. The queue is defects-only and near-empty by design, so the section is silent almost every morning and loud exactly when a pipeline defect is waiting.
- **Queue purge:** pilot#9–#19 closed as not planned (all bandwidth-metric re-filings, and the latest readings had decayed to P3 anyway). The queue's contract going forward: *pipeline defects a human must fix*, nothing else. No agent works these issues — the builder/triage/cleanup paths are hardcoded to `GITHUB_ISSUES_REPO` (Lift) and deliberately stay that way; a builder that edits its own pipeline would violate the Infrastructure Change Protocol permanently.

Tests: +8 (5 auditor — the `audit_issue_worthy` gate and both regression guards on the filing loop; 3 digest — section renders, section omitted when empty, gh failure tolerated). Suite green; `digest.sh --dry-run` and `pipeline-auditor.sh --dry-run` verified live.

### 2026-08-28 — Health Report watches launchd exit codes

`lib/service-health.sh` replaces the hardcoded three-service loaded/not-loaded check that let `tune-budget` (exit 126) and `roadmap-synth` (exit 1) stay broken for months. The service list is derived from the committed plists, and it reports not-loaded, non-zero last exit, and log-staler-than-cadence. Findings reach both the Services section and the Anomalies list. See agent section 6.

Staleness thresholds come from each plist's own schedule and exempt plists younger than one cadence, so newly loaded services don't read as broken. Also fixes the Anomalies section printing "✅ No anomalies" above the warnings it then listed.

### 2026-08-28 — Budget tuner and roadmap-synth: both broken since inception, both fixed

`tune-budget.sh` had never adjusted a value: its heredoc's positional args sat after the `PYEOF` terminator, so python3 ran with an empty argv (always `skip: True`) and bash tried to execute the CSV path — exit 126. Behind that, `int(row.get('x', 0))` crashed on `None` from short `DictReader` rows. Five unit tests passed the whole time because each re-implements the Python in the test file rather than running the script. Added `--dry-run`, and end-to-end tests that drive the real script.

`roadmap-synth.sh` had failed every week since 2026-05-06: Bun's `warn: CPU lacks AVX support` preamble made the captured envelope invalid JSON — the same breakage `builder.sh` was hardened against on 2026-05-19. The extractor now scans for the first parseable JSON line and strips Claude's ```json fence; replaying the real 2026-08-26 output recovers 10 themes.

Also corrected both docs' claim that the budget is "auto-tuned nightly" — it is weekly, and it was not tuning at all.

### 2026-08-28 — PR-creation failures now fail honestly (closes the last live fragment of pilot PR #8)

Cleared the pilot PR backlog: #24 (agile-gap pass) and #22 (model bumps) merged after conflict resolution; #8 (2026-05-12 builder hardening) closed as superseded — its marker normalizer landed as `_marker_lines` (2026-08-28), its side-branch recovery and branch-scoped commit counting landed 2026-05-20. One fragment of #8 was still live and is fixed here: when `gh pr create` failed and no PR existed for the branch, `builder.sh` fabricated a `pull/new/<branch>` **compare** URL, counted it as a PR, and handed Slack a fake "View PR" link (the 2026-05-11 incident: 12 "PRs" reported, 3 real). Now: new `extract_pr_url` in `lib/builder-utils.sh` anchors on `…/pull/<number>` (failure text mentioning github.com and compare URLs no longer match); if create + lookup both produce no PR, the iteration is scored a failure (counts toward `MAX_CONSECUTIVE_FAILURES`), a ❌ alert goes to the build thread with a link to the preserved branch, and the metrics row records `false` — the branch is deliberately not deleted so the work can be investigated. +2 bats tests.

### 2026-08-28 — Biweekly doc-drift audit

New `doc-drift-audit.sh` (checks in `lib/doc-drift-check.py`), scheduled `com.aaron.pilot-doc-drift` at Sunday 09:00 with a biweekly no-op on odd ISO weeks. Mechanically checks the docs against the repo — see agent section 8 for the full check list and the two exemptions (changelog sections, doc tombstones) that keep it from crying wolf.

First run found 19 real drifts, all fixed: a vault path missing its `Lift/` subdirectory, a stale `Fast tier (196 tests)` line, six scripts documented nowhere, and three undocumented env vars. It also caught a malformed XML comment in its own plist — `plutil -lint` accepts a `--` inside a comment, but launchd's parser and `plistlib` reject it, so the job would have silently never loaded.

### 2026-08-28 — Stale-PR audit scheduled weekly

`stale-pr-audit.sh` moved from on-demand to a weekly launchd job, `com.aaron.pilot-stale-pr-audit`, at **Sunday 08:15** with `--notify`. Slotted 15 minutes after the Health Report and ~14h ahead of Sunday's Discovery, so flagged PRs can be resolved before the next build cycle claims work. See agent section 7.

Also corrected the Scheduled Tasks table, which had been missing the Wednesday trio (Auditor / Roadmap Synth / Architect) and the daily Issue Digest since those services were added.

### 2026-08-28 — Duplicate-build root cause: a lost state flip, and triage forking in-flight work

**Incident.** LIFT-783 and LIFT-1039 ("Split from LIFT-783") were built independently as PR #1032 and PR #1041 — the same migration, the same always-send upsert field, the same setter. #1041 sat open for a month and merged with zero schema delta.

**Chain of causes** (each verified against the run logs and the GitHub timeline):

1. `2026-07-27` run 3's pre-pick emitted no parseable `ISSUE_PICKED` marker, so the deterministic `state:started` flip was skipped — the run log says so outright: *"state-flip-on-pick is skipped this iteration."* Stage 2 ran anyway, picked LIFT-783 itself, and opened PR #1032.
2. Both fallback flips then failed. The commit-driven flip skips any issue with an `ISSUE_DONE:` marker (its guard has no separator requirement, so it matched), and the `ISSUE_DONE` handler it defers to required a **pipe** separator that the builder agent has never emitted — **0 of 96** recorded runs use the pipe form; all use `ISSUE_DONE:LIFT-N:summary`. That handler had never executed. Its state flip, its "Implementation complete" comment, the PR title fallback, and the Slack digest links were all dead code.
3. LIFT-783 therefore kept `state:unstarted` while its PR was open.
4. `triage.sh` — the only stage that never consulted pull requests — saw it as untriaged, in-scope backlog, returned RESCOPE, created LIFT-1039, and canceled the parent. (The split itself was clean: the parent was canceled six seconds after the child was created. Parent/child leakage was **not** the bug.)
5. The builder picked LIFT-1039 the same night. A brand-new issue number has no open PR referencing it, so all three existing dedupe layers — discovery's do-not-duplicate lists, the builder's picking-time open-PR filter, the pre-PR guard — passed cleanly. Every one of them is keyed on *issue identity*, and the work had been laundered into a new identity.

**Fixes.**
- **`lib/builder-utils.sh`** — new `_marker_lines` normalizes `|`, `:`, em dash, and bare markers to a single pipe. The four `ISSUE_DONE`/`ISSUE_PROGRESS` parsers in `builder.sh` now call it, restoring the state flip and the three other consumers.
- **`scripts/triage.sh`** — defers any issue with an open PR before review. A deferral, not a skip: the issue is untouched and returns to scope when the PR resolves. Fails open; logged to the triage log and the Slack thread.
- **`adapters/tracker.sh`** — all open-issue queries share `GH_OPEN_LIMIT` (200 → **1000**), plus a stderr warning when a query returns exactly at the cap. Found while verifying the triage guard: with 265 open issues the 200 cap was hiding **8 of 10** triageable and **3 of 5** pickable issues.
- **`scripts/stale-pr-audit.sh`** (new; scheduled weekly Sun 08:15 as of the same day) — asks the question issue identity cannot: does merging this PR still change anything? Flags no-op merges (`git merge-tree` against master), migrations duplicating a column already in master, and two open PRs adding the same column.

**Observed effect on cleanup.** With the full issue set visible, `cleanup.sh --dry-run` now reports 150 done-awaiting-close (was 92) and 42 needing a human call (was 7), and takes ~4 minutes. Behavior is unchanged — 0 auto-recycled, exit 0 — it simply is no longer blind to two thirds of the board.

**Why not a pre-build freshness check against master.** Verified as ineffective for this incident: when PR #1041 was opened, `plate_count_mode` was **not** in master — it lived only in the still-open PR #1032, and master stayed clean for six more days. Checking the codebase at build time would have found nothing. The duplicate was visible only in the *open-PR set*, which is why the audit's cross-PR collision check is the one that fires (retro-validated: it flags `exercises.plate_count_mode added by PRs [1032, 1041]` at #1041's creation).
### 2026-08-28 — Agile-gap pass: outcome metrics, rejection-feedback loop, WIP limit, blockers in the standup, GA burndown, backlog expiry, acceptance criteria

**Context.** A review of Pilot against standard agile practice found two systemic gaps: the pipeline measured *activity* (iterations, tokens, stalls) but not *outcomes* (merged PRs, merge rate, lead time), and the human-feedback loop still advertised in the Data Flow diagram had been dead since the review tuner was removed (2026-05-11) — Aaron's merge/reject decisions were the one signal nothing learned from. Seven changes, all zero-AI-token (bash/python/gh) apart from two prompt additions:

- **Health report — Delivery metrics** (`scripts/health-report.sh`): new report + Slack section computed from `gh pr list`: PRs merged (7d), PRs closed unmerged, merge rate, avg time-to-merge, open-PR count with oldest age, and output tokens per merged PR (the cost-of-delivery number). Two new anomalies: review-queue aging (oldest open PR ≥ 7d) and low merge rate (<50% with ≥4 decided PRs). Every path degrades to zeros when `gh` is unavailable.
- **Health report — GA burndown**: stabilization mode now has a termination condition. The report tracks the GitHub milestone named by `GA_MILESTONE` (default `GA`) as a release burndown — closed/total (%) and open issues remaining — and prints a create-the-milestone hint until it exists.
- **Rejection-learnings loop** (`scripts/cleanup.sh` step 2b + `scripts/builder.sh`): cleanup harvests the closing comments of PRs closed unmerged in the last 14 days into `data/lift-build-learnings.md` (idempotent by `## PR #N ` key; repo-owner comment wins, bot comments ignored, missing comment recorded as a nudge). The builder injects the file's tail into every iteration prompt as "Learnings from PRs Aaron rejected". Cleanup also snapshots the current rejected-PR issue IDs to `data/lift-needs-decision.txt` for the digest.
- **WIP limit** (`scripts/builder.sh` + `wip_gate_active` in `lib/builder-utils.sh`): when `MAX_OPEN_PRS` (default 8, `0` disables) PRs are already open, the builder stops for the night with a Slack notice instead of growing the review queue. `ci:failed` retry iterations are exempt (their old PR is closed at startup).
- **Blockers in the digest** (`scripts/digest.sh`): the 6:15 AM digest gains "⏳ Waiting on you" (`state:needs-input` issues with links) and "⚖️ Needs your call" (rejected-PR issues from the cleanup snapshot) — the standup now surfaces what is blocked on a human.
- **Backlog expiry** (`scripts/cleanup.sh` step 4): open `priority:4-low` issues untouched for `BACKLOG_EXPIRY_DAYS` (default 56, `0` disables) are auto-closed as not planned with a reopen invitation; parked issues (started/blocked/needs-input) never expire. `lift-cleanup-metrics.csv` gains a fifth `expired` column (parsers must tolerate 3/4/5-field rows).
- **Acceptance criteria** (`scripts/triage.sh` + builder prompt): APPROVE/ENHANCE verdicts emit `ACCEPTANCE_CRITERIA` (2–4 testable, user-observable criteria), rendered as a definition-of-done checklist in the triage comment; the builder must verify each criterion before pushing and confirm it in the PR's Verification section.
- **Config:** `MAX_OPEN_PRS`, `BACKLOG_EXPIRY_DAYS`, `GA_MILESTONE` added to `project.env.example` + `init.sh`; `project.env.example` also gains the long-missing `GITHUB_ISSUES_REPO` (drift — init.sh has written it since the GitHub migration).
- **Tests:** +16 across builder/cleanup/digest/triage/health-report (WIP gate, harvest end-to-end with idempotency, expiry filter, digest blockers, flow metrics end-to-end, acceptance parsing). Full suite 267 green (rebased onto the same-day duplicate-build-fix and doc-drift-audit merges).

**New for Aaron:** leave a one-line closing comment whenever you close a PR without merging (it becomes builder training data); create the `GA` milestone in aschung212/Lift and tag GA-blocking issues; expect the builder to pause nights when ≥8 PRs are open.
### 2026-08-27 — Architect moved to Claude Fable 5 via new `AI_ARCHITECT_MODEL` knob

The weekly architect run is the pipeline's deepest-reasoning task (whole-codebase review along one axis) and its lowest-cadence one (Wed 8pm), so it now runs **Claude Fable 5** — Anthropic's most capable model, $10/$50 per MTok vs Opus 5's $5/$25; one run/week keeps the premium negligible next to nightly builder spend. New env var `AI_ARCHITECT_MODEL="claude-fable-5"` (bare ID — Fable's context is 1M by default, no `[1m]` suffix), consumed only by `scripts/architect.sh` via the fallback chain `${AI_ARCHITECT_MODEL:-${AI_CODE_MODEL:-claude-opus-5[1m]}}`, so unsetting it reverts the architect to the shared Opus knob. Effort stays `AI_CODE_EFFORT` (`max`). The model string was validated with a live headless probe (success, `contextWindow: 1000000`). No timeout risk from Fable's longer turns: the architect has no wall-clock cap, only `ARCHITECT_MAX_TURNS` (40), and it's read-only so it can't conflict with the 11pm builder. `init.sh` gained an architect-model prompt (default `claude-fable-5`) and writes the var; `project.env.example`, README, and the Model Allocation table updated. Also added the missing Architect row to the Scheduled Tasks table (doc drift — the service predates this change).

### 2026-08-27 — Opus-tier model bumped to Claude Opus 5

`AI_CODE_MODEL` moved from `claude-opus-4-8[1m]` to `claude-opus-5[1m]` (Claude Opus 5, 1M-context variant); `AI_CODE_EFFORT` stays `max` — Opus 5 supports the same low→max effort ladder. One-line change in the live `project.env` per the 2026-05-28 centralization; the `${AI_CODE_MODEL:-claude-opus-5[1m]}` fallbacks in `adapters/ai-code.sh`, `scripts/builder.sh`, `scripts/discover.sh`, and `scripts/architect.sh`, plus the `init.sh` default and `project.env.example`, were bumped in the same pass so unsourced/test-mode runs use the same model. The string was validated with a live headless probe before the edit (`claude --model "claude-opus-5[1m]" -p …` → success, `contextWindow: 1000000`). `model_display_name()` needed no code change (`claude-opus-5[1m]` → `Claude Opus 5`); a new regression test pins that mapping, so commit trailers now read `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

### 2026-08-21 — GA-readiness shift: pipeline re-aimed from feature discovery to stabilization

**Context.** Lift is feature-complete; the beta build-out phase is over. Continuing to burn overnight runs on feature suggestions (mostly rejected) and test additions (suite already extensive) was waste. The whole pipeline now optimizes for a general-availability release: find bugs, fix bugs, improve performance, refine existing UX.

**Discovery** (`scripts/discover.sh`): new weighted rotation — `bug-hunt` ×5, `performance` ×4, `ux-polish` ×4, `accessibility` ×3, `pwa-reliability` ×2, `security-deps` ×2 (20-slot cycle). Three new focus areas (`bug-hunt`, `ux-polish`, `pwa-reliability`) with codebase-grounded prompts; 11 feature-research areas retired from rotation but kept for manual runs. Prompt now forbids net-new-feature and test-only issues, requires a file citation per finding, re-anchors the priority scale on defects (1=crash/data loss/security … 4=cosmetic), and targets 2–6 discoveries with zero as a valid result. `QUEUE_VERSION` stamp (`lift-discovery-queue.version`) auto-discards queues from older rotations; unknown focus names now fail loud instead of dying on `set -u`. `init.sh` menu/map extended to 17 areas and stamps the version file when seeding.

**Triage** (`scripts/triage.sh`): standing GA policy in the prompt — SKIP net-new features and monetization/growth/marketing ("deferred until post-GA"), SKIP test-only additions, refactors only when they unblock a fix; GA priority scale for SUGGESTED_PRIORITY. New `--re-triage` flag re-reviews the entire triageable backlog under current policy (one-shot re-baseline; "Re-triaged by" comments keep nightly idempotency; parked issues untouched; combinable with `--dry-run`).

**Builder** (`scripts/builder.sh`): pre-pick tie-break re-ordered — bug fixes > perf/reliability > UX/a11y polish > refactors/tests/features. Inline per-iteration discovery list rewritten to defects-and-refinements-only (functional bugs and UX friction added; "missing tests" and "code smells" removed as issue sources).

**Architect** (`lib/architect-utils.sh`): `test-architecture` axis retired, replaced by `error-resilience` (unhandled rejections, silent-failure UX, global error capture, partial-write consistency, retry/recovery). Mandate now carries a GA lens — user-visible bugs/data loss/perf over structural taste; pure refactors reported at P4 or not at all.

**Tests:** discover/architect/triage bats updated + 4 new tests (GA queue shape, version-guard regeneration, re-triage arg parsing/marker, re-triage dry-run). Full suite green (215 tests).

**2026-08-26 addendum (deployment day).** Merged to main (PR #20) and deployed to the live checkout; the re-triage sweep ran (LIFT-808 approved, LIFT-1203 parked "deferred until post-GA") and the queue-version guard swapped the live rotation as designed. The first manual `bug-hunt` run then hit a known failure shape from the builder's history: the model emitted its six ISSUE_DISCOVER findings mid-session and closed with a summary, so the pipeline (which parses only the final message) filed **zero** issues. The findings were verified against the Lift source and filed by hand (LIFT-1211…1215; one finding dropped for citing a nonexistent file), then triaged normally (5× APPROVE). Two hardenings shipped: the discovery prompt now carries the builder-style final-message guard (restate every ISSUE_DISCOVER line in the final message; declare "No discoveries met the bar this run" when empty), and the script alerts Slack when a run parses 0 discoveries, created 0 issues inline, and lacks that sentinel — a silent-zero can no longer masquerade as a legitimate empty run.

### 2026-07-17 — Review re-platformed from Gemini CLI to headless Claude

**Problem.** The `gemini` CLI's OAuth-personal auth started returning `IneligibleTierError` / `UNSUPPORTED_CLIENT` after Google retired the free "Gemini Code Assist for individuals" tier on 2026-06-18. Every review from ~2026-06-30 failed silently (graceful-degradation skip — no alert for ~2.5 weeks). Verified live: Google AI Pro/Ultra provide no API/CLI entitlement; the Gemini API free key works for Flash but returns 429 `limit: 0` for all Pro models; the `codex review` fallback binary was missing (ENOENT).

**Fix.** Rewrote the review engine in `~/.claude/scripts/review-router.sh`: Gemini CLI → `claude -p --model "$PILOT_REVIEW_MODEL"` (default `sonnet`), `--max-turns 1`, `Read,Glob,Grep` allowed, wrapped in a `$PILOT_REVIEW_TIMEOUT` (180s) wall-clock guard (no `gtimeout` on this host). Context building (CLAUDE.md + full changed files + resolved imports + diff), the post-commit hook interface, `PILOT_BUILDER`/`PILOT_REVIEW_LOG` env, and log paths are unchanged. Added fail-loud: on reviewer error/timeout it emits `REVIEW FAILED`, posts a #lift-automation Slack alert in builder mode, and exits 0 (never blocks the push). `scripts/builder.sh` prompt corrected — the review fires on **post-commit**, not pre-push (a long-standing doc drift) — and its model/Slack strings updated. Backup: `review-router.sh.gemini.bak-13c1d68`; verified end-to-end against planted P1/P2 bugs before cutover.

**Companion fix (same day).** Discovery research (`ai-research.sh`) and triage were broken by the same cutoff (triage had a Claude fallback; discovery did not). They were re-platformed onto the Gemini REST API — see the "Discovery research + triage re-platformed" entry below.

### 2026-06-25 — Builder commit co-author trailer pinned to the configured model

**Problem.** Lift PR commits carried inconsistent attribution — `Co-Authored-By: Claude Opus 4.6`, `Co-authored-by: Claude Opus 4.6` (lowercase), and occasionally `Claude Opus 4.8 (1M context)` — even though the builder runs `claude-opus-4-8[1m]`. The 2026-05-28 model pin assumed the trailer would follow `--model`, but the builder prompt never specified one. In headless `claude -p` mode the model **self-reports** the trailer from its training-cutoff self-knowledge (it identifies as "Opus 4.6"), so the `--model` flag had no effect on attribution.

**Fix.** Attribution is now derived from `AI_CODE_MODEL` (single source of truth) and instructed explicitly:
- New tested helper `model_display_name()` in `lib/builder-utils.sh` converts the model ID to a display name (`claude-opus-4-8[1m]` → `Claude Opus 4.8`; strips `[1m]` and trailing date snapshots; degrades to `Claude` for a bare alias).
- `scripts/builder.sh` computes `COAUTHOR_TRAILER` once from `AI_CODE_MODEL` and injects an explicit "use exactly this trailer, do not self-report a version" instruction into all three committing prompts (main build, merge-conflict fix, CI-fix).
- Because it derives from `AI_CODE_MODEL`, the trailer follows future model bumps automatically — no second edit needed.
- 6 regression tests added in `tests/builder.bats` (18 total, all green), including an assertion that the output never contains the stale `4.6`.

**No model allocation change.** The builder still runs `claude-opus-4-8[1m]` at max effort; only the self-reported attribution string is corrected.

### 2026-06-23 — Builder auth preflight

Added a fail-loud auth check before the builder's main loop. The keychain OAuth token (Max subscription) expired 2026-06-19 and, with no interactive session under launchd to refresh it, every iteration's pre-pick stage 401'd — silently, producing zero-PR nights on 2026-06-19 and 2026-06-22. The loop swallowed the 401 as a soft "no ISSUE_PICKED marker" warning and burned `MAX_CONSECUTIVE_FAILURES` iterations.

- **`lib/builder-utils.sh`:** new `is_auth_failure()` classifies a `claude` probe's output as an auth failure (401 / logged out) vs. transient/network error.
- **`scripts/builder.sh`:** auth preflight before the loop — one probe; on auth failure, alert #lift-automation + the build thread and `exit 1`. Escape hatch `SKIP_AUTH_PREFLIGHT=1`.
- **`tests/builder.bats`:** +4 tests for `is_auth_failure`. Full suite 203 green.
- Operational fix is interactive: `claude setup-token` mints a long-lived token, then `~/Documents/Scripts/set-claude-token.sh` validates + persists it as `CLAUDE_CODE_OAUTH_TOKEN` in `~/.zshenv` (sourced by every agent, so it fixes the whole pipeline). Running `setup-token` alone is not enough — it only prints the token. See `docs/pilot-responsibilities.md` → "Builder Auth (re-login)".

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

### 2026-07-15 — Builder `claude`-call timeouts + builder-staleness alert

Hardening after a hung `claude` call took the builder offline for 5 days (2026-07-09 → 07-14). The builder's launchd job uses `StartCalendarInterval`, which **skips a scheduled run whenever the previous instance is still alive** — so one indefinitely-blocked call suppressed every nightly run until the stuck process was killed by hand.

- **Every builder `claude` call is now wall-clock bounded.** New `run_with_timeout` helper in `lib/builder-utils.sh` (portable — this Mac ships no GNU `timeout`/`gtimeout`) runs the call in the background with a poll-based watchdog; on expiry it kills the whole process tree (recursive TERM→KILL via `kill_process_tree`) and returns `124`. Applied to all four call sites: main implement, CI-fix / merge-conflict retries, pre-pick, and auth probe. A timed-out iteration is scored a failure and the loop continues, so the night finishes and launchd is free to launch the next run.
- **New config knobs** (`project.env`, generous defaults so they only fire on a genuine hang): `BUILDER_ITERATION_TIMEOUT` (3600s), `BUILDER_FIX_TIMEOUT` (1800s), `BUILDER_PREPICK_TIMEOUT` (300s), `BUILDER_AUTH_TIMEOUT` (180s). `0` disables a given timeout. This extends the centralized-config pattern (see 2026-05-28 entries).
- **Weekly health report gained a builder-staleness anomaly** (`scripts/health-report.sh`): computes days-since-last-builder-run across all metrics history and flags ≥3 days idle (plus a "Last builder run" line). Defense-in-depth backstop for hang modes outside a `claude` call; the per-call timeout is the primary prevention.
- Tests: `tests/builder.bats` +7 (timeout / tree-kill), `tests/health-report.bats` +2 (staleness). Suite 218 green.
- **No change to Aaron's workflow.**

### 2026-07-17 — Discovery research + triage re-platformed off the retired Gemini CLI

Companion to the 2026-07-16 review re-platform. Google retired the free "Gemini Code Assist for individuals" OAuth tier on 2026-06-18, so every bare `gemini` CLI call (default OAuth auth) now returns `IneligibleTierError` / `UNSUPPORTED_CLIENT`. This silently broke discovery web research (no fallback → empty findings, Claude self-researched blind) and forced triage onto its Claude Sonnet fallback every night — both undetected, same failure class as the review outage.

- **`adapters/ai-research.sh` rewritten to call the Gemini REST API directly** (`generateContent`) with the `GEMINI_API_KEY` from `~/.zshenv` — no `gemini` CLI, no OAuth. Flash is free on the API key (Pro is billed and excluded from the free tier). Research keeps **Google Search grounding** (`tools:[{google_search:{}}]`) so it still returns real URLs/versions instead of hallucinations; `--no-grounding` disables it for pure-reasoning callers. The adapter now **fails loud** — non-zero exit + reason on stderr — instead of swallowing errors with `|| true`. Verified live: grounded Flash returns fresh sourced results; a bad key/model surfaces the API error and exits non-zero.
- **`scripts/discover.sh` Phase 1 routed through the adapter** (was calling `gemini` directly, twice, in violation of the adapter pattern). On failure it posts a **loud Slack alert** to the discovery thread and Claude self-researches — no more silent degradation.
- **`scripts/triage.sh` routed through the adapter** (`--no-grounding`), keeping the Claude Sonnet fallback. Restores free Flash triage (was quietly burning Claude tokens on the fallback every night). Alerts **once per run** if the Gemini path is down.
- **Interactive `gemini` CLI is untouched** — the pipeline no longer depends on the CLI binary at all, so this cannot disturb Aaron's manual `gemini` usage.
- **Model Allocation + Data Flow updated.** Also corrected the stale "Gemini 3.1 Pro" review references these two structures still carried from before the 2026-07-16 migration (review is Claude Sonnet now). Deeper review-prose (hook timing, the 2026-04-06 entries) still predates the migration and needs a separate cleanup pass.
- **Tests:** `ai-research.bats` rewritten for the REST/curl contract + fail-loud cases; `curl` mock extended for `-o`/`generateContent`; `triage.bats` dry-run fed via the mocked API; `GEMINI_API_KEY` added to `test_helper.bash` for hermeticity. Full suite green: **223/223**.
