---
type: system-reference
tags:
  - pilot
  - automation
  - responsibilities
updated: 2026-05-08
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
| **Check per-PR review status** | Each PR has inline review results in description (Gemini 3.1 Pro pre-push review). PRs now include a Verification section (steps to test, expected behavior, risk assessment) and a Vercel preview URL for quick testing. | PR description shows review findings + verification checklist + preview link |
| **Test on preview deploys** | Click the Vercel preview URL in the PR description. Preview mode is enabled by default — Supabase writes are blocked (safe to use real Google account). Toggle "Enable writes" in the blue banner if you need full write-path testing. Test account available: test@lift.local / LiftTest2026! | Vercel preview URL in PR body |
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
| **Review metrics** | `pilot/data/lift-metrics.csv` and `lift-discovery-metrics.csv` |
| **Review token usage + runtime** | `pilot/data/lift-usage-tracking.csv` and `lift-runtime.csv` — budgets auto-tune but review if unexpected |
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
  - Builder (Mon-Fri 11 PM): implements per-issue branches (`enhance/LIFT-{id}-{date}`), per-issue PRs with Gemini 3.1 Pro adversarial review (pre-push hook, single model) + auto-fix cycle, CI check. Uses git worktree for isolation. Failed PRs (`ci:failed`) auto-retried next night.
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
| `pilot/data/` | Logs, metrics, digests, cost tracking |
| `Obsidian: 20_Learning/Vibe Coding Projects/Lift - Product Decisions.md` | Product direction — rejected concepts, approved direction. Discovery agent reads this. |

## Slack Channels

| Channel | What posts there |
|---|---|
| #lift-automation | Overnight build iterations, discovery digests, GitHub activity (pending setup) |
| #daily-review | AI review summary, LeetCode updates, Linear digest |
| #pilot | Pilot changelog — what changed, new responsibilities |

## Environment Variables (`~/.zshenv`)

| Var | Purpose |
|---|---|
| `SLACK_WEBHOOK_URL` | Webhook for #lift-automation |
| `SLACK_WEBHOOK_DAILY_REVIEW` | Webhook for #daily-review |
| `SLACK_WEBHOOK_CHANGELOG` | Webhook for #pilot |

---

## Changelog

### 2026-05-13 — Builder early-exit prompt strengthened (audit P2)

**Symptom.** [Pilot audit 2026-05-13](../data/pilot-audit-2026-05-13.md) flagged that 25/60 builder runs (41.7%) in the 2026-05-06..2026-05-13 window exited without ISSUE_DONE/ISSUE_PROGRESS markers. Pattern: `num_turns=1`, opus output ≥500 tokens (parent did the real work), but final assistant message was a chatty one-liner ending in "background task completed" or "PR is live at …" — no structured response, so the pipeline drops the issue and re-attempts it the next night.

**Cause.** The prompt already forbade backgrounding git operations and required the structured response, but both rules sat in the `## Rules` block AFTER `### Step 2: Push for review`. The model read the push instruction and acted on it before reaching the prohibition.

**Action.** Updated `scripts/builder.sh`:
- Inlined the no-background rule into Step 2 itself (rename: "Step 2: Push for review (FOREGROUND ONLY)"), with explicit "wait 2-5 minutes synchronously for the Gemini pre-push hook" rationale and 2026-05-13 audit reference.
- Added a literal pre-exit self-check to Step 4 enumerating the seven required strings (`## Plan`, `## Changes`, `## Issue updates`, `ISSUE_DONE:` or `ISSUE_PROGRESS:` line, `## Verification`, `## Screenshots`, `## Summary`) and a sentence explicitly stating that a background-task completion notification is not permission to exit early.
- Slimmed the Rules-block duplicate to point at Step 2 instead of repeating the rationale.

**Action needed for Aaron:** None. Watch next week's audit for `early_exit_pct` — if it stays above 25%, the model is treating the prompt as advisory and we'll need a structural fix (e.g. wrap the parent in a follow-up turn that the pipeline injects to force the structured response).

### 2026-05-13 — Time-to-merge audit finding (P2): no code change

**Symptom.** Same audit flagged median time-to-merge of 25.9h (vs prior window 31.0h). Slowest 3 merged PRs were #418 (283.3h), #423 (281.0h), #424 (280.9h).

**Action.** Spot-checked all 3 — every one merged with **0 failed CI checks**. This is not a CI-retry-loop issue; it's an Aaron-attention bottleneck on old PRs (PRs created ~12 days before merge, sitting in review queue). Median actually improved 31.0h → 25.9h, so trend is healthy. No code change; auditor will continue flagging per its standing remediation.

**Action needed for Aaron:** None right now, but if median climbs back above 30h, that's a signal to triage your review queue more aggressively in the morning.

### 2026-05-12 — Builder PR titles no longer truncated mid-word

**Symptom.** PR titles created by the builder were getting cut off mid-word. Example: [PR #554](https://github.com/aschung212/Lift/pull/554) shipped with title `fix(#549): export classifyWarmupSets convenience wrapper and fix thres` — chopped at "thres" instead of "threshold comparison".

**Cause.** `scripts/builder.sh:845` hard-truncated `PR_TITLE` with `head -c 70` before passing it to `gh pr create`. The 70-byte cap was arbitrary (GitHub allows 256 chars) and ignored word boundaries.

**Action.** Removed the `head -c 70` truncation. The PR title now uses the first commit subject as-is, which is already conventionally short and bounded by commit-message hygiene rather than an arbitrary script cap.

**Action needed for Aaron:** None.

### 2026-05-11 — Review tuner decommissioned

**Symptom.** Aaron observed the Sun 21:15 review tuner posting `🎛️ Review Tuner — no new merged PRs to analyze ✅` to #lift-automation, while Lift had merged 10+ PRs in the prior week (#517, #523, #524, #525, #526, #527, #528, #529, #530, …). His hypothesis was that the script confused merged with closed-without-merge PRs.

**Actual cause.** `scripts/tune-reviews.sh` correctly fetched `--state merged` PRs, but filtered out every PR that lacked a `Layer 1: Claude` or `Layer 2: Gemini` issue-comment marker. Those markers stopped being posted on 2026-04-06 when the review pipeline moved to inline pre-push hooks (Gemini 3.1 Pro). All recent merged PRs (#517, #528, #530, ...) have zero issue comments — every PR fell through the filter, and the misleading "no new merged PRs" Slack message fired every Sunday. The script header had a deprecation note: "Safe to delete after 2026-05-06."

**Action.** Fully decommissioned the review tuner:
- Unloaded and removed `~/Library/LaunchAgents/com.aaron.pilot-tune-reviews.plist`.
- Deleted `scripts/tune-reviews.sh`, `launchd/com.aaron.pilot-tune-reviews.plist`, `tests/tune-reviews.bats`, and the `~/Documents/Scripts/lift-tune-reviews.sh` symlink.
- Removed plist generation from `init.sh` (`PLIST_REVIEWS` block + load loop).
- Removed the `review-tuner` identity from `adapters/notify.sh` and `tests/adapter-contracts.bats`.
- Cleaned references in `README.md`, `docs/architecture.md`, `docs/pilot-architecture.md`, `docs/tuning.md`, and the builder.sh footer comment.
- Retained the frozen `data/lift-review-learnings.md` and `data/lift-review-history.json` data files — `adapters/ai-review.sh` still reads the learnings file. (That adapter is itself deprecated but out of scope for this cleanup.)

**Action needed for Aaron:** None. The Sunday 21:15 slot is now empty. No replacement is planned — the inline review system posts to per-iteration Slack threads, not GitHub comments, so any future tuner would have to learn from your manual PR review comments rather than bot comments. Flag if you want that built; otherwise the slot stays empty.

### 2026-05-12 — Triage FLAGs park issues on `state:needs-input` (now respected by builder)

**Problem.** The 2026-05-10 triage run flagged issue [#550](https://github.com/aschung212/Lift/issues/550) as 🚩 NEEDS INPUT — a color-only delta indicator has multiple reasonable a11y fixes (icon+color, monochrome treatment, ARIA-only) and the right call needs Aaron's product judgment. The 2026-05-11 overnight builder picked the same issue and shipped [PR #556](https://github.com/aschung212/Lift/pull/556) anyway. Two bugs combined:

1. **FLAG didn't change state.** Triage's FLAG branch only added a comment. The issue stayed on `state:unstarted`, and `list pickable` (exclusion of `{triage, backlog, started, blocked, canceled}`) had no signal for "human decision required." Eight currently-open issues had the same pattern (#306, #308, #309, #533, #546, #547, #550, #551) — every FLAG since the GitHub migration was a no-op against the picking pool.
2. **The NEEDS INPUT comment was blank.** Triage's FLAG prompt asked for a 1-2 sentence reason; the Sonnet fallback returned no `REASON:` line at all on #550, so the parser produced an empty comment body. Even when populated, a single sentence is not enough for Aaron to decide in 30 seconds.

**Fix.** Two changes, both small:

- `adapters/tracker.sh`: `pickable` and `triageable` jq predicates now also exclude `state:needs-input`. Builder skips it; triage doesn't re-process it (so the existing options analysis isn't overwritten each cycle).
- `scripts/triage.sh`: FLAG branch now calls `tracker.sh update --state needs-input` after commenting. The triage prompt was rewritten to require, on FLAG, a `FLAG_QUESTION` line, 2–4 `OPTION_N` blocks (each with `TITLE`, `PROS`, `CONS`), and a `RECOMMENDATION`. Pros/cons are pipe-separated in the model output and rendered as bulleted lists in the comment. Guidance also clarifies that FLAG is for *product* decisions — implementation fuzziness goes to ENHANCE with a documented assumption. Fallback path logs a warning if the model omits structured fields and surfaces the raw REASON so the comment is never blank.
- `state:needs-input` label created in `aschung212/Lift` (color F9D0C4, "Triage flagged — waiting on human decision") — required because `gh issue edit --add-label` does not auto-create labels.

**Locked in via tests.** Both `tests/tracker.bats` and `tests/triage.bats` got new assertions: `pickable`/`triageable` must exclude `state:needs-input`, and FLAG output parsing must extract `FLAG_QUESTION`, `RECOMMENDATION`, and N options correctly.

**New responsibility for Aaron.** Issues parked on `state:needs-input` are waiting on you. The workflow:
1. Open the issue, read **Question / Options / Recommendation** in the latest "Triaged by …" comment.
2. Decide. Either accept the recommendation (just react with 👍 in the comment for your own audit trail) or pick a different option / add a constraint.
3. Edit the issue body or add a comment with the chosen direction so the builder has context.
4. Flip the label: remove `state:needs-input`, add `state:unstarted` (or use the GitHub UI's labels picker). The next builder iteration picks it up.

If you ignore a `state:needs-input` issue, it just sits there indefinitely — that's the point. No silent re-picking.

**Backfill action (completed 2026-05-12).** The 8 already-FLAGged issues (#306 #308 #309 #533 #546 #547 #550 #551) plus 2 untriaged extras (#531 #532) were re-triaged under the new prompt. Outcome:

- **5 cleared back into the picking pool** — under the new prompt with `--max-turns 6`, Sonnet found sensible defaults instead of FLAGing: #533 #547 #550 #551 (APPROVE), #531 (APPROVE), #532 #546 (ENHANCE). Original FLAGs were premature punts.
- **1 skipped** — #306 (custom app icon, blocked by Capacitor wrapper).
- **2 genuine NEEDS INPUT** — #308 (premium theme packs) and #309 (Stripe Checkout). Both got rich `FLAG_QUESTION` / `OPTION_N` / `RECOMMENDATION` comments and are parked on `state:needs-input` until Aaron decides.

**Two follow-up fixes landed in the same backfill session:**

1. **Prompt strengthening.** Added an explicit FLAG output example to the triage prompt and rewrote the FLAG gating: "If you cannot fill in OPTION_1 and OPTION_2 with concrete content, change the verdict to ENHANCE instead of FLAG." Sonnet was emitting bare `VERDICT: FLAG` lines without the structured fields on first attempt; the new wording + example trains the format.
2. **Sonnet `--max-turns` bumped 3 → 6.** Root cause of the empty FLAG outputs on the first re-triage pass: Sonnet was hitting `Error: Reached max turns (3)` after Read/Glob/Grep tool calls and getting cut off before emitting `OPTION_N` / `RECOMMENDATION`. With max-turns 6, Sonnet has headroom to investigate the code AND produce the structured output. Side effect: turned 4 of the 5 "FLAG" verdicts in the 2026-05-12 backfill into APPROVE/ENHANCE — the model picked sensible defaults once it had time to look at the codebase.

**Lesson for future tuning.** Triage's quality is bounded by Sonnet's turn budget when Gemini Flash falls back. If we see a wave of FLAG verdicts with empty options, check the Sonnet logs for `Error: Reached max turns` before assuming the prompt is wrong.

### 2026-05-11 — Triage no longer caps at 10 issues per run

**Change.** `scripts/triage.sh` previously processed at most 10 untriaged issues per run (`MAX_PER_RUN=10`), deferring the rest to the next Sun/Tue/Thu cycle. Removed the cap — triage now processes every untriaged issue returned by `list triageable` in a single run.

**Why.** The cap was a leftover hedge from when triage was slower and ran in the overnight chain ahead of the builder. With Gemini Flash as the primary model and Claude Sonnet as fallback, per-issue latency is low enough that processing the full backlog (typically 10–20 issues) fits comfortably inside the triage window. Capping meant orphan issues surfaced by `list triageable` (e.g. unlabeled manual issues from the 2026-05-08 fix) waited two extra cycles to be reviewed.

**Action needed for Aaron:** None. The next triage run drains whatever backlog has accumulated. If a single run ever does become noticeably slow, the right knob is per-issue concurrency or model selection, not a count cap.

### 2026-05-08 — Builder no longer closes issues at implementation time

**Problem.** [PR #467](https://github.com/aschung212/Lift/pull/467) (LIFT-436, BroadcastChannel for cross-tab sync) was opened 2026-04-30 with a typecheck failure. CI never went green, the PR sat unreviewed, and the merge state went DIRTY against `main`. But on 2026-05-06 issue [#436](https://github.com/aschung212/Lift/issues/436) closed itself — orphaned: PR open, issue closed, no merge, no human action.

**Root cause.** `scripts/builder.sh:797` ran `tracker.sh update <id> --state "Done"` whenever Claude emitted `ISSUE_DONE:LIFT-N`. That call routes through `gh_update` in `adapters/tracker.sh:203`, which calls `gh issue close --reason completed`. The pipeline was treating "Claude finished implementation" as "issue is done" — but the PR still has to pass CI and merge before the work is real.

**Fix.** `ISSUE_DONE` markers now flip state to `In Progress` (with a "PR opened, will close on merge" comment), not `Done`. Closure is GitHub-driven via `Closes #N` in the commit body. Builder prompt now explicitly requires Claude to include `Closes #N` in at least one commit message so the GitHub merge mechanism is the single source of truth for closure.

**Action needed for Aaron:** None for new runs — the next overnight pipeline picks up the new behavior automatically. For the orphaned issue: I reopened LIFT-436 manually and rebased PR #467 onto `master` (the typecheck error in `crossTabSync.ts` was a non-distributive conditional type — the function parameter resolved to `never` because TS only distributes naked type *parameters*, not type *aliases*; replaced with an explicit `SyncStatus` alias). Issue will auto-close when PR #467 merges.

**Watch for stalls.** Issues that get committed against but whose PRs never merge will now stay in `state:started` indefinitely. The pipeline auditor's existing PR-stall detection still surfaces these — no new responsibility, but the symptom shifts from "closed orphan issue" to "stale In-Progress issue."

### 2026-05-06 — Auditor unblocked + builder early-exit fix

Three changes triggered by today's auditor P1 findings ([pilot#4](https://github.com/aschung212/pilot/issues/4), [pilot#5](https://github.com/aschung212/pilot/issues/5)):

1. **Auditor was silently dropping P1 findings.** `gh issue create` rejected calls because `audit` and `severity:p1/p2/p3` labels didn't exist in `aschung212/pilot`. Created the labels and added `ensure_audit_labels` (`lib/auditor-utils.sh`) that runs at audit start. Now the labels are guaranteed before any issue is filed.

2. **Builder prompt fix for the real root cause.** The auditor's "subagent delegation" narrative was outdated — that bug was fixed weeks ago. The current pattern is **early-exit-after-background-push**: parent agent does all the work itself (opus_outputTokens 5k–44k), pushes via a background bash task, then exits with a chatty one-liner like "background task completed, pipeline will handle PR creation" — never emitting the structured `## Issue updates` block, so `ISSUE_DONE` markers are missing in 80% of recent runs. Two prompt edits to `scripts/builder.sh`:
   - **Step 4 rewrite:** "After your final push, you are done" → "Output structured response, THEN exit" with explicit warning about the chatty-one-liner failure mode.
   - **New rule (foreground git):** `CRITICAL — DO NOT BACKGROUND GIT OPERATIONS`. Backgrounding the push is what triggers the early exit; foregrounding kills the upstream cause.

3. **Auditor detector split.** The original `num_turns_one_spike` detector lumped two distinct failure modes (delegation vs early-exit) into one finding. Split into `subagent_delegation_pct` (haiku/sonnet visible in modelUsage) and `early_exit_pct` (opus-only with high opus_outputTokens). Both new metrics added to `classify_severity` in `lib/auditor-utils.sh`. Marker-emission summary updated to point at the right companion finding for remediation.

**Action needed:** None for the prompt fix — overnight builders pick up the new prompt automatically on next run. For the auditor detector split, the next scheduled audit (Wed 18:00) will exercise it against live data.

**P2 time-to-merge regression (40.5h → 114h):** Confirmed Aaron-attention bottleneck, not a CI loop (zero `ci:failed` PRs). Slowest 5 PRs (#420, #423, #424, #428, #429) are sitting 11-12 days waiting for review. No code fix; auditor will keep flagging it.

### 2026-04-24 — Health report fixes (data was lying for ~3 weeks)
Two compounding bugs caused the weekly health report to silently understate pipeline activity since the orchestrator decommission on 2026-04-02:

1. **`grep -c || echo "0"` produced multiline output.** When `grep -c PATTERN file` finds no matches it prints `0\n` AND exits 1, so the `|| echo "0"` then appended a SECOND `0\n`. That double-zero broke the per-iteration row in `lift-metrics.csv` across 2-3 lines. Python's CSV reader saw the orphan halves as separate rows with `success=None`, so `successful = 0`. Bug existed in 6 call sites (builder.sh ×4, health-report.sh ×1, digest.sh ×2). Fixed by piping through `head -1`.
2. **`nights_run` and `avg_pipeline_min` read from a dead CSV.** Both were sourced from `lift-runtime.csv`, which only `orchestrator.sh` writes to. Orchestrator was decommissioned 2026-04-02 — the CSV has been frozen at one row from 2026-04-01 ever since. Re-derived `nights_run` from distinct dates in `lift-metrics.csv`; renamed and re-derived `avg_builder_min` as `sum(duration_sec) / nights`. (Discovery+triage runtime not included — they were a small fraction of total time anyway.)
3. **`BACKLOG_COUNT` in health-report.sh greppped for `MAS-` (Linear) instead of `LIFT-`.** Stale reference left over from the GitHub-tracker migration. Fixed to use `${ISSUE_PREFIX}`.

Repaired `lift-metrics.csv` in place (one-shot script reconstructed 46 split rows). Backup at `data/lift-metrics.csv.bak-1777095849`. Past 14 days now show 18 iterations (12 successful, 6 stalls) and 13 commits — vs the report's previous claim of 0 successful and 0 commits. Added 4 new bats tests for `health-report.sh`.

**Action needed:** None. Sunday's report should show real numbers. If you see "Nights run: 0" again, escalate.

### 2026-04-24 — PR screenshot capture
- **New:** Builder now captures local screenshots of routes affected by each PR for pre-merge review.
- Builder Claude declares affected routes via `SCREENSHOT_ROUTE:/path` markers in its output (or `SCREENSHOT_ROUTE:NONE` for backend-only changes).
- After PR creation, `scripts/capture-pr-screenshots.sh` boots a temporary `npm run dev` server in the worktree on a free port, signs in via `.authDevBtn`, and uses Playwright (already installed in Lift) to capture each route at iPhone 14 Pro viewport.
- Output saved to `~/development/pilot/data/pr-screenshots/pr-{NUM}-{ISSUE}-{slug}/` with numbered PNGs and an `INDEX.md`. Folder path is included in the per-iteration Slack thread message.
- New files: `scripts/capture-pr-screenshots.sh`, `scripts/capture-pr-screenshots.mjs`. `scripts/builder.sh` modified for prompt + integration.
- Best-effort: failures (no Playwright, dev server crash, route timeout) are logged but never block PR creation.
- **Action needed:** Before merging a PR, browse the screenshot folder in Finder Quick Look (`open ~/development/pilot/data/pr-screenshots/`) — it shows what changed visually without needing to load the Vercel preview on your phone.

### 2026-04-22 — Builder permission block fix (0-PR outage)
- **Fixed:** Builder had been stopping after 2 iterations with 0 commits since the 2026-04-08 security hardening. Root cause: `$BUILDER_ALLOWED_TOOLS` was passed unquoted to `claude --allowedTools`, so the shell word-split on the space inside patterns like `Bash(git add:*)`. Claude only received `Read,Edit,Write,Glob,Grep,Bash(git` as its allowlist — every git-write, npm test, and npm build was then blocked. Run logs literally said *"all git write operations and npm scripts are being blocked by the permission system."*
- Quoted `"$BUILDER_ALLOWED_TOOLS"` / `"$DISCOVER_ALLOWED_TOOLS"` / `"$TRIAGE_ALLOWED_TOOLS"` in `scripts/builder.sh` (3 call sites), `scripts/discover.sh`, `scripts/triage.sh`.
- **Cleanup:** `~/development/lift-builder` worktree was carrying uncommitted LIFT-325 leftovers (App.vue, index.css, cssRegression.test.ts) and was 14 commits behind master. Reset and fast-forwarded so tonight's run starts clean.
- **Action needed:** None. Builder should produce PRs again tonight (Wed 2026-04-22 23:00).

### 2026-03-31
- Replaced all Slack notifications with webhooks (zero tokens)
- Added discovery digest to #lift-automation
- Created `linear-digest.sh` for board snapshots to #daily-review
- Added LeetCode Slack updates to `/ai-review`
- Moved `/ai-review` source of truth to `~/.claude/commands/ai-review.md`
- Created this responsibilities document
- Created global `~/.claude/CLAUDE.md`
- Discovery agent now reads canceled issues with full details and a product decisions file to understand approved vs rejected product direction
- New file: `pilot/data/lift-product-decisions.md` — Aaron should update this when rejecting categories of features
- New responsibility: when canceling Linear issues, add a comment explaining why (discovery agent reads this)
- Added #pilot Slack channel — all workflow changes are now posted there automatically
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
- Usage tracking CSV: `pilot/data/lift-usage-tracking.csv`
- Auto-stops overnight builder when iteration or token cap reached
- Slack alerts at 80% of token cap and when caps are hit
- Morning digest includes token usage summary and per-night averages
- Auto-tuner (`lift-tune-budget.sh`) runs after each overnight session — analyzes usage history and adjusts budget.conf
  - Raises iteration cap if consistently productive, lowers if stalling
  - Adjusts token cap to 2x average nightly usage
  - Tunes cooldown based on failure rate
  - Needs 3+ nights of data before it starts tuning
  - Tuning log: `pilot/data/lift-tune-log.csv`
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
  - History: `pilot/data/lift-review-history.json`
  - Learnings: `pilot/data/lift-review-learnings.md`
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

### 2026-04-28 — Builder Crash Fix: Multi-Line Numeric Capture
- The 2026-04-27 overnight builder ran 6 minutes / 0 PRs instead of the usual 8 hours. Root cause: `TESTS_BEFORE`/`TESTS_AFTER` in `scripts/builder.sh` used `pipeline | … || echo "0"`. With `set -o pipefail`, when `npm test` exited non-zero (broken `node_modules` from a missing `html-to-image` install), the pipeline emitted `1335` *and* the `||` fallback then appended `0` — producing a multi-line value that crashed the next `$((TESTS_AFTER - TESTS_BEFORE))` with `syntax error in expression (error token is "0")`. The iteration body bailed before `gh pr create`.
- Wrapped four sites (`TESTS_BEFORE`, `TESTS_AFTER`, `BUILD_SIZE`, `FINAL_TESTS`) in `{ … ; } | head -1` — same pattern already used for `DONE_COUNT`/`SKIPPED_COUNT`/`CREATED_COUNT` in commit 88796c0. Bug reproduced and fix verified in isolation; all 119 bats tests still pass.
- The orphaned commit from that night (branch `enhance/LIFT-439-2026-04-27`, commit `8545fdd`) was already CI-green and is being opened as a manual PR.
- **No change to Aaron's responsibilities** — overnight builder behavior is unchanged when the build is healthy.

### 2026-04-30 — Coach's Questions Surfaced in Next Day's Daily Note
- Section 9c ("What Would Help Me Coach You Better") questions are now mirrored into the next day's daily note so Aaron can actually answer them. Previously, 9c lived only in the AI Review file, which Aaron rarely reopened — questions were effectively unanswerable.
- Added `### 💬 Coach's Questions` placeholder to `60_Reference/Templates/Daily Note Template.md` (in the Morning section, right after `### 📚 Study & Job Search`).
- Updated `~/.claude/commands/ai-review.md`:
  - Added new "Vault Update: Coach's Questions (next day's daily note)" step that mirrors 9c bullets verbatim into the daily note.
  - Updated Path A step 6 and Path B step 5 vault-update lists to include the new prefill/refresh.
- Idempotency: placeholder gets replaced on first populate; on Path B re-runs, refresh in-place if Aaron hasn't yet added response bullets. If Aaron has answered, do not overwrite — append new questions with an `<!-- updated YYYY-MM-DD -->` comment instead.
- If 9c is omitted from the review (no questions to ask that day), the placeholder line is left untouched. Older daily notes that pre-date this feature do not get the heading retroactively.
- **New responsibility (light):** Answer Coach's Questions inline in the daily note (nested bullet under each), in the Log, or in the Evening recap. Answers are picked up by the next AI Review's coaching analysis.


### 2026-04-30 — Vault Frontmatter Compliance Templates
- Patched periodic-note templates (Weekly, Monthly, Quarterly, Yearly), AI-Review-Template, and Rest Day Note Template to include `created`, `source`, and `tags` frontmatter. Daily Note Template was already compliant.
- Updated `~/.claude/commands/ai-review.md` Output Structure spec to require `source: ai-generated` and `tags: [ai-review, daily]` on every AI Review file.
- Source: 2026-04-30 vault audit found only 30% frontmatter compliance; templates were the systemic root cause.
- Compounding effect: every new periodic note + AI Review from today forward ships compliant.
- Existing files untouched (handled by separate backfill agent).

### 2026-05-08 — Builder Picking-Time Dedupe + `gh pr create` Lockdown
- 2026-05-07 overnight produced PRs #515 and #517 for the same issue (#501); two of three "real" runs that night still emitted duplicates after the post-PR guard landed on 2026-05-06. Root cause: Claude was running `gh pr create` itself inside the iteration, opening the dup PR before the script-side guard could fire — and there was no signal at issue-pick time to steer Claude away from issues that already had open PRs.
- `scripts/builder.sh` now queries `gh pr list --state open` at the start of every iteration, extracts every `#NNN` / `LIFT-NNN` reference from PR titles, and injects the deduped set into the prompt under a new `## Issues with EXISTING OPEN PRs — DO NOT PICK` section (above the existing "ATTEMPTED tonight" list). Same set is also merged into `NIGHTLY_ATTEMPTED_ISSUES` so run 1 of the night isn't blind.
- `Bash(gh pr create:*)` added to `BUILDER_DISALLOWED_TOOLS`. Claude can still push branches and open issues; only PR creation is reserved to the script. The script's existing post-work dedupe guard at line ~700 stays in place as a second line of defense.
- Post-work guard hardened: now falls back to `PRIMARY_ISSUE` and then to a full-branch commit-message scan when `FIRST_COMMIT_MSG` lacks a ref. Also logs the issue number it checked and what it found, so silent regressions show up in audit reports.
- **No change to Aaron's responsibilities** — this is a behavior fix to the overnight pipeline. The new layer should make `♻️ skipped duplicate PR` Slack messages more common and mornings cleaner. The duplicate PRs from 2026-04-29 and 2026-05-07 nights still need manual close (`gh pr close 447 448 450 451 515 …`); not in scope for this change.

### 2026-05-08 — Builder Marks Issues "In Progress" When Work Starts
- Follow-up fix to dedupe: previous-night iterations could still pick issues that earlier runs had committed against, because the tracker only flipped state when Claude emitted `ISSUE_DONE` / `ISSUE_PROGRESS` markers — and the stall pattern (terse exit after pre-push review) skipped emitting those entirely. Result: the `state:started` label was rare in practice, and `tracker.sh list unstarted started` continued to surface the same issue across iterations.
- `scripts/builder.sh` now drives the state change from commits, not markers. As soon as commits with an issue ref (`#NNN` or `LIFT-NNN`) land on the iteration branch, the script calls `tracker.sh update <id> --state "In Progress"` for each ref. The label flip survives even when Claude exits terse.
- Picking-side query split: `BACKLOG_ISSUES` now uses `tracker.sh list unstarted` (was `list unstarted started`). In-progress issues move to a separate `IN_PROGRESS_ISSUES` block surfaced in a new `## Issues already IN PROGRESS — DO NOT PICK` prompt section, where Claude sees them but knows not to pick. Stalled "In Progress" issues that need a retry can be flagged via `ISSUE_SKIPPED:<id>:looks stalled, needs human review`.
- Existing `ISSUE_DONE:` handler at line ~620 still closes issues that finished — short-circuited via a guard so the new "set In Progress" loop does not race with the imminent close. Net behavior: started → done is a single transition; never-finished issues sit in `state:started` until manually triaged.
- **New responsibility (light, eventual):** if a `state:started` issue lingers in the tracker for several days with no PR / no commits, treat it as stalled and either revert to `state:unstarted` (for retry) or move to `state:blocked` with a reason. This will be uncommon — most issues now reach Done via the closed-PR path — but stalled work no longer auto-recycles into the picking pool.

### 2026-05-08 — Pre-Pick Stage: Flip State BEFORE Implementation Starts
- Gap in the commit-driven flip: it only fires AFTER Claude finishes its session. If iteration N stalls without ever producing a commit (the 2026-05-07 stall pattern — Claude exits terse after the pre-push review hook fires), no commits exist, so the state never flips. Iteration N+1 inside the same nightly run sees the issue as still unstarted and re-picks it.
- `scripts/builder.sh` now uses a two-stage Claude invocation per iteration:
  - **Stage 1 (pre-pick, ~30s, ~$0.05)**: read-only Claude call (`--allowedTools "Read,Glob,Grep" --max-turns 2`) that returns a single line: `ISSUE_PICKED:LIFT-<n>` or `NO_IMPROVEMENTS_REMAINING`. Stage 1 sees the same do-not-pick lists as the main prompt (in-progress, open-PR, attempted-tonight, skipped) but no full issue bodies — just titles and priorities. The script parses the line and calls `tracker.sh update --state "In Progress"` immediately, BEFORE the main implementation call begins.
  - **Stage 2 (main, unchanged cost)**: identical to today's main builder call, except the prompt now includes an `## ASSIGNED ISSUE FOR THIS ITERATION` block telling Claude exactly which issue to work on. Step 2 of "Your job" becomes "Implement \`LIFT-<n>\`" instead of "Pick exactly ONE issue".
- If stage 2 decides the assigned issue is genuinely unworkable, Claude is instructed to output `ISSUE_SKIPPED:<id>:<reason>` AND release the label via `gh issue edit <n> --remove-label state:started --add-label state:unstarted`. The next iteration starts fresh.
- Stage-1 failure modes (network, garbled response, Claude refuses): script logs a warning and falls through to stage 2 with the original "pick from backlog" instruction. The commit-driven fallback from earlier today still catches commits that land. Belt-and-suspenders.
- Net cost: ~$0.60–2.40 extra per night (12 iterations × ~$0.05–0.20 each). Trade-off accepted: deterministic state-flip-on-pick beats a Claude-side instruction that gets ignored ~half the time.
- **No new responsibilities for Aaron** beyond the existing one from the earlier 2026-05-08 entry (manually triage stalled `state:started` issues if they linger).

### 2026-05-08 — Builder Allowlist: Permit `npm install`
- Last night's builder ran 12 iterations; runs 5, 8, 10, 12 all hit `--max-turns 100` with `result: null` and burned ~$13.78 in tokens for zero output. Root cause: the picker chose dependency-update issues that needed `npm install` to refresh `package-lock.json` after editing `package.json` overrides, but `npm install` was not in `BUILDER_ALLOWED_TOOLS`. Claude spent 80+ turns trying every workaround (`npm i`, `bash -c`, `zsh -c`, `node -e execSync`, custom shell scripts, `--ignore-scripts`, `dangerouslyDisableSandbox: true`) — every variant denied — until the SDK truncated.
- Added `Bash(npm install:*)` to `BUILDER_ALLOWED_TOOLS` in `scripts/builder.sh`. The supply-chain framing for blocking `npm install` was thin: the builder already runs `npm test`, `npm run build`, `npm run dev`, and `npx vitest`, all of which execute arbitrary code from `node_modules`. A poisoned dep gets code execution through those paths regardless; blocking `npm install` only delayed the install, not the risk surface.
- Web access (`WebFetch`, `WebSearch`) and arbitrary shell remain blocked. Network egress still flows through git/gh only, plus npm registry traffic during installs.
- **No change to Aaron's responsibilities** — dependency-update issues should now succeed instead of stalling, recovering ~$13/night and unblocking the security/upgrade backlog.

### 2026-05-08 — `list pickable`: exclusion-based picking pool
- Earlier today's two-stage pre-pick fix locked stage 1 to `tracker.sh list unstarted`, which is an inclusion query (`--label state:unstarted`). That accidentally cut off the side channel that was rescuing architect-created issues — those lack the `state:unstarted` label due to a separate labeling bug, and Claude's main builder call was finding them via its own `gh issue list` calls. Locking stage 1 to read-only tools made the picking deterministic but also blind to orphans. The pickable pool effectively shrank from ~9 to 4.
- New pseudo-state in `adapters/tracker.sh`: `list pickable` returns every open issue NOT in `{triage, backlog, started, blocked, canceled}`. Issues with no `state:*` label at all are pickable by default. One agent forgetting to label can no longer silently drop issues.
- `scripts/builder.sh` stage 1 calls `tracker.sh list pickable` (was `list unstarted`). The end-of-night backpressure signal (line 1039) that asks "should discovery run extra tonight?" still uses `list unstarted` — it specifically measures the discovery → triage pipeline output, not the broader picking pool.
- Locked-in via test: `tests/tracker.bats` now asserts `list pickable` hits `--state open` and does NOT regress to `--label state:unstarted`.
- **No change to Aaron's responsibilities.** Tonight's run should see ~9 pickable issues instead of 4, including the architect orphans #502 and #504.

### 2026-05-08 — Architect labeling bug: cleanup, root cause, and prevention
- Root cause investigation: the "architect labeling bug" was never in `architect.sh` or `tracker.sh`. Both correctly produce `state:unstarted` for new issues — proven by discover-created issues #306, #308, #309, which all have the label. The actual cause was a one-shot Python rescue script (`/tmp/backfill-architect-2026-05-06.py`) that ran 2026-05-06 to file the architect's findings after the architect-side parser had emitted "Findings: 0". The backfill bypassed `tracker.sh` and called `gh issue create` directly with only `--label "architect:"` and `--label "priority:N-X"` — never `state:unstarted`. Result: 6 issues (#500, #501, #503, #505 already closed; #502, #504 still open) stuck without state labels.
- Cleanup applied:
  - `gh issue edit 502 --add-label state:unstarted` ✓
  - `gh issue edit 504 --add-label state:unstarted` ✓
  - `rm /tmp/backfill-architect-2026-05-06.py` ✓ (so nobody runs it again)
- Defensive change in `scripts/architect.sh`: now passes `--state "unstarted"` explicitly to `tracker.sh create`. This is the existing default — making it explicit means future readers see the contract at the call site rather than having to inspect `gh_create`'s defaults.
- Closed PRs from the wrong-state issues (#500, #501, #503, #505) already merged or got closed earlier today — no further action.
- **No change to Aaron's responsibilities.** Future architect runs will produce correctly-labeled issues. The 5 historical labelless issues (#216 epic, #358 warmup filter, #434 archive exercises) are NOT architect-related and remain as Aaron-judgment items.

### 2026-05-08 — Architect body-rendering bug: list-vs-string field handling
- Validation run of architect.sh (axis: composable-quality) succeeded on the labeling and counting fronts (5 findings, 5 issues filed, all with state:unstarted, priority, architect: labels) but the issue bodies came out as `Error generating body: sequence item N: expected str instance, list found`. Root cause: Claude's JSON output drifted between runs. On 2026-05-06, `proposed_approach` was a single string with newline-separated bullets. On 2026-05-08, the same field came back as a JSON `list[str]` of 4-5 bullet items. The body generator did `lines.append(f.get('proposed_approach', ''))` — appending the list verbatim to a string-array, which then failed `'\n'.join(lines)`.
- Fix in `scripts/architect.sh`: both the markdown report block and the issue-body block now go through `render_text_or_bullets(value)` — if the field is a list, format as `- item` bullets; if a string, return as-is. Applied defensively to `motivation`, `proposed_approach`, and `sequencing_notes`.
- Prompt sharpened in `lib/architect-utils.sh`: the JSON schema in the prompt now specifies `proposed_approach` as an array (with example), and `motivation` / `sequencing_notes` as strings explicitly. Reduces Claude's wiggle room to drift further.
- Backfilled the 5 broken bodies (#518-522) by replaying the corrected logic against the captured run JSON. Regenerated `data/architect-2026-05-08.md` from the same source.
- **No change to Aaron's responsibilities.** Architect runs going forward will render issue bodies correctly.

### 2026-05-08 — Triage agent: pick up unlabeled (manually-created) issues
- Aaron observed: issues #216, #358, #434 had been sitting open for weeks with no triage updates. Investigation: triage.sh queried `tracker.sh list backlog unstarted` (line 50) — same inclusion-based pattern as the builder's old `list unstarted`. Manually-created issues without a `state:*` label were silently invisible to the triage agent and never got reviewed, scoped, or promoted into the picking pool.
- Same structural fix as the builder's `list pickable`: added `list triageable` to `adapters/tracker.sh`. Returns every open issue NOT in `{state:started, state:blocked, state:canceled}`. Includes state:triage, state:backlog, state:unstarted, AND fully-unlabeled issues. Excludes only terminal/in-flight states so triage doesn't disrupt active work or revive intentionally-blocked items. Idempotency (skip already-triaged issues by "Triaged by" comment match) is unchanged in the agent itself.
- `scripts/triage.sh` now queries `list triageable` (was `list backlog unstarted`).
- Locked-in via `tests/tracker.bats`: new test asserts `list triageable` hits `--state open` with no `--label state:backlog/unstarted` filter.
- Live count: 17 triageable issues (was 8 under the old query). The 9 newly-visible issues are #216 (epic), #358, #434, plus a mix of `state:backlog` items that hadn't been re-triaged. Triage's `MAX_PER_RUN=10` cap means the first run after this fix processes 10; the rest are picked up in the next run.
- **What Aaron will see:** the next triage run (Sun/Tue/Thu 22:30) processes the orphans. Each one gets a "Triaged by..." comment, a verdict (APPROVE / ENHANCE / SKIP / FLAG / RESCOPE), and the appropriate state label. After triage runs once, #216 will likely be FLAGGED or RESCOPED (it's an epic), #358 likely APPROVED/ENHANCED, #434 likely FLAGGED (the title is barely coherent — needs human input).
- **No change to Aaron's responsibilities.** Manually-created issues now flow through the pipeline automatically.

### 2026-05-12 — Builder: PICKED_ISSUE_OVERRIDE env var + security-scan false-positive fix
- **PICKED_ISSUE_OVERRIDE hook (`scripts/builder.sh`):** when the env var is set, the builder skips its pre-pick Claude call and uses the override as the issue ID. Flips tracker state to `In Progress` and runs the implementation stage exactly as if pre-pick had returned that issue. The override is cleared after use, so a multi-iteration loop falls back to normal pre-picking from iteration 2 onward.
  - **Why:** Aaron's normal flow is "let the builder pick" — but sometimes a specific Lift bug needs the builder's attention right now and the priority/recency sort wouldn't surface it next. Previous workaround was temporarily editing priority labels, which left side-effects.
  - **Usage:** `PICKED_ISSUE_OVERRIDE=LIFT-545 ./scripts/builder.sh 1` from inside `pilot/`.
- **Security-scan regex fix (`lib/security-scan.sh`):** the "Dynamic code execution" check used `grep -iE '\bFunction\s*\('` — case-insensitive matched lowercase `function (` (the JS keyword) as well as the uppercase `Function()` constructor. First inaugural run of the override hook on LIFT-545 was blocked from auto-PR because the agent's `(function () { ... })()` IIFE in the report toolbar handler tripped the check. Fix: split the Function-constructor check into its own case-sensitive grep; left the lowercase-noise patterns (`eval`, `exec`, `spawn`, `child_process`) on `-i`.
  - Re-ran the scan against the LIFT-545 branch after the fix → exits 0. Opened PR [#559](https://github.com/aschung212/Lift/pull/559) manually to recover the run.
- **No change to Aaron's daily responsibilities.**
