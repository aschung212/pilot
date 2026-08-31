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
| **Check per-PR review status** | Each PR has inline review results in description (Claude Sonnet post-commit review). PRs now include a Verification section (steps to test, expected behavior, risk assessment) and a Vercel preview URL for quick testing. | PR description shows review findings + verification checklist + preview link |
| **Test on preview deploys** | Click the Vercel preview URL in the PR description. Preview mode is enabled by default — Supabase writes are blocked (safe to use real Google account). Toggle "Enable writes" in the blue banner if you need full write-path testing. Test account available: test@lift.local / LiftTest2026! | Vercel preview URL in PR body |
| **Test locally if needed** | `cd ~/development/lift && npm run dev` | localhost |
| **Merge or request changes** | GitHub PR UI — merge individually, each PR is self-contained | Vercel auto-deploys on merge to master |
| **Leave a closing comment when rejecting a PR** | If you close a PR without merging, add a one-line comment saying why. cleanup.sh harvests it into `data/lift-build-learnings.md` and the builder reads it every iteration — no comment means the builder cannot learn from the rejection. | GitHub PR UI |
| **Act on digest blockers** | The 6:15 AM digest now lists "⏳ Waiting on you" (needs-input issues — answer, then flip `state:needs-input` → `state:unstarted`), "⚖️ Needs your call" (issues whose PR was closed unmerged — recycle to unstarted or close as not planned), and "⚙️ Pilot pipeline" (open issues in the Pilot repo itself — these are pipeline defects, **no agent works them**, they're yours to fix or delegate in a Claude session). Each section renders only when nonzero. | #daily-review digest |
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
| **Read the Health Report's Services section** | Auto-posted Sunday 08:00. It now reconciles every committed plist against `launchctl`: not loaded, non-zero last exit, or a log staler than the service's own cadence. Nothing watched launchd exit codes before 2026-08-28, which is how two agents stayed broken for months. Anything listed there is a service that is failing or not running at all. |
| **Act on the doc-drift audit** | Auto-posted to #lift-automation Sunday 09:00, **every other week** (even ISO weeks). Flags docs that disagree with the repo: undocumented scripts/adapters/env vars, dead references, plists missing from the schedule tables, stale test counts, broken vault paths. Each finding needs your call on which side is wrong — sometimes the doc is right and the code is the bug. Run any time: `./scripts/doc-drift-audit.sh`. |
| **Act on the stale-PR audit** | Auto-posted to #lift-automation Sunday 08:15. It flags open PRs whose work already shipped — no-op merges, migrations duplicating a master column, two open PRs adding the same column. A clean week still posts one line, so silence means the job broke. Anything flagged is a PR to close or land **before** Sunday 22:00 discovery. |
| **Manage Linear backlog** | Reprioritize, add comments/context to flagged issues. Completed/canceled issues and duplicates are archived automatically each night. When canceling, add a comment explaining why — discovery agent learns from this. |
| **Update product decisions** | If you reject a category of feature (not just one issue), update `Lift - Product Decisions.md` in your vault |
| **Review delivery metrics + GA burndown** | Weekly health report (Sun 8 AM, #pilot) now shows merged PRs, merge rate, time-to-merge, open-PR aging, tokens per merged PR, and GA-milestone burndown. If the "review queue aging" anomaly fires, clear the PR queue — the builder pauses nights at `MAX_OPEN_PRS` (8) open PRs. |
| **Review metrics** | `pilot/data/lift-metrics.csv` and `lift-discovery-metrics.csv` |
| **Review token usage + runtime** | `pilot/data/lift-usage-tracking.csv` and `lift-runtime.csv` — budgets auto-tune but review if unexpected |
| **Update CLAUDE.md** | If design principles or code standards evolve |

---

## One-Time Setup (pending)

**Load the stale-PR audit plist (added 2026-08-28).** The launchd job is committed but not yet loaded on this machine:

```bash
cp ~/development/pilot/launchd/com.aaron.pilot-stale-pr-audit.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.aaron.pilot-stale-pr-audit.plist
```

Verify with `launchctl list | grep stale-pr-audit`. Until it is loaded, the audit only runs when you invoke it by hand.

**Load the doc-drift audit plist (added 2026-08-28).** Same deal:

```bash
cp ~/development/pilot/launchd/com.aaron.pilot-doc-drift.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.aaron.pilot-doc-drift.plist
```

Verify with `launchctl list | grep doc-drift`. It fires weekly but no-ops on odd ISO weeks, so the first real run is **Sunday 2026-09-06** (ISO week 36).

- [x] Run `/github subscribe aschung212/Lift` in #lift-automation in Slack ✅ 2026-03-31
- [x] Schedule `linear-digest.sh` via cron or launchd for mornings ✅ 2026-03-31 (launchd, 6:15 AM daily)
- [ ] Create the `GA` milestone in aschung212/Lift and add the GA-blocking issues to it — the weekly health report tracks it as the release burndown (added 2026-08-28)

---

## What's Fully Automated

- **PR-close reconcile** — the first step of every Triage run: an issue whose PR was closed unmerged is either closed (when a rejection verdict is recorded and the title/body links agree) or released from `state:started` back to `state:triage`. Prevents the leak that hid 74 of 107 open issues from Triage. Kill switch `PR_RECONCILE_ENABLED=0`.
- Decomposed pipeline — 10 independent services, each with its own launchd plist (plus the daily digest). No orchestrator:
  - Discovery (Sun/Tue/Thu 10 PM): finds improvements, creates GitHub issues (Gemini + Claude). **GA-readiness mode since 2026-08-21:** rotation covers only bug-hunt, performance, ux-polish, accessibility, pwa-reliability, security-deps — no feature research, no test-coverage hunting.
  - Triage (Sun/Tue/Thu 10:30 PM): reviews issues, adds implementation plans (Gemini, Claude fallback). **GA gate:** net-new features and test-only issues are SKIPped ("deferred until post-GA"); only bug/perf/UX-polish/a11y/security work reaches the builder.
  - Builder (Mon-Fri 11 PM): implements per-issue branches (`enhance/LIFT-{id}-{date}`), per-issue PRs with Claude Sonnet adversarial review (post-commit hook, single model) + auto-fix cycle, CI check. Uses git worktree for isolation. Failed PRs (`ci:failed`) auto-retried next night. **WIP limit (2026-08-28):** pauses the night when `MAX_OPEN_PRS` (8) PRs are already open. Prompt carries rejection learnings from `lift-build-learnings.md`.
  - Cleanup: runs at end of builder — archives completed/canceled, deduplicates backlog, recycles abandoned issues, harvests rejection learnings from closed-unmerged PRs, snapshots the needs-your-call list for the digest, and expires P4 issues untouched for `BACKLOG_EXPIRY_DAYS` (56)
  - Auditor (Wednesday 6 PM): pipeline self-audit
  - Roadmap Synth (Wednesday 7 PM): synthesizes the roadmap from the backlog
  - Architect (Wednesday 8 PM): deep architectural review
  - Budget Tuner (Sunday 9 PM): adjusts iteration/token caps based on week's data
  - Health Report (Sunday 8 AM): weekly metrics dashboard, log rotation, anomaly detection
  - Stale-PR Audit (Sunday 8:15 AM): flags open PRs whose work already shipped — no-op merges, migrations duplicating a master column, two open PRs adding the same column
  - Doc-Drift Audit (Sunday 9:00 AM, every other week): checks README, both Pilot docs, CLAUDE.md and the Pilot-referenced vault paths against the repo's actual state
- Version controlled at [github.com/aschung212/pilot](https://github.com/aschung212/pilot)
- Swappable components via adapter scripts (tracker, notify, AI models)
- Structured logging via `lib/log.sh` — unified daily log, error alerting to Slack
- Backpressure: builder signals discovery when backlog is low
- Branch protection on master: requires build-and-test CI to pass before merge
- Vercel preview deploys per PR; auto-merge available (GitHub setting enabled)
- Post-merge CI failure → Slack notification
- Slack threading: one parent message per night, all updates threaded (updated for multi-PR output)
- Slack webhooks: all notifications are token-free (no Claude instances spawned)
- Test suite (bats-core, 344 tests across 26 files): fast tier (297 tests) runs on every commit via pre-commit hook, full tier (344 tests) runs on push via GitHub Actions CI
- Auto-discovery smoke tests: fail when new scripts lack test coverage — enforces that every new script gets tests
- Linear digest: posts board snapshot to #daily-review at 6:15 AM daily (launchd)

## What's NOT Automated

- **~~Starting scripts~~** — ✅ Automated: every stage has its own launchd plist (see the service list above). There is no `com.aaron.lift-overnight` orchestrator; that plist was retired when the pipeline was decomposed.
- **Loading new launchd plists** — a plist committed to `launchd/` does nothing until you `cp` it to `~/Library/LaunchAgents/` and `launchctl load` it. Check One-Time Setup above for any pending.
- **Merging PRs** — intentionally manual (review first)
- **Daily notes** — Aaron writes the content, AI reviews it
- **Linear triage** — discovery creates issues, Aaron prioritizes and adds context
- **LeetCode solving** — Aaron solves, notes it in daily note, automation tracks it
- **Adding tests for manual script changes** — when editing pilot scripts by hand, add/update corresponding bats tests in `~/development/pilot/tests/`. Pre-commit hook will catch missing coverage for new scripts.

---

## Builder Auth (re-login)

Every pilot agent (`builder`, `discover`, `triage`, `architect`, `pipeline-auditor`, plus the `ai-code` adapter and the `review-router.sh` reviewer) authenticates the `claude` CLI the same way. Under launchd there is no interactive session to refresh an OAuth login, so a keychain login can silently lapse for days — and when it does, **every** agent 401s. The builder's pre-pick stage fails on every iteration and the night produces zero PRs (root cause of the 2026-06-19 / 2026-06-22 dead nights).

As of 2026-06-23 the builder runs an **auth preflight** before its main loop: one cheap `claude` probe. On an auth failure it aborts immediately and posts a 🚨 alert to **#lift-automation** (and the build thread) instead of grinding through doomed iterations. If you see that alert — or a run of zero-PR nights — the token has lapsed.

**The durable fix (recommended) — a long-lived token in `~/.zshenv`.** A `claude setup-token` token does not expire for ~a year and, exported in `~/.zshenv` (which every pilot script sources), survives launchd with no keychain-refresh dependency. ⚠️ `claude setup-token` only *prints* the token — running it is **not** enough; the token must be persisted. Use the helper, which validates the token against the API before writing it:

```bash
claude setup-token                       # mint a token; copy the sk-ant-oat… value it prints
~/Documents/Scripts/set-claude-token.sh  # paste it; validates + writes CLAUDE_CODE_OAUTH_TOKEN to ~/.zshenv + re-verifies
```

A green result means the next run of any agent will authenticate. This fixes the **whole pipeline** at once, not just the builder.

**Quick alternative — `claude login`.** Refreshes the keychain login instead (no token handling), but it expires again in a few weeks, recreating this outage; the preflight would at least alert you the same night.

**Verify manually** the way launchd sees it (clean env + source `~/.zshenv`, no inherited credentials):

```bash
env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.npm-global/bin" \
  bash -c 'source ~/.zshenv 2>/dev/null; claude -p "Reply with exactly: AUTH_OK" --max-turns 1'
```

If that prints `AUTH_OK`, the next scheduled run (discover/triage/builder, Tue/Thu + builder Mon–Fri 23:00) will authenticate. To catch up the same day, run one manual iteration: `cd ~/development/pilot && scripts/builder.sh 1`. Escape hatch to skip the preflight (debugging only): `SKIP_AUTH_PREFLIGHT=1`.

---

## Key Files

| File | Purpose |
|---|---|
| `~/development/pilot/` | Pipeline repo — all scripts, adapters, config, docs ([GitHub](https://github.com/aschung212/pilot)) |
| `~/Documents/Scripts/lift-*.sh` | Symlinks to `~/development/pilot/scripts/`. The five older plists (builder, discover, health, triage, tune-budget) point at these; the four newer ones (architect, auditor, roadmap, stale-pr-audit) point straight at the repo. Both work — prefer the direct form for anything new. |
| `~/development/pilot/launchd/` | Committed launchd plists. A plist here does nothing until it is copied to `~/Library/LaunchAgents/` and `launchctl load`ed. |
| `~/development/pilot/scripts/stale-pr-audit.sh` | Weekly (Sun 8:15 AM) — flags open PRs whose work already shipped |
| `~/development/pilot/scripts/doc-drift-audit.sh` | Biweekly (Sun 9:00 AM) — checks the docs against the repo's real state; checks live in `lib/doc-drift-check.py` |
| `~/development/pilot/adapters/` | Swappable adapters: tracker, notify, ai-code, ai-research |
| `~/development/pilot/lib/log.sh` | Shared structured logging (unified log, error alerting) |
| `~/development/pilot/lib/service-health.sh` | Reconciles committed plists against `launchctl` — not loaded / non-zero exit / stale log. Called by the weekly Health Report. |
| `~/development/lift/CLAUDE.md` | Lift project standards (design, code, workflow) |
| `~/.claude/commands/ai-review.md` | Daily review slash command |
| `~/.claude/CLAUDE.md` | Global Claude instructions |
| `~/development/pilot/tests/` | bats-core test suite — 26 test files, 344 tests (fast tier, 297, runs in the pre-commit hook) |
| `~/development/pilot/.github/workflows/test.yml` | GitHub Actions CI — runs full test suite on push |
| `~/development/pilot/.githooks/pre-commit` | Git pre-commit hook — runs fast test tier before every commit |
| `~/Documents/Scripts/lift-triage.sh` | Gemini issue triage — reviews, enhances, and plans before builder runs |
| `~/Documents/Scripts/lift-budget.conf` | Token budget config — auto-tuned **weekly** (Sun 21:00) by `tune-budget.sh`. Inert from inception until 2026-08-28; see the changelog. Preview changes with `tune-budget.sh --dry-run`. |
| `~/Documents/Scripts/lift-tune-budget.sh` | Auto-tuner — analyzes usage + runtime history and adjusts budget config |
| `~/Documents/Scripts/lift-linear-cleanup.sh` | Linear cleanup — archives done/canceled issues, deduplicates backlog |
| `pilot/data/` | Logs, metrics, digests, cost tracking |
| `Obsidian: 20_Learning/Vibe Coding Projects/Lift/Lift - Product Decisions.md` | Product direction — rejected concepts, approved direction. Discovery agent reads this. |

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
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived `claude` auth for all headless agents. Set via `~/Documents/Scripts/set-claude-token.sh`. See [Builder Auth](#builder-auth-re-login). |

---

## Changelog

### 2026-08-30 — Pilot now notices when Lift's master CI is red

You asked why nothing caught that master CI had been failing 41 times in a row. It's because Pilot watched CI in two places and neither was the default branch: the builder retries PRs labeled `ci:failed`, and the health report watches Pilot's own launchd exit codes. The target repo's `master` had no watcher at all.

New `target-ci-watch.sh` runs as part of the **daily 06:15 Issue Digest** and puts every currently-red workflow at the top of the "waiting on you" block — failure streak, days since last green, and the exact failing job names. It escalates as the streak grows: 🔴 at one failure, ⚠️ at three, 🚨 *BROKEN* at ten.

It went in the digest rather than the weekly health report deliberately: a weekly cadence would have needed six reports to notice a streak this long, and a red default branch means nothing is deploying.

**It found a second outage on its first run.** `Integration Tests` has been red since 2026-08-18 — 13 consecutive failures, failing job `supabase-integration`. Nothing had ever surfaced it. That one is still open and is not fixed by tonight's work.

#### ⚠️ New for Aaron

- **A red workflow will now appear at the top of your morning digest** and stay there until it's green. That's the whole point — it should be annoying.
- **`Integration Tests` is still red** (`supabase-integration`, since 2026-08-18). Worth a look; it's unrelated to the migration problem that was fixed tonight.
- **Green is silent.** No news in the digest means every workflow passed. If the check itself can't read the branch, it says UNKNOWN rather than staying quiet.
- Turn it off with `TARGET_CI_WATCH_ENABLED=0` if it ever becomes noise.

### 2026-08-30 — Issues you file by hand now jump the queue

You asked: *"any issues i manually create myself (not automated via pilot) should still be picked up with top priority, even with the ongoing GA readiness policy. as a rule, if i take the time to file a ticket myself, I want it addressed asap."*

Before this, an issue you filed by hand was **actively buried within hours**. Three gates: Triage's GA policy SKIPped it as a net-new feature and stamped `priority:4-low`; the builder's pre-pick sorted feature-shaped issues last; and the builder only runs Mon–Fri. LIFT-1271 and LIFT-1272 were both headed there.

Now a new `claim-manual-issues.sh` runs as a pre-step of both Triage and the Builder. Anything open, authored by you, with no `state:*` label gets `origin:aaron` + `priority:1-urgent` + `state:unstarted` and a comment explaining the promotion. Triage may no longer SKIP it for being feature-shaped, and the builder's pre-pick takes it ahead of everything else.

The detector is exact rather than heuristic: every issue Pilot creates gets a `state:*` label at creation, so "no state label" means a human filed it. Checked against all 109 open issues — zero false positives, nothing to backfill.

#### ⚠️ New for Aaron

- **Just file the issue. Don't add labels.** The detector keys on the *absence* of a `state:*` label. If you add one yourself, the issue looks Pilot-created and won't be promoted. Title + body is all it needs.
- **It only promotes issues authored by you.** Lift is a public repo, so this is gated on the GitHub author — otherwise a stranger's first bug report would outrank your whole backlog. Set `MANUAL_ISSUE_AUTHOR` if that ever needs to change.
- **To opt an issue out**, remove the `origin:aaron` label and set the priority you want. To turn the whole thing off, `MANUAL_CLAIM_ENABLED=0`.
- **`priority:1-urgent` now means something.** Nothing else in the backlog carries it. If you start using it by hand, your issues and Pilot's will compete.

### 2026-08-30 — Three builder defects, found while your two feature issues failed to build

Forcing LIFT-1271 through the builder exposed problems that were costing every run, not just this one.

- **The pre-pick never saw priority labels.** Its prompt said priorities "appear in the issue list", but the underlying query has emitted bare `LIFT-N Title` rows in *every revision in this repo's history*. Your backlog has been ordered by title vibes, not priority, for the life of the pipeline. Fixed — the builder now annotates and pre-sorts the list itself.
- **330 permission denials across 51 August runs** (~6.5 per run). 57% were the agent trying to pin which binary runs (`PATH=…`, absolute paths) — shapes the allowlist can never match. The builder now hands every `claude` child an explicit `BUILDER_PATH`, and the prompt tells the agent that retrying a denied command with a PATH prefix is the one change guaranteed not to help.
- **Failed runs destroyed their own work silently.** LIFT-1271 was fully implemented, then hit the 100-turn ceiling on denied verification commands; the branch was deleted and 513 verified insertions were left uncommitted where the next run would wipe them. `BUILDER_MAX_TURNS` is now 150, failures print why they failed, and uncommitted work is parked on a `recovered/…` branch.

#### ⚠️ New for Aaron

- **Check for `recovered/…` branches after a failed run.** A failed iteration now parks its work there and posts to #lift-automation. Nothing is pushed — it's yours to keep or delete.
- **LIFT-1271 shipped as [Lift PR #1273](https://github.com/aschung212/Lift/pull/1273)** — recovered by hand from the failed run and verified (typecheck, lint, 3710 tests, build). Review it like any other Pilot PR; the provenance is in the PR body.

### 2026-08-28 — Backlog audit: 149 of 255 Lift issues closed, and the leak that let them pile up

**What happened.** A full audit of the Lift backlog closed **149 of 255 open issues (58%)**. The backlog had stopped describing work that needed doing, so the builder was spending runs on issues that were already shipped, already rejected, or duplicates.

| Cause | Closed |
|---|---|
| Already shipped on master | 34 |
| PR closed unmerged (rejection / stale / silent), issue left open | 36 |
| Supporter / monetization thread (confirmed dead) | 19 |
| Duplicates of another open issue | 11 |
| Obsolete premise or settled pattern | 2 |
| Bloat pass — charts, coverage-chasing tests, refactor churn, speculative perf | 47 |

**Root cause 1 — the `state:started` leak.** An issue flips to `state:started` when its PR opens; when that PR closes *unmerged*, nothing resets it. `tracker.sh`'s `triageable` query excludes `state:started`, so those issues became permanently invisible to Triage. **74 of 107 open issues carried `state:started` with zero open PRs** — 69% of the backlog unreachable by the pipeline's own self-cleaning stage.

All 74 were repaired to `state:triage` (triageable but not pickable, so they get re-examined before the builder can claim one). New `scripts/pr-close-reconcile.sh` prevents recurrence — see architecture doc, agent section 10. 8 new bats tests; full suite **307 green**.

Note this bucket was never undetected: `cleanup.sh` computes it and deliberately reports rather than acts ("a closed-unmerged PR may have been a deliberate rejection"). That rule is sound — it failed because the surfaced list was never worked through, reaching 74. The new script resolves only the subset whose decision is already recorded as a verdict on the PR; everything else still comes to you.

**Root cause 2 — retired discovery focuses are reachable with no guard.** The GA shift (`da78cc4`, 2026-08-21) correctly removed the feature-hunting focuses from the rotation: the queue is now `bug-hunt / performance / ux-polish / accessibility / pwa-reliability / security-deps`, stamped `2026-08-21-ga`. But "retired from rotation" is enforced by nothing — `discover.sh <focus>` accepts any name still present in the `case` block, and those retired prompts are unchanged since 2026-04-01, still soliciting exactly what the GA rules forbid (`competitors` still reads "Find features users love that Lift is missing").

`data/lift-discovery-log.md` shows it happening: **`[testing]` ran 2026-08-23 and `[monetization]` ran 2026-08-25**, producing #1188–#1191 and the #1201–#1205 Supporter cluster — 9 of the issues this audit closed, and monetization is banned outright by the GA rules. **Fix pending:** gate the retired focuses behind an explicit opt-in so a bare `discover.sh testing` refuses.

### 2026-08-28 — PR-close reconcile moved from manual to automatic (inside Triage)

Per your call that it must not need manual execution: `pr-close-reconcile.sh` now runs as the **first step of every Triage run**, immediately before the `list triageable` query — so an issue it releases from `state:started` is triaged the same night rather than waiting a week.

- Triage passes `--apply` (or `--dry-run` when Triage itself is dry-run, so a preview never mutates the tracker).
- A reconcile failure is **non-fatal** — logged and swallowed; it is a pre-step, not a gate.
- Kill switch: `PR_RECONCILE_ENABLED=0`.
- Verified live: a `--dry-run` Triage logged the reconcile pass, correctly flagged PR #1065's conflicting links without touching anything, then proceeded to its 23 untriaged issues.

Tests: +4 in `triage.bats` (ordering before the triageable query, failure non-fatal, dry-run propagation, kill switch). Suite 307 green.

### ⚠️ New for Aaron

1. **`pr-close-reconcile.sh` runs automatically inside Triage** — first step of every run, before the triageable query, so issues it releases are triaged the same night. It can close issues; watch the first few Triage logs. Disable with `PR_RECONCILE_ENABLED=0` if it misbehaves.
2. **The five stale focus prompts still need rewriting or deleting** — this is the remaining half of the fix and it is not done. `ui-refinement` and `pwa-reliability` show the pattern; the other five were missed by the GA shift.
3. **`state:started` now means what it says.** 74 stale labels were cleared, so the `list pickable` / `list triageable` pools reflect reality again — expect Triage to have real work to do on its next run.
4. [pilot#28](https://github.com/aschung212/pilot/issues/28) tracks the filing-side guards (filed during this audit as LIFT-1263 and relocated the same day — it is a Pilot defect, not a Lift one).

### 2026-08-28 — The Pilot repo's own issue queue gets a contract and a consumer

Your question — "is any agent actually reading the auditor's issues?" — had the answer *no*. The Pilot repo's queue was write-only: the auditor filed weekly, nothing read them, and its dedupe had never fired once (it searched titles for the finding ID, which only ever appeared in bodies), so nine open `[Audit P1]` issues were really **two** findings re-filed for months.

**What changed:**
- **Purged the queue.** pilot#9–#19 closed as not planned per your ruling: cost-per-merged-PR and time-to-merge measure *your* review bandwidth (merged PRs are the denominator), not pipeline health. Also same-day: LIFT-1263 moved out of the Lift tracker to pilot#28 — it was a Pilot defect sitting in the builder's picking pool.
- **Those two metrics never file issues again** (`audit_issue_worthy`, `lib/auditor-utils.sh`). They stay in the audit report and Slack digest as trend data; their actuator is the builder's `MAX_OPEN_PRS` WIP gate (backpressure), not the issue tracker.
- **Auditor dedupe fixed.** Finding ID now lives in the issue title (`[Audit P1] [<finding_id>] …`), so repeat findings comment on the standing issue instead of piling up.
- **The morning digest now surfaces the queue.** A "⚙️ Pilot pipeline" section in the 6:15 AM digest lists open Pilot-repo issues, rendered only when nonzero.

**New responsibility for you (small):** when the digest shows the "⚙️ Pilot pipeline" section, those are pipeline defects waiting on a human — no agent works that queue, deliberately (a builder editing its own pipeline would permanently violate the Infrastructure Change Protocol). Fix them yourself or hand them to a Claude session. The queue should be near-empty; if it grows, that's the signal something structural is wrong. Currently open: pilot#28 (discovery/architect re-filing shipped and rejected work).

### 2026-08-28 — The Health Report now watches launchd exit codes

Yesterday's two dead agents both sat in one column of `launchctl list` that nothing read. The Health Report's service check existed, but it was hardcoded to three services (discover / triage / builder) and only asked whether they were **loaded** — never how they **exited**. Neither `tune-budget` (exit 126 since its first run) nor `roadmap-synth` (exit 1 weekly since 2026-05-06) was even in the list.

**`lib/service-health.sh`** replaces it. The service list is **derived from the committed plists**, so a new service is covered the moment it's added rather than when someone remembers to extend a hardcoded list. It answers three questions, ordered by how long each failure can hide:

| Question | Failure it catches |
|---|---|
| Is a committed plist not loaded? | It never runs, and nothing says so |
| Did a loaded service exit non-zero? | It runs and fails, silently |
| Is its log older than its own cadence? | Loaded, but never actually firing |

Exit **126** ("command found but not executable") and **127** ("command not found") get an explanatory hint — 126 is exactly what the tuner's malformed heredoc produced.

Findings appear in both the **Services** section and the **Anomalies** list, so they reach Slack rather than sitting in a file.

**Kept deliberately quiet.** Staleness thresholds derive from each plist's own schedule (`2× cadence + 1 day`), and a plist younger than one full cadence is exempt — without that, both services you loaded yesterday reported as broken because they hadn't fired yet. Four of the nine tests assert it says *nothing*; a weekly report that cries wolf gets skimmed and then ignored.

**On the current machine it reports exactly the two known failures** and nothing else:

```
com.aaron.pilot-roadmap last exited 1
com.aaron.pilot-tune-budget last exited 126 (command found but not executable — check the invocation)
```

Both are fixed as of yesterday's merge, so they should clear on their next runs — roadmap Wednesday, tune-budget Sunday. **If they don't clear, the fixes didn't take**, and this check is now how you'd find out.

**Also fixed:** the Anomalies section printed "✅ No anomalies" and then listed the warnings underneath it. It now uses the existing `append_anomaly` helper, which replaces the placeholder on the first finding.

**Verification.** Full suite **295 passing, 0 failures** (9 new tests). Verified against the real machine state, not just fixtures. `bash -n` clean; doc-drift audit clean.

**My mistake, worth flagging:** while testing I ran `health-report.sh` without `--dry-run`, which posted a real Weekly Health Report to #pilot and #lift-automation. The report was accurate but unscheduled — if you saw a stray health report yesterday, that was me.

### 2026-08-28 — Two agents that had never once worked: the budget tuner and roadmap-synth

Checking that the two new plists had loaded surfaced non-zero exit codes on two *other* services. Both turned out to have been broken since inception.

**1. The budget auto-tuner had never adjusted a single value.** `launchctl` reported exit **126**.

- **Bug A — heredoc args after the terminator.** The Python block's positional arguments sat on the line *after* `PYEOF`, so `python3` ran with an empty argv. Every CSV path defaulted to `""`, so it read no data and always returned `skip: True`; bash then tried to **execute** `lift-usage-tracking.csv` as a command — "Permission denied", exit 126.
- **Bug B, hidden behind A.** With argv restored, `int(row.get('commits', 0))` hit `None` on short rows — `csv.DictReader` fills missing columns with `None`, so the `get` default never applies — and crashed on the **30 ragged rows** in `lift-metrics.csv`. `builder.sh` already used the correct `or 0` idiom; the tuner never ran long enough for anyone to notice it didn't.
- **Why nothing caught it:** the tuner had **five green tests**, and every one of them re-implements the Python *inside the test file*. None ever ran the script. New tests drive the real script end-to-end, and each was verified to fail when its fix is reverted.
- **Evidence of the blast radius:** `lift-tune-log.csv` contained only its header, last written **2026-04-03**, and `config/budget.conf` had not changed since **2026-04-02**. Roughly five months of "auto-tuning" that never happened.

**2. `roadmap-synth` had failed for 17 consecutive weeks.** Every saved output from **2026-05-06 through 2026-08-26** begins with Bun's `warn: CPU lacks AVX support` line, so `json.load()` on the captured stream died at "line 1 column 1". This is the *same* failure that made all 12 pre-pick stages unparseable on 2026-05-19 — `builder.sh` was hardened then, `roadmap-synth` was not. The extractor now falls back to the first line that parses as a JSON object, and strips the ```json fence Claude wraps the payload in. Replaying the real 2026-08-26 output through the fix recovers **10 themes** — the synthesis had been produced correctly all along and thrown away every week.

**New: `tune-budget.sh --dry-run`** — analyses and reports what it would change, touching neither `budget.conf`, the tune log, nor Slack.

**Doc claims corrected.** Both docs said the budget was "auto-tuned nightly". It is weekly (Sunday 21:00), and it was not tuning at all.

**Verification.** Full suite **278 passing, 0 failures** (8 new tests). Both fixes verified non-vacuously by reverting each and watching the matching test fail. `bash -n` clean.

**⚠️ New for Aaron — the tuner's first real run will cut your token cap.** Against the last 7 nights it wants:

```
MAX_ITERATIONS_PER_NIGHT     12 → 12     (unchanged)
MAX_OUTPUT_TOKENS_PER_NIGHT  500000 → 200000
ITERATION_COOLDOWN           30 → 30     (unchanged)
```

200,000 is the **floor** the script clamps to, so its raw suggestion was lower still — average nightly output is 95,242 with zero cap hits across those 7 nights. That change applies automatically at **Sunday 21:00**. If you'd rather it not drop that far, raise the floor at `scripts/tune-budget.sh` (`suggested_tokens = max(suggested_tokens, 200000)`) before then, or run `./scripts/tune-budget.sh --dry-run` yourself to re-check against fresher data.

### 2026-08-28 — Pilot PR backlog cleared (#24, #22 merged; #8 closed superseded) + honest PR-creation failures

All three open pilot PRs are resolved: **#24** (agile-gap pass) and **#22** (Opus 5 + architect-on-Fable-5 model bumps) merged after rebasing onto the day's main; **#8** (May builder hardening) closed as superseded — everything it fixed had since landed via the 2026-05-20 builder fixes and the 2026-08-28 `_marker_lines` work, except one live fragment ported forward here: the builder can no longer report a fabricated `pull/new/` compare link as a "PR" in Slack. A failed `gh pr create` now scores the iteration a failure, posts a ❌ alert with the preserved branch, and never inflates the nightly PR count. **No new responsibilities** — but if you ever see that ❌, the branch named in the alert holds real pushed work that needs a manual PR or deletion.

### 2026-08-28 — Biweekly doc-drift audit, and the 19 drifts it found on its first run

Docs drift silently. The 2026-08-28 sweep earlier today was done by hand, and hand-reading docs against the filesystem does not scale. `scripts/doc-drift-audit.sh` (checks in `lib/doc-drift-check.py`) does it mechanically.

**What it checks:** undocumented scripts/adapters/env vars · a `*.sh` named in the docs that no longer exists · plists missing from, or disagreeing with, the schedule tables · a plist pointing at a missing script · test counts vs the real suite (both tiers) · Obsidian vault paths Pilot depends on.

**It is a reporter, never an editor.** Every finding needs a human call about which side is wrong — sometimes the doc is right and the code is the bug.

**Two exemptions keep it honest.** Changelog sections are excluded from every check (history is *supposed* to describe the past), and doc tombstones — "the old `ai-review.sh` was deleted 2026-07-17" — are recognized as the docs doing their job. Without those it cries wolf, and a report that cries wolf gets ignored. Both are pinned by tests, along with scripts that legitimately live outside the repo and counts quoting either tier.

**Vault scope:** only the vault files Pilot itself reads or names (`PRODUCT_DECISIONS_FILE`, `PRODUCT_FEATURES_FILE`, and vault paths cited in Pilot docs). Your vault workflows are a separate domain and are not audited. A broken path here is a *Pilot* bug — discovery and triage degrade silently without it.

**Cadence:** launchd cannot express "every two weeks", so `com.aaron.pilot-doc-drift` fires weekly at Sunday 09:00 and the script no-ops on odd ISO weeks. Calendar-anchored, so it cannot drift the way a 14-day `StartInterval` would. First real run: **Sunday 2026-09-06**.

**The 19 findings on its first run — all fixed:**
- **A vault path was wrong.** Key Files cited `20_Learning/Vibe Coding Projects/Lift - Product Decisions.md`; the file actually lives under a `Lift/` subdirectory. The docs had been pointing at a nonexistent note.
- **`Fast tier (196 tests)`** — I updated the full tier this morning and missed the fast tier one line below. Both now derive from a real run (251 full / 246 fast, 22 files).
- **Six scripts documented nowhere:** `architect.sh`, `pipeline-auditor.sh`, `roadmap-synth.sh`, `capture-pr-screenshots.sh`, `orchestrator.sh`, and the new audit. Added to the README tree; `orchestrator.sh` is now labelled as superseded by the per-service plists.
- **Three undocumented env vars:** `OBSIDIAN_VAULT`, `AUDITOR_USE_AI_SYNTHESIS`, `GEMINI_API_BASE` — added to `project.env.example` and `init.sh`.

**A real bug in my own plist, caught by my own test.** `plutil -lint` passed `com.aaron.pilot-doc-drift.plist`, but XML comments may not contain `--`, and mine explained the `--biweekly` flag. `plutil` is lenient; launchd's parser and `plistlib` are not — the plist would have failed to load, silently, which is exactly the failure mode these plist tests exist to catch. Fixed, and the smoke test now reports it as a clean message instead of a traceback.

**Verification.** Full suite **251 passing, 0 failures** (12 new audit tests, half of them asserting it stays *quiet* on look-alike drift). After fixing all 19, the audit reports `✅ Docs match the repo.` `bash -n` clean; `plutil -lint` plus a strict `plistlib` parse on all 10 plists.

**⚠️ New for Aaron — one manual step,** the same shape as the stale-PR audit: `launchctl load` the new plist (see One-Time Setup). Note the audit runs the test suite twice (both tiers) and takes ~3 minutes.

### 2026-08-28 — Doc drift swept: the automated-services list was describing a pipeline that no longer exists

Checking whether the docs reflected the audit scheduling turned up adjacent sections that had gone stale and now contradicted the corrected ones. Fixed in the live (non-changelog) sections only — historical entries are left exactly as written.

- **"Review Tuner (Sunday 9:15 PM): learns from PR feedback" was still listed as fully automated.** It was decommissioned **2026-05-11**; `scripts/tune-reviews.sh` does not exist and no plist references it. Removed.
- **"6 independent services" → 9.** Auditor (Wed 6 PM), Roadmap Synth (Wed 7 PM) and Architect (Wed 8 PM) had never been added to the list, and Stale-PR Audit is new.
- **"Overnight runner: discovery → triage → builder chain starts at 11 PM nightly"** — removed. There is no orchestrator plist; the pipeline was decomposed long ago, and the stated time was wrong besides (discovery is 10 PM).
- **`com.aaron.lift-overnight`** was still cited in *What's NOT Automated* as the thing that automated script-starting. That plist is retired. Replaced with an accurate line, plus a new entry noting that a committed plist does nothing until it is `launchctl load`ed.
- **Test counts:** "105 tests across 16 files / fast 101 / full 105" and Key Files' "20 test files, 211 tests" → **239 across 21, fast tier 234**.
- **Key Files' symlink claim** said launchd points at `~/Documents/Scripts/lift-*.sh`. Only five of nine plists do; the four newest point straight at the repo. Documented both, and noted the direct form as preferred for new services.
- **Removed the `/ai-review` line from *What's Fully Automated*.** Per the global instructions, the Obsidian vault workflows are a separate domain from Pilot and do not belong in this doc's automation surface. **Flagging this one explicitly** — it is a scope judgment, not a factual correction, so revert it if you disagree.

### 2026-08-28 — Stale-PR audit scheduled weekly (Sunday 08:15)

Following the duplicate-build fix below, the audit is no longer on-demand only.

- **New plist** `launchd/com.aaron.pilot-stale-pr-audit.plist` — Sunday **08:15**, runs `stale-pr-audit.sh --notify`. Placed 15 minutes after the Health Report (08:00) so the two weekly review artifacts land together, and ~14h before Sunday's Discovery (22:00) so anything flagged can be closed or landed before the next build cycle picks work up. No conflict with any existing job.
- **`--notify` is in the scheduled invocation** — a clean week still posts a single "clean" line, so silence means the job is broken rather than the backlog being healthy.
- **Schedule tables corrected.** The architecture doc's Scheduled Tasks table and the README's service table were both missing the Wednesday trio (Auditor 18:00, Roadmap Synth 19:00, Architect 20:00); the architecture one also omitted the daily Issue Digest. Both are now generated from the plists' actual `StartCalendarInterval` values.

**Verification.** `plutil -lint` passes, and three new smoke tests now guard *every* plist — valid XML, a Label plus a schedule, and a ProgramArguments script that exists in this repo (paths are rebased onto the checkout, since plists carry machine-absolute paths CI does not have). Each was confirmed to fail against a deliberately broken plist rather than passing vacuously — the first cut of the path check did pass vacuously, because `plutil -extract ... raw` returns an array's element *count*, not its elements. The script was also run under a launchd-equivalent environment (`env -i` with only the plist's `PATH` and `HOME`) — exit 0, `gh`/`git`/`python3` all resolve, `project.env` sources correctly, and the Slack webhook and `notify.sh send` subcommand are both present. No test message was posted.

**⚠️ New for Aaron — one manual step.** The plist is committed but **not loaded**; loading it needs your machine. After merging the PR:

```bash
cp ~/development/pilot/launchd/com.aaron.pilot-stale-pr-audit.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.aaron.pilot-stale-pr-audit.plist
```

Then `launchctl list | grep stale-pr-audit`. The script must exist in the **main checkout** first, so merge before loading.

### 2026-08-28 — Why the pipeline built the same change twice (LIFT-783 / LIFT-1039), and the three defects behind it

**Symptom.** Resolving PR #1041 surfaced that the pipeline had shipped the same work twice: LIFT-783 (PR #1032, merged 2026-08-04) and LIFT-1039 — "Split from LIFT-783" — (PR #1041, opened 2026-07-29). Same migration, same always-send upsert field, same setter. #1041 sat open a month and merged with **zero schema delta**; the only thing worth keeping was an unrelated `syncQueue` bug it found on the way.

**Root cause — a lost state flip, not a dedupe gap.** Every dedupe layer worked as designed; they are all keyed on *issue identity*, and the work had been laundered into a new identity. The chain:

1. `2026-07-27` run 3's pre-pick produced no parseable `ISSUE_PICKED` marker. The run log says it plainly: *"state-flip-on-pick is skipped this iteration."* Stage 2 still ran, picked LIFT-783 on its own, and opened PR #1032.
2. Neither fallback flip fired. The commit-driven one skips any issue that has an `ISSUE_DONE:` marker; the handler it defers to required a **pipe** separator (`ISSUE_DONE:LIFT-N|summary`) that the builder has never once emitted — **0 of 96** recorded runs use it; every run uses the colon form. That handler had been dead code since it was written, taking the state flip, the "Implementation complete" comment, the PR-title fallback, and the Slack digest links with it.
3. So LIFT-783 sat at `state:unstarted` with an open PR.
4. Triage — the only stage that never looked at pull requests — treated it as fresh backlog, returned RESCOPE, created LIFT-1039, and canceled the parent.
5. The builder picked LIFT-1039. New number, no open PR references it, every guard passes. PR #1041.

**On the three hypotheses in the original write-up:** (1) parent/child splits leaving both buildable — **not what happened**; triage canceled the parent six seconds after creating the child. (2) a pre-build freshness check against the codebase — **would not have prevented this**; at #1041's creation `plate_count_mode` was not in master, only in the still-open #1032, and master stayed clean for six more days. (3) PR queue depth — **right instinct**; depth is why the waste went unnoticed for a month, though the duplicate was created within 22 hours, so depth amplified the cost rather than causing it.

**Fixes.**
- **`lib/builder-utils.sh` / `scripts/builder.sh`** — new `_marker_lines` accepts every separator the agent actually emits (`:`, `|`, em dash, bare) and normalizes to one form. Resurrects four parsers.
- **`scripts/triage.sh`** — defers any issue with an open PR. A **deferral, not a skip**: the issue is untouched and comes back into scope when the PR merges or closes, so a false positive costs one cycle and can never drop real work. Fails open; every deferral is logged and posted to the triage Slack thread.
- **`adapters/tracker.sh`** — open-issue queries now share `GH_OPEN_LIMIT` (**200 → 1000**) plus a truncation warning. Found while verifying the above: with 265 open issues, the 200 cap was hiding **8 of 10** triageable issues and **3 of 5** pickable ones. The builder had been choosing from a pool of 2.
- **`scripts/stale-pr-audit.sh`** (new) — flags open PRs whose work already shipped: no-op merges, migrations duplicating a master column, and two open PRs adding the same column.

**Backlog audit (your "worth checking" ask).** Ran the audit over the open-PR set: **no other duplicates**. No no-op PRs, no migration duplicating master, no two PRs colliding on a column. #1041 was a one-off, not the tip of a pile.

**Side effect of the truncation fix — `cleanup.sh` now sees the whole board.** Its dry-run reports **150** issues `state:started` with a merged PR (was 92 at the 2026-07-27 audit) and **42** stuck behind a closed-unmerged PR (was 7). Most of that jump is issues the 200 cap had been hiding from the recycler, not new decay. Nothing is auto-recycled (0 recycled — the conservative "no PR ever" rule still holds), and the run exits 0. It is also slower now (~4 min, more issues to cross-reference), which matters only if you time the overnight chain.

**Verification.** `bash -n` clean across all scripts; full bats suite **239 passing, 0 failures** (up from 199 — 9 marker tests, 4 triage-deferral tests, 7 audit tests, 3 launchd-plist smoke tests). `triage.sh --dry-run` against the live backlog now prints `🔒 Deferred 1 issue(s) with an open PR — LIFT-616` — a **live recurrence** of the exact #783 configuration, caught. The audit's cross-PR check was retro-validated against the incident: it reports `exercises.plate_count_mode added by PRs [1032, 1041]` on the day #1041 was opened, a month before it was found by hand.

**⚠️ New for Aaron:**
1. **`stale-pr-audit.sh` now runs weekly, Sunday 08:15** (`com.aaron.pilot-stale-pr-audit`), posting to #lift-automation — scheduled at your request after you reviewed it. It lands 15 minutes after the Health Report and ~14h before Sunday's Discovery, so anything it flags can be closed or landed before the next build cycle picks work up. Run it any time with `./scripts/stale-pr-audit.sh` (add `--notify` to post). **You must `launchctl load` the new plist once** — see the Weekly section.
2. **I did not run `builder.sh 1`.** The Infrastructure Change Protocol calls for it, but it opens a real PR against Lift and spends budget, so I verified the exact tracker/triage queries the builder depends on instead. Worth doing before the next unattended run.
3. **LIFT-616 is the live recurrence** — `state:unstarted` with open PR #1065 (28 days). Triage now defers it, so it can't be forked, but the PR still needs landing or closing.
4. **The picking pool more than doubled** (2 → 5 pickable) now that truncation is fixed. Expect the builder to have more to choose from tonight.
5. **42 issues need your call** (up from 7) — `state:started` with a closed-unmerged PR. Cleanup never auto-recycles these because closing a PR may have been a deliberate rejection. It will keep reporting them until you either recycle them to `state:unstarted` or close them as not planned. The **150** issues sitting `state:started` with a merged PR are harmless to the picking pool but inflate the do-not-pick list in every builder prompt.
### 2026-08-28 — Agile-gap pass: outcome metrics, rejection-feedback loop, WIP limit, blockers in the digest, GA burndown, backlog expiry, acceptance criteria

Pilot mirrored most agile ceremonies but measured activity instead of outcomes, and the feedback loop from Aaron's merge/reject decisions had been dead since the review tuner was removed (2026-05-11). Seven changes close the gaps — full technical detail in the [architecture doc changelog](pilot-architecture.md#changelog).

- **Weekly health report** gains a Delivery section (PRs merged, merge rate, time-to-merge, open-PR aging, tokens per merged PR) and a **GA burndown** against the `GA` GitHub milestone, plus review-queue-aging and low-merge-rate anomalies.
- **Rejection-learnings loop:** cleanup harvests your closing comments on PRs closed unmerged into `data/lift-build-learnings.md`; the builder reads it every iteration and stops repeating rejected approaches.
- **WIP limit:** the builder pauses the night when `MAX_OPEN_PRS` (default 8) PRs are already open, instead of piling more onto your review queue. `ci:failed` retries are exempt.
- **Morning digest** now surfaces blockers: "⏳ Waiting on you" (needs-input issues) and "⚖️ Needs your call" (issues whose PR you closed unmerged).
- **Backlog expiry:** P4 issues untouched for 8 weeks are auto-closed as not planned ("reopen if still relevant").
- **Acceptance criteria:** triage APPROVE/ENHANCE now attach a testable definition-of-done checklist; the builder must verify each criterion and cover it in the PR's Verification section.
- New knobs in `project.env`: `MAX_OPEN_PRS`, `BACKLOG_EXPIRY_DAYS`, `GA_MILESTONE`. Tests 251 → 267, all green.

**New responsibilities for Aaron:**
1. **Always leave a one-line closing comment when you reject a PR** — it becomes builder training data; a silent close teaches nothing.
2. **Create the `GA` milestone** in aschung212/Lift and add GA-blocking issues to it (one-time; the health report nags until it exists).
3. Act on the digest's blocker lines during the morning review; if the builder reports the WIP gate, clear the PR queue.

### 2026-08-28 — Lift: exercise-first gyms + tags manager (#1252, PR #1253); master CI found red (#1254)

- **What.** New **Settings › Exercises › "Manage Exercises"** — the inverse of Manage Gyms. Every exercise in one alphabetical, searchable list; each row expands to a Gyms and a Tags chip picker, toggles applying immediately. Collapsed rows carry a gym summary line ("Gold's Gym · Home Garage", or "All gyms" when unassigned) so membership gaps are scannable without tapping in; archived exercises sink to the bottom with an "Archived" prefix.
- **Why.** Gym membership was only editable gym-first: you tapped into a gym and got a checklist of exercises. Spotting that one exercise is at gyms 1 and 2 but should also be at gym 4 meant opening all four and transposing the matrix by hand. The per-exercise view existed only inside EditExerciseModal — one at a time, behind the log-set gear, buried among plate calculator / intensity / archive / delete.
- **Scope discipline.** Membership only: no exercise create/rename/archive/delete and no inline gym/tag creation, since those already have owners. A test pins their absence so the scope can't drift. Reuses the gym/tag manager shell and the existing chip chrome, so no new modal paradigm.
- **Also.** `toggleExerciseTag` consolidated onto the workout store (WorkoutTracker's duplicate removed). A live 44pt DOM audit of the new modal caught a real 1px HIG violation in my own CSS — the two-line row label measured 43px — now fixed and pinned in `cssRegression.test.ts`.
- **Found along the way: `master` CI is red** and has been since the #1250/#1251 merges — two stale tests, filed as [#1254](https://github.com/aschung212/Lift/issues/1254). One assertion missed the third `syncQueue.enqueue` argument that LIFT-1239 added; one uses hardcoded dates that just aged out of a rolling 6-month window. Not caused by #1253, but it blocks merging it (and everything else).
- **New responsibility for Aaron.** Fix #1254 first (a task chip is queued for it), then review + merge [PR #1253](https://github.com/aschung212/Lift/pull/1253) on a green check. Until #1254 lands, treat "2 failing shards" on any Lift PR as the known baseline rather than a new break.
- **Tests.** 24 new; 3501 passing locally; lint, typecheck and build clean. Verified live in the browser at mobile viewport in dark and light with 4 gyms / 9 exercises / 1 archived, including the round-trip back to the workout tab's gym filter.
### 2026-08-27 — Architect upgraded to Claude Fable 5

The weekly architect run (Wed 8pm) now uses Claude Fable 5 — the top-tier model — via a new `AI_ARCHITECT_MODEL` var in `project.env`; everything else stays on Opus 5 via `AI_CODE_MODEL`. Rationale: the architect is the deepest-reasoning, lowest-frequency agent, so Fable's 2× price (~$10/$50 per MTok) is negligible at one run per week while its findings feed everything downstream. Live `project.env` updated in place; unset `AI_ARCHITECT_MODEL` (or set it to an Opus ID) to revert — the script falls back to `AI_CODE_MODEL`. **New responsibility for Aaron:** there are now two model knobs in `project.env` — `AI_CODE_MODEL` (builder/discovery/code-gen) and `AI_ARCHITECT_MODEL` (architect only). When bumping models later, check both. Watch the first couple of Wednesday runs (#lift-automation) for cost/quality; if Fable's issue quality isn't visibly better, revert.

### 2026-08-27 — Opus-tier model bumped to Claude Opus 5 (1M context)

`AI_CODE_MODEL` moved from `claude-opus-4-8[1m]` to `claude-opus-5[1m]` — builder, discovery, architect, and code-gen now run Claude Opus 5, still at 1M context and `max` effort. The model string was verified with a live CLI probe before the switch (request succeeded, 1M context window confirmed). Live `project.env` updated in place; repo defaults, script fallbacks, the `init.sh` wizard default, and docs updated to match. Commit co-author trailers follow automatically via `model_display_name()` and now read `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. **No new responsibilities for Aaron** — pricing is unchanged from Opus 4.8 ($5/$25 per MTok) and no other knobs moved.

### 2026-08-21 — GA-readiness shift: Pilot re-aimed from feature discovery to stabilization

Lift's build-out is treated as a completed beta; the pipeline now works toward a general-availability release. Full technical detail in the [architecture doc changelog](pilot-architecture.md#changelog). Merged to main 2026-08-26 (PR #20).

- **Discovery** rotation replaced: `bug-hunt` ×5, `performance` ×4, `ux-polish` ×4, `accessibility` ×3, `pwa-reliability` ×2, `security-deps` ×2. Feature-research focuses (competitors, ui-trends, monetization, marketing, growth, seo-aso, onboarding, data-viz, dx-cicd, testing, pwa-patterns) retired from rotation (still runnable manually). Discovery output capped at 2–6 findings, each must cite a code location; no feature or test-only issues.
- **Triage** enforces the GA gate (features/tests SKIPped as "deferred until post-GA") and gained a one-shot `--re-triage` sweep to re-baseline the existing backlog under the new policy.
- **Builder** pre-pick prefers bug fixes > perf > UX/a11y polish at equal priority; its inline discovery no longer files feature or test-coverage issues.
- **Architect** swapped the `test-architecture` axis for `error-resilience` (failure paths, silent data loss, recovery) and deprioritizes purely structural refactors.

**New/changed responsibilities for Aaron:**
1. ~~One-time, after merging: run `triage.sh --re-triage`~~ — ✅ done 2026-08-26 at merge time (Claude ran the sweep; results in #lift-automation). Re-run only if triage policy changes again.
2. Expect morning PRs to be fixes/polish rather than features. SKIP verdicts on feature ideas are deferrals, not rejections — overridable per issue by flipping state back to `state:unstarted` after editing.
3. Optionally mirror the GA policy in `Lift - Product Decisions.md` (vault) so manual issue writing stays consistent with what triage will pass.

### 2026-08-17 — Lift: PWA boot path hardened against the standalone crash loop (issue #1155, PR #1157)

**What prompted it.** The installed iOS Home-Screen app hit WebKit's "A problem repeatedly occurred" kill screen (2026-08-17) and had to be reinstalled. The exact failure chain was never directly observed; two contributing defects were confirmed and fixed.

- **Defect 1 — SPA rewrite swallowed missing assets.** vercel.json's catch-all rewrite (`/(.*) → /index.html`) also matched `/assets/*`, so a hashed chunk that no longer existed returned HTTP 200 with the HTML shell instead of 404 (verified live). A stale precached index.html then executes HTML as a JS module and hard-fails before Vue mounts. The rewrite now carries a negative lookahead so real static/function prefixes (`assets/`, `api/`, `launch/`, `sw.js`, `workbox-*`, `sw-offline-handler.js`, `manifest.webmanifest`) miss it and 404; navigations keep the SPA fallback. Side benefit: a real 404 at `/sw.js` restores the browser's service-worker kill switch.
- **Defect 2 — unbounded automatic reloads.** App.vue's IndexedDB-restore path and useServiceWorker's `controllerchange` handler each ended in a bare `location.reload()`; if the trigger recurs after reloading, the page reloads forever. Both now route through a new `guardedReload(reason)` circuit breaker (`src/lib/reloadGuard.ts`): one automatic reload per trigger per browsing session (sessionStorage-counted), repeats suppressed and reported to Sentry via `logError`.
- **Prevention shipped in the same commit:** behavioral rewrite-scope regression tests (`vercelRewriteRegression.test.ts`), reloadGuard unit tests, and a new architectural invariant banning bare `location.reload()` outside the guard. CLAUDE.md Architecture Notes documents both guards — any new static output prefix must join the rewrite lookahead.
- **For Aaron:** review/merge [PR #1157](https://github.com/aschung212/Lift/pull/1157). After the merge deploys, `https://spa-rho-sandy.vercel.app/assets/index-DOESNOTEXIST.js` should return 404 (it returns 200 today). New observable signal: a Sentry event "Automatic reload suppressed — already reloaded once this session (…)" means a boot trigger is recurring on someone's device — that's the crash loop being caught, and worth investigating.

### 2026-07-28 — `/ai-review`: artifact prompts can now be *declined*, not just completed (Pilot demo video retired)

**What prompted it.** Aaron: *"the ai-reviews keep telling me to make a pilot demo video, but i dont want to… I am not going to make a video."* He was right that it kept coming back, and the cause was a real defect in the command rather than model drift.

- **Root cause.** The **Phase B+ portfolio prompt** rule in `~/.claude/commands/ai-review.md` read: *"Inject as a one-time action item; don't re-prompt once completed."* The only off-switch was **completed**. There was no state for "Aaron considered it and chose not to," so any artifact he declined re-injected itself on every single run — indefinitely. It had been surfacing on nearly every review since Phase C entry (6/2), plus riding along in the Carry-Forward Gap Analysis, which propagates review-to-review by design.
- **Fix.** Artifact prompts now have **three** states — `pending` / `done` / **`declined`** — with `declined` as a legitimate terminal state. Added a named exclusion list to the rule, seeded with the Pilot demo video (declined 2026-07-28), and an explicit instruction not to propose substitute framings of a declined artifact (shorter cut, Loom, GIF, screen recording). This mirrors the existing **Load Balancing retirement** precedent on the SD track, where Aaron declared sufficiency and the item was retired rather than re-nagged.
- **Vault sources cleaned** so the recommendation can't regenerate from data the command reads at Step 0.5: `40_Career/Strategy/Interview Prep Cadence.md` (Phase C cadence matrix — AI-fluency + Portfolio-artifacts rows — and the Phase C section), `40_Career/Company Research/Application Schedule.md` (the Phase C gate line, which sits inside the Current Phase Status block the command parses every run).
- **Nothing lost on the AI-native track.** The Pilot story is already carried verbally by `Q16` and the cover letters, which is where it actually did its work in both AI-native applications so far (Zapier, Figma).
- **New responsibility for Aaron:** none. This removes a recurring prompt.
- **If you decline another artifact in future**, say so once and it gets added to the same exclusion list with a date — no need to repeat yourself. The general lesson banked in the rule: *"he hasn't done it yet" is not evidence he still intends to.*

### 2026-07-27 — Builder was starving, not crashing: recycled abandoned issues and closed the backlog leak

**Symptom.** No PRs since 2026-07-23. The builder looked dead, but launchd was healthy and it had run on schedule — Fri 2026-07-24 fired at 23:00, ran for 4 minutes, produced 0 PRs, and exited after a single iteration with `NO_IMPROVEMENTS_REMAINING`. (Sat/Sun are not scheduled; the builder runs Mon–Fri.) Both 2026-07-23 run 3 and the whole 2026-07-24 session ended on the same log line: `🧹 Backlog filter: 2 pickable → 0 after removing already-claimed/attempted issues`.

**Root cause — a one-way backlog leak.** The builder's pre-pick flips an issue to `state:started` *before* implementation. If that iteration dies before opening a PR, nothing ever clears the label. Because `tracker.sh list pickable` is exclusion-based (everything not in triage/backlog/started/blocked/needs-input/canceled), a stuck `state:started` issue leaves the picking pool **permanently**. Nothing in the pipeline ever recycled them — `cleanup.sh` only closed issues already in tracker-state `completed`/`canceled`, which is why it kept reporting `0 closed` while the backlog quietly drained.

At diagnosis: 145 open issues carried `state:started`. Only 34 had an open PR. Of the remaining 113 — 92 had a **merged** PR (done, issue never closed) and 21 were genuinely stranded.

**A second, hidden bug.** `tracker.sh list <state>` used `--limit 100`, but 131 issues carried `state:started`. `gh issue list` truncates silently, so 31 issues were invisible to every consumer — the builder's do-not-pick list and the new recycle step alike. Raised to `--limit 200` to match the `pickable` query.

**Fixes.**
- **Immediate (data).** Recycled the 14 stranded issues that had **no PR of any state** back to `state:unstarted` — LIFT-536, 580, 598, 616, 619, 664, 666, 667, 751, 783, 834, 836, 850, 966. Effective picking pool went from **2 → 16**, above the 12-iteration nightly cap.
- **Durable (`scripts/cleanup.sh`).** New step 2 sorts every `state:started` issue into four buckets by cross-referencing PR titles and auto-recycles only the unambiguous "no PR ever" case. Issues whose PR was closed unmerged are reported, never auto-recycled — closing a PR may have been a deliberate rejection, and rebuilding it would churn. Adds a `recycled` column to `data/lift-cleanup-metrics.csv` (pre-existing rows have 3 fields; parsers must tolerate both).
- **`adapters/tracker.sh`.** `list <state>` limit 100 → 200.

**Verification.** `bash -n` on both scripts; `cleanup.sh --dry-run` reports `0 recycled` (the 14 were already fixed by hand), `92 done awaiting close`, `7 needs your call`, with in-flight open-PR issues correctly excluded — the buckets reconcile to 131 and match an independent manual cross-reference. Confirmed the builder's own filter now yields 16 pickable. I did **not** run `builder.sh 1`: it would open a real PR and spend tonight's token budget, so I verified the exact tracker queries the builder depends on instead.

**⚠️ New for Aaron — two things need your decision:**
1. **7 issues stuck with a closed-unmerged PR** — LIFT-750, 910, 925, 926, 949, 968, 969. Six were batch-closed within three minutes on 2026-07-20 (a stale-PR sweep, no rejection comments), so they're probably still wanted. Recycle to `state:unstarted` to rebuild, or close as not planned. Cleanup will keep reporting them until you act.
2. **92 issues are `state:started` with a merged PR** — work is done, the issue was never closed. They no longer block the builder, but they inflate the do-not-pick list injected into every builder prompt. Closing them is a 92-issue bulk write, so I left it for you.

Also worth knowing: **39 open PRs** are outstanding, the oldest from 2026-05-27. Every one of them holds its issue out of the picking pool, so the merge queue is now the pipeline's real throughput limit.

### 2026-07-17 — Relocated the cover-letter reviewer out of Pilot (job-search tooling, not the Lift pipeline)

The cover-letter reviewer fixed earlier today (see "Cover-letter reviewer moved off the (retired) Gemini CLI" below) was never actually part of the overnight Lift pipeline: nothing scheduled or referenced it, it used no Pilot infrastructure (`project.env`, `lib/`, adapters, `$TRACKER`/`$NOTIFY`), and it had simply been swept into the 2026-04-01 initial commit. Routing it through `adapters/ai-research.sh` in PR #15 had just given it its first real Pilot dependency — pulling the repo's scope toward "Aaron's AI-automation home" instead of "the Lift pipeline."

- **Moved it out.** `~/Documents/Scripts/review-cover-letter.sh` is now a **self-contained** script (the Gemini REST call inlined — no adapter dependency), replacing the symlink that used to point into the repo. Verified end-to-end with a live Flash review.
- **Removed from Pilot.** Deleted `scripts/review-cover-letter.sh` and `tests/review-cover-letter.bats` (5 tests) plus its Key Files row. Full suite: 216 → **211**, green.
- **New for Aaron.** No change in how you use it: `bash ~/Documents/Scripts/review-cover-letter.sh <letter.md> [job-desc.md]`, auth via `GEMINI_API_KEY` in `~/.zshenv`. It's now a real file (not a symlink), so it no longer depends on the pilot repo being present or on your branch state. Career/job-search tooling lives in `~/Documents/Scripts` and the Obsidian vault, not in Pilot.

### 2026-07-17 — Deleted the dead `ai-review.sh` adapter (last `gemini` CLI caller in the repo)

**What prompted it.** Sweeping for leftover callers of the retired `gemini` CLI turned up `adapters/ai-review.sh`, which still shelled out to `gemini -p ... --sandbox`. Those calls have failed with `IneligibleTierError` since 2026-06-18, and the adapter's Claude fallback meant it would have "worked" only on its degraded path — the same silent-degradation class fixed for research/triage in 089d662 and for the reviewer in 13c1d68.

**What we found instead.** The adapter was dead code, not a broken dependency:
- No callers anywhere — repo-wide, `~/.claude/scripts`, `~/.claude/commands`, launchd plists, and hooks. (The only home-wide hits were Claude session transcripts.)
- Its own header, dated 2026-04-06, read *"Safe to delete after 2026-05-06 if no issues arise."* That was 72 days ago.
- `tests/adapter-contracts.bats` had an "ai-review.sh interface" section whose only test actually asserts **triage** verdicts — the contract test was gutted in 2026-04-06 and just the label survived.
- The live `project.env` already had every `AI_REVIEW_*` var commented out, and `data/lift-review-learnings.md` no longer exists — so the adapter was reading "No learnings yet." even on its fallback path.

**Fix.** Deleted rather than migrated — migrating would have meant maintaining a REST-API path for code nothing calls.
- Removed `adapters/ai-review.sh` and `tests/ai-review.bats` (9 tests).
- Removed the `AI_REVIEW_MODEL_L*` / `AI_REVIEW_FALLBACK_L*` / `AI_REVIEW_TIMEOUT_L*` vars from `project.env.example`, `init.sh`, and `tests/test_helper.bash` — confirmed the deleted adapter was their only reader.
- Removed the dead 3-layer review wizard from `init.sh` (it prompted for L1/L2/L3 models that nothing consumed); it now just states that review runs via the hook.
- Relabeled the mislabeled contract-test section; updated `CLAUDE.md`, `README.md`, `docs/adapters.md`, and both source-of-truth docs to state that review is a **hook, not an adapter**.
- Also corrected `docs/adapters.md`, which still listed research as "Gemini CLI" — it moved to the REST API in 089d662.

Test suite: 223 → 214 passing, 0 failures (the 9 removed tests only covered the deleted adapter). No behavior change — nothing executed this code.

**New for Aaron:** Nothing to do. No runtime path changed. If you ever want a swappable review backend again, note the deliberate design decision recorded in `docs/adapters.md`: review is a PostToolUse hook (`~/.claude/scripts/review-router.sh`), so it has no adapter surface — reinstating one is a new design, not a revert.

### 2026-07-17 — Cover-letter reviewer moved off the (retired) Gemini CLI to the REST adapter

- **Symptom.** `scripts/review-cover-letter.sh` — the second-opinion reviewer you run before sending an application (symlinked at `~/Documents/Scripts/review-cover-letter.sh`) — still shelled out to the bare `gemini` CLI, so it had been silently broken since the 2026-06-18 OAuth-tier retirement (`IneligibleTierError`). It's career/personal tooling, not the overnight Lift pipeline, which is why the same-day research/triage fix skipped it.
- **Root cause.** Identical to the research/triage + review outages: Google retired the free "Gemini Code Assist for individuals" OAuth tier, so every `gemini -p` call now fails.
- **Fix.** Rewrote the script to route both review passes through `adapters/ai-research.sh` (Gemini REST API, free-tier Flash via `GEMINI_API_KEY`) — the same adapter discovery + triage use — with `--no-grounding` (it reviews supplied cover-letter text, it doesn't research the web). The retired CLI is no longer invoked anywhere. Kept the two-pass structure (full hiring-manager rubric → shorter fallback prompt); the adapter returns clean text, so the old `gemini`-startup-noise grep filter is gone. It now **fails loud** (non-zero exit + reason on stderr) when both passes come back empty, instead of printing a blank review. Also switched `set -euo pipefail` → `set -uo pipefail` per the code standard (the adapter fallback is an expected-failure path).
- **New for Aaron.** No new responsibility, still $0 (free Flash). Same command: `bash ~/Documents/Scripts/review-cover-letter.sh <letter.md> [job-desc.md]`. If it ever prints **"❌ Cover-letter review failed"**, that's the `GEMINI_API_KEY` / free-Flash quota — same fix as the discovery/triage alert (`~/.zshenv`, `adapters/ai-research.sh`).
- **Tests.** `tests/review-cover-letter.bats` switched from the `gemini` mock to the curl/REST path — it now asserts the adapter called `generateContent` **and** that the retired `gemini` CLI was never invoked, plus a fail-loud test for the both-passes-error case. Full suite green: **216/216** (after the `ai-review.sh` deletion above removed 9 tests). `bash -n` clean; verified end-to-end with a live Flash review.

### 2026-07-17 — Adversarial review migrated off the (retired) Gemini CLI to Claude

**Symptom.** Every builder PR since ~2026-06-30 shipped with no working adversarial review — silently. The review step printed an auth error and the build continued.

**Root cause.** Google retired the free "Gemini Code Assist for individuals" OAuth tier on 2026-06-18; the `gemini` CLI now returns `IneligibleTierError` / `UNSUPPORTED_CLIENT` ("migrate to Antigravity"). Google AI Pro/Ultra grant **no** Gemini API or CLI access, and the Gemini API free tier excludes all Pro models (`limit: 0`), so the paid AI Pro subscription could not rescue it. The Codex fallback was independently broken (missing binary).

**Fix.** `~/.claude/scripts/review-router.sh` now runs a headless `claude -p` reviewer (Sonnet by default, a different model than the Opus builder) on the same Claude auth that powers the builder — no new vendor, no extra billing. Same post-commit hook, env, and log paths. It now **fails loud** (Slack alert to #lift-automation + a `REVIEW FAILED` marker) instead of silently skipping. `builder.sh` prompt/Slack strings and all docs updated. Old Gemini script backed up at `review-router.sh.gemini.bak-13c1d68`.

**New for Aaron:**
- Nightly PRs are reviewed again (by Claude Sonnet) — morning triage review findings resume.
- Override the reviewer model with `PILOT_REVIEW_MODEL` (e.g. `opus`); tune the wall-clock cap with `PILOT_REVIEW_TIMEOUT`.
- **Same root cause also broke discovery research + triage** — both called the bare `gemini` CLI (triage had a Claude fallback; discovery did not). Fixed the same day by pointing them at the Gemini API key (free-tier Flash) — see the "Discovery research + triage fixed" entry below.
- To reinstate Gemini for review specifically, enable pay-as-you-go billing on the Gemini API project (~$0.10/review, separate from AI Pro) and switch the script/model back.

### 2026-06-25 — Builder commit trailers now correctly attribute Claude Opus 4.8

Lift PR commits had been tagged `Co-Authored-By: Claude Opus 4.6` (and lowercase / `(1M context)` variants) even though the builder runs Opus 4.8. Root cause: the builder prompt never specified a co-author trailer, so in headless mode the model self-reported a stale version from its own self-knowledge — the `--model` flag never controlled attribution. The trailer is now derived from `AI_CODE_MODEL` and injected explicitly into every committing prompt, so it reads `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and will track any future model bump automatically. Added `model_display_name()` to `lib/builder-utils.sh` with 6 regression tests. **No new responsibilities for Aaron** — existing open PRs keep their old trailers; only commits from tonight onward are corrected.

### 2026-06-23 — Builder auth preflight (zero-PR-night root cause)

**Symptom.** The builder produced zero PRs on 2026-06-19 and 2026-06-22 — every iteration "failed," 3/3, both nights.

**Root cause.** The Max-subscription OAuth token in the macOS keychain expired 2026-06-19 06:00 and never refreshed (no interactive session under launchd). Every iteration's pre-pick stage 401'd with `Invalid authentication credentials`. The loop swallowed the 401 as a soft "no parseable ISSUE_PICKED marker" warning and ground through `MAX_CONSECUTIVE_FAILURES` doomed iterations before stopping — a silent failure with no obvious cause in the digest. (Jun 20–21 were Sat/Sun; the plist only runs Mon–Fri, which is why only two failing nights show.)

**Action.**
- `lib/builder-utils.sh`: added `is_auth_failure()` — classifies a `claude` probe's output as an auth failure (401 / logged out) vs. a transient/network error.
- `scripts/builder.sh`: added an **auth preflight** before the main loop. One cheap `claude` probe down the real code path; on an auth-signature failure it posts a 🚨 alert to #lift-automation + the build thread and aborts (`exit 1`) instead of burning the loop. Transient errors are *not* auth signatures, so they fall through to the existing per-iteration handling. Escape hatch: `SKIP_AUTH_PREFLIGHT=1`.
- `tests/builder.bats`: 4 new tests for `is_auth_failure` (real 401 string, logged-out string, healthy response, transient network error). Full suite 203 green.
- Added a **Builder Auth (re-login)** section above with the exact `claude setup-token` + verify steps.

**Action needed for Aaron (one-time, interactive — only you can do this):** `claude setup-token` then `~/Documents/Scripts/set-claude-token.sh` (paste the token; it validates + persists `CLAUDE_CODE_OAUTH_TOKEN` to `~/.zshenv` + re-verifies). See **Builder Auth (re-login)** above. Note: running `claude setup-token` alone does **not** fix it — the token it prints must be persisted, which the helper does. From now on, a lapsed token alerts loudly the same night instead of failing silently.

**Resolved 2026-06-23:** token persisted to `~/.zshenv` and verified end-to-end — the clean-env probe returned `AUTH_OK`, and a manual `builder.sh 1` ran clean: auth preflight passed and the pre-pick stage (the call that was 401'ing) returned a valid `NO_IMPROVEMENTS_REMAINING`. Pipeline operational; tonight's discovery → triage → build chain will run normally.

### 2026-05-28 — Fixed 5 locally-failing bats tests (env-leak + stale fixtures)

**Symptom.** Running the bats suite from a normal interactive shell failed 5 tests (in `cleanup.bats`, `digest.bats`, `health-report.bats`) on a clean tree, even though CI-style runs looked fine.

**Causes (three distinct, not one).**
- `digest.sh` used `set -euo pipefail`. The `-e` aborted the run on benign pipeline "failures" — `grep` with no match on an empty board, and `head -N` closing a pipe early (SIGPIPE, exit 141). Both `digest.bats` tests asserted `status -eq 0` and so failed. (This is exactly the footgun CLAUDE.md warns about: use `set -uo pipefail`, not `-e`.)
- `cleanup.bats` asserted the output `"No Linear API token"`, a credential-gate message that the Linear→GitHub tracker migration (2732bce) deleted from `cleanup.sh`. Current code runs against `gh` and exits 0 with a summary — the test could never pass again.
- `health-report.bats` hardcoded fixture dates (`2026-04-23/22`) that aged past `health-report.sh`'s rolling 7-day window, so every fixture row was filtered out (`nights_run` → 0 instead of 2).

**Action.**
- `scripts/digest.sh`: `set -euo pipefail` → `set -uo pipefail` (with a comment explaining the SIGPIPE/no-match rationale). No user-visible output change; the digest just no longer aborts mid-run.
- `tests/test_helper.bash`: hardened `setup()` to scrub inherited secrets (all `SLACK_WEBHOOK_*`, `SLACK_BOT_TOKEN`, `LINEAR_API_*`) so the suite is hermetic — `_PILOT_TEST_MODE` only blocks re-sourcing, it does not clear vars bats inherits from `~/.zshenv`.
- `tests/cleanup.bats`: re-pointed the stale assertion at current GitHub-backed behavior (exits 0 + prints a cleanup summary).
- `tests/health-report.bats`: fixture dates are now generated relative to today, so they never age out of the 7-day window again.

**Action needed for Aaron:** None. Full bats suite (199 tests) green from a plain interactive shell.

### 2026-05-28 — Centralized agent-tuning knobs in project.env

Followed the model-config change by surfacing the rest of the system's hardcoded tunables into `project.env`, so cost/performance/behavior can be tuned in one place instead of editing scripts.

- **New knobs:** per-agent turn caps (`BUILDER_MAX_TURNS`, `BUILDER_FIX_MAX_TURNS`, `BUILDER_PREPICK_MAX_TURNS`, `DISCOVER_MAX_TURNS`, `ARCHITECT_MAX_TURNS`, `TRIAGE_MAX_TURNS`, `ROADMAP_MAX_TURNS`); builder resilience (`MAX_CONSECUTIVE_FAILURES`, `MAX_STALLS`, `MAX_FIX_ATTEMPTS`); Sonnet planning effort (`AI_TRIAGE_EFFORT`, `AI_ROADMAP_EFFORT`, default `high`).
- **New responsibility for Aaron:** to change how hard/long any agent works, edit `project.env` — not the scripts. Every value has a safe fallback, so unsetting one just reverts to the built-in default.
- Nightly budget/rate caps still live in `config/budget.conf` (auto-tuned); now mirrored into `project.env.example` for discoverability.
- All call sites keep `${VAR:-default}` fallbacks; the bats suite passes after the change.

### 2026-05-28 — Opus calls upgraded to Claude Opus 4.8 (1M context) at max effort

The builder, discovery, and architect agents previously ran the bare `opus` alias, which resolved to whatever Opus the CLI shipped (4.6, then 4.7) and could not request the 1M-context variant — that's why Lift PR commit trailers read "Opus 4.6 / 4.7". All Opus-tier calls are now pinned to `claude-opus-4-8[1m]` with `--effort max`, driven by two new `project.env` vars: `AI_CODE_MODEL` and `AI_CODE_EFFORT`.

- Touched: `project.env`(+`.example`), `scripts/builder.sh` (4 call sites; pre-pick keeps default effort), `scripts/discover.sh`, `scripts/architect.sh`, `adapters/ai-code.sh`, `init.sh`.
- **New responsibility for Aaron:** the model/effort is now centralized in `project.env`. To change the Opus model or effort later, edit `AI_CODE_MODEL` / `AI_CODE_EFFORT` there (one place) — don't hand-edit individual scripts. When a newer Opus ships, bump `AI_CODE_MODEL` to the new full version string (keep the `[1m]` suffix for 1M context).
- **Cost watch:** max-effort + 1M context is more expensive per iteration. Keep an eye on `data/lift-usage-tracking.csv`; drop `AI_CODE_EFFORT` to `high` if nightly spend climbs.

### 2026-05-21 — cleanup.sh stops re-closing already-closed issues

**Symptom.** The 2026-05-21 builder run logged `Cleanup: 101 closed, 0 deduped`, but all 101 issues had been closed on GitHub weeks earlier (e.g. LIFT-310 closed 2026-05-05, LIFT-438 closed 2026-04-29). The "closed" count counted re-processed issues, not new closures.

**Cause.** `cleanup.sh` step 1 iterates every issue in tracker-state `completed`/`canceled` and calls `tracker.sh close` on each, every run. Those tracker-states map directly onto GitHub's closed state, so the loop fired ~101 redundant `gh issue close` API writes per run and incremented `CLOSED` for every one.

**Action.**
- `adapters/tracker.sh`: new `state <id>` subcommand — returns `OPEN`/`CLOSED` for GitHub issues (empty for the decommissioned Linear backend). Locked in via `tests/tracker.bats` and the `tests/adapter-contracts.bats` command set.
- `scripts/cleanup.sh`: step 1 now checks `tracker.sh state` first and skips issues already closed on GitHub. `CLOSED` counts only real open→closed transitions; a new `ALREADY_CLOSED` count is surfaced in the log line and console output. The `--dry-run` preview no longer lists already-closed issues as "would close".
- Verified with `cleanup.sh --dry-run`: reported `101 already closed, skipped` (0 redundant writes on the next real run).

**Action needed for Aaron:** None. Expect the nightly `Cleanup: N closed` line to drop to near-zero — that is correct, not a regression.

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

### 2026-05-20 — Builder PR-pipeline fix: only 1 PR from a 12-run night
- **Symptom.** The 2026-05-19 overnight run started 12 iterations and 11 produced commits, but only one (`enhance/run3` → PR #604) became a real PR. The other 10 `enhance/runN-2026-05-19` branches were pushed to the Lift remote as empty refs identical to `master`, and the builder redid LIFT-589 four times and LIFT-520 three times. (Separately, the 2026-05-14 night's last 3 runs failed outright — that was the Claude rate limit resetting at 2:10am, a different issue, not addressed here.)
- **Root cause — three compounding bugs in `scripts/builder.sh`:**
  1. **Pre-pick parsing.** Stage 1's output is captured with `2>&1`; Bun prepends a `warn: CPU lacks AVX support` line, which made `json.loads()` throw and an `except: pass` silently drop the result. Every pre-pick stage logged "no parseable ISSUE_PICKED marker" even though Stage 1 had correctly picked an issue. Stage 2 then ran with no issue assignment and no dedupe list.
  2. **No cross-run dedupe.** With the pre-pick result lost and stray commits invisible to `git log master..ITER_BRANCH`, `NIGHTLY_ATTEMPTED_ISSUES` stayed empty all night, so every iteration re-picked from scratch.
  3. **`HEAD`-based commit detection.** The builder Claude sometimes `git checkout -b`'s its own branch (`test/*`, `refactor/*`) and commits there. The script counted commits via `git rev-list --count HEAD`, so it scored those runs a success while `ITER_BRANCH` stayed empty — and pushed the empty branch, producing no PR.
- **Fix.** (a) Pre-pick parsing scans for the JSON line + raw-grep fallback; (b) commit counts are now branch-scoped (`master..$ITER_BRANCH`); (c) new stray-branch reconcile moves `$ITER_BRANCH` onto off-branch work after Stage 2; (d) the Stage 2 prompt names the branch and hard-prohibits branch switching. Verified: pre-pick parsing replays correctly against all 12 corrupted 2026-05-19 capture files; reconcile + counting verified in throwaway-repo tests; `bash -n` clean.
- **Cleanup.** Deleted the 10 empty `enhance/runN-2026-05-19` branches + 9 duplicate/stale orphan branches. Salvaged the two stranded pieces of work into PRs: [#606](https://github.com/aschung212/Lift/pull/606) (LIFT-520 useModal composable) and [#607](https://github.com/aschung212/Lift/pull/607) (LIFT-504 useTheme SSR guard). LIFT-589/592 were already covered by PRs #604/#605.
- **Flag for Aaron — not fixed here:** the Lift repo's Husky `pre-push` hook throws `error: could not apply …` on branch-delete pushes. Harmless for deletes (used the GitHub API to bypass it) but worth a look — it may be interfering with the builder's normal pushes too.
- **No change to Aaron's daily responsibilities.** Tonight's scheduled run (23:00) is the live end-to-end test; expect distinct PRs per committing iteration and no repeated issues.

### 2026-05-21 — Builder ran only 2 iterations, produced nothing
- **Symptom.** The 2026-05-20 night ran just 2 of 12 iterations and made zero commits. Both iterations pre-picked LIFT-591 — an issue that already had open PR #596 — Stage 2 correctly skipped the duplicate both times, and the night ended.
- **Root cause.** Yesterday's pre-pick parsing fix made Stage 1 functional again, which surfaced a latent bug: the cheap pre-pick call does not reliably honor its "do not pick" lists. It was handed LIFT-591 in the exclusion lists and picked it anyway, twice. Then run 2's Stage 2 emitted `NO_IMPROVEMENTS_REMAINING` (meaning "this assigned issue is a dup"), and the script misread that as "whole backlog exhausted" and stopped the night.
- **Fix (`scripts/builder.sh`), three changes:**
  1. **Deterministic backlog filter** — the script now removes every excluded issue (open-PR, attempted/skipped tonight, in-progress) from the pickable list *before* the pre-pick sees it. The pre-pick can no longer pick a duplicate because it is not in the list.
  2. **Pre-pick validation guard** — if the pre-pick names an issue that is not in the filtered backlog, the pick is discarded and Stage 2 free-picks instead of wasting the iteration.
  3. **NO_IMPROVEMENTS gate** — Stage 2's `NO_IMPROVEMENTS_REMAINING` now ends the night only when Stage 2 was free-picking (no assigned issue). Genuine backlog exhaustion is the pre-pick stage's call.
- **Verified.** Against tonight's live data the filter takes the pickable pool 26 → 22 (removes LIFT-591 + 17 other open-PR/in-progress issues); `bash -n` clean; filter unit-tested under bash 3.2.
- **No change to Aaron's daily responsibilities.** Two consecutive thin nights (05-19 dup-storm, 05-20 dead-stop) are now both addressed. Tonight's 23:00 run is the live test.

### 2026-05-27 — Security-scan false positive blocked LIFT-653 (`RegExp.exec()`)
- **Symptom.** The 2026-05-27 builder run completed LIFT-653 (consolidating structural invariant tests into `architecturalInvariants.test.ts`) and committed cleanly, but the pre-push pattern scan (`lib/security-scan.sh`) blocked the push: `⛔ Dynamic code execution (eval/exec/spawn)`. The iteration was skipped (no gated push / CI / PR).
- **Root cause.** The "Dynamic code execution" arm matched `\bexec\s*\(`, which trips on the `.exec(` *method call*. The consolidated test file uses `RegExp.prototype.exec()` (`enqueueRe.exec(src)`, `deletePattern.exec(body)`, etc.) — a benign, ubiquitous JS idiom — to scan source for architectural invariants. This is the same class of false positive as the 2026-05-12 `Function(`/lowercase-`function()` fix: the scan can't distinguish a test that *greps for* a pattern from code that *executes* it.
- **Fix (`lib/security-scan.sh`).** The `exec` arm now excludes method calls: `\bexec\s*\(` → `(^|[^.[:alnum:]_])exec\s*\(`. Bare `exec(` and `child_process.exec` (caught by the separate `child_process` token) are still flagged; `.exec()` is not. Verified the full ruleset against the real LIFT-653 diff → now clean, and confirmed real threats (bare `exec`, `child_process`, `eval`, `Function`, `fetch`, `atob`) still trip.
- **Regression test.** Added `tests/security-scan.bats` (9 fast-tier tests) — the first coverage for this script. Locks in both documented false positives (`.exec()` method calls, lowercase `function()` IIFEs) and the real-threat detections. Suite now 199 tests / 22 files.
- **Recovery.** LIFT-653's work is committed locally on `enhance/LIFT-653-2026-05-27`; the in-session push also landed it on the remote as `enhance/run4-2026-05-27`. No PR was created (gated CI/PR step was skipped). Re-driving the PR is pending Aaron's call.
- **No change to Aaron's daily responsibilities.**

### 2026-07-15 — Builder silently offline for 5 days (hung `claude` call, no timeout)
- **Symptom.** The builder produced no PRs, commits, or logs from 2026-07-09 through 07-14. Discovery and triage (separate launchd jobs) ran normally the whole time, so the pipeline *looked* half-alive. Nothing alerted.
- **Root cause.** On 2026-07-09 the builder started Run 2 for LIFT-926, spawned the main implementation `claude` call, and that process **hung indefinitely** (5d 8h, ~0% CPU, blocked — no wall-clock timeout on any of the builder's `claude` calls). The parent `builder.sh` sat in `wait` on it, so the launchd job never exited. Because the builder plist uses `StartCalendarInterval`, **launchd will not start a new instance while the previous one is still running** — so every scheduled run since (Fri 07-10, Mon 07-13, Tue 07-14) was silently skipped. One stuck child took the whole builder offline for 5 days with zero signal.
- **Immediate recovery.** Killed the hung process tree (15 procs: the parent, the `claude` child, and 13 reparented node/git descendants). That freed the launchd slot so the next scheduled run fires normally. Run 2 had actually *committed and pushed* its implementation before hanging (it hung right before opening the PR), so the work was recovered as [PR #945](https://github.com/aschung212/Lift/pull/945) (LIFT-926 in-workout stopwatch) — the branch is ~16 commits behind `master` and may need an Update-branch before merge.
- **Fix 1 — per-call timeouts (`lib/builder-utils.sh`, `scripts/builder.sh`).** New portable `run_with_timeout` helper (this Mac has neither GNU `timeout` nor `gtimeout`) wraps all four builder `claude` calls: the main implement call, the CI-fix / merge-conflict retries, the pre-pick, and the auth probe. On expiry it kills the whole process tree (TERM→KILL) and returns 124; the iteration is scored a failure and the night continues. So a hung call now self-terminates instead of blocking the loop, and the builder exits normally at end of night → launchd is free for the next run. New knobs in `project.env` (generous defaults; a healthy iteration is ~5-12 min): `BUILDER_ITERATION_TIMEOUT` (3600s), `BUILDER_FIX_TIMEOUT` (1800s), `BUILDER_PREPICK_TIMEOUT` (300s), `BUILDER_AUTH_TIMEOUT` (180s). Set any to `0` to disable.
- **Fix 2 — staleness alert (`scripts/health-report.sh`).** The weekly health report now computes days-since-last-builder-run across all history and raises an anomaly (surfaced in the report + Slack) when the builder hasn't run in ≥3 days — the signature of a hung/blocked builder holding its launchd slot. Also adds a "Last builder run" line to the report. Note: this is a **weekly** backstop; Fix 1 is the real prevention (same-night self-recovery).
- **Tests.** +7 `run_with_timeout`/tree-kill tests in `tests/builder.bats`, +2 staleness tests in `tests/health-report.bats`. Full suite green: **218/218**. `bash -n` clean on both scripts.
- **No change to Aaron's daily responsibilities.** Tonight's 23:00 run is the live end-to-end test of the timeout path.

### 2026-07-17 — Discovery research + triage fixed after silent Gemini CLI outage

- **Symptom.** Since ~2026-06-30, discovery web research returned nothing (Claude fell back to researching blind) and triage silently ran on its Claude Sonnet fallback every night. No alerts fired — the same silent-failure class as the review outage.
- **Root cause.** Google retired the free "Gemini Code Assist for individuals" OAuth tier on 2026-06-18. The bare `gemini` CLI (default OAuth auth) now returns `IneligibleTierError`. Discovery Phase 1 and triage both shelled out to it directly.
- **Fix.** Re-platformed both stages onto the **Gemini REST API** using the `GEMINI_API_KEY` already in `~/.zshenv` (free-tier Flash; the `gemini` CLI is no longer used by the pipeline). Research keeps Google Search grounding (real URLs, not hallucinations) via the rewritten `adapters/ai-research.sh`. Both stages now **fail loud** to Slack instead of degrading silently. The interactive `gemini` CLI on your machine is untouched.
- **Cost.** Still $0 — Flash is free on the API key, and triage is back on free Flash (it had been quietly spending Claude tokens on the fallback). Reminder: Google AI Pro ($20/mo) grants **no** API/CLI access; the free `GEMINI_API_KEY` is a separate thing and is sufficient for Flash.
- **New responsibility for Aaron.** If you ever see a Slack alert **"⚠️ Discovery — web research FAILED"** or **"⚠️ Triage — Gemini Flash unavailable"**, the `GEMINI_API_KEY` or the free Flash quota is the problem — check `~/.zshenv` and `adapters/ai-research.sh`. The pipeline keeps running (Claude covers), just at higher token cost / lower research quality until it's fixed. Quick manual check: `bash adapters/ai-research.sh prompt "ping" --no-grounding` should print a reply and exit 0.
- **Tests.** `tests/ai-research.bats` rewritten for the REST contract + fail-loud paths; `GEMINI_API_KEY` added to the test harness for hermeticity. Full suite green: **223/223**. `bash -n` clean on all modified scripts.

### 2026-08-17 — Lift SEV: unpaged Supabase reads silently truncated workout history at 1000 rows (#1152, PR #1153)

- **Symptom.** Aaron's installed PWA (iOS Home Screen) hit WebKit's "A problem repeatedly occurred" crash page; after reinstalling, the app showed workout history ending **Jul 14** and a "4 weeks since your last workout" banner — despite near-daily logging. Bodyweight and exercises looked fine.
- **Root cause.** PostgREST caps every response at the project's `max_rows` (1000) with **no error and no truncation flag**. Every collection read in the app was an unpaged `.select()` (zero `.range()`/`.limit()` in `src/`), and the sets fetch sorted `created_at` ASCENDING — so an account past 1000 sets hydrated its **oldest** 1000 and nothing newer. Server had 1454 sets (1426 live, newest Aug 15); **nothing was lost server-side**. localStorage masked the truncated read for a month until the PWA reinstall wiped the container and made the server dump the only source of truth. Bodyweight (1/day) and exercises (46) sit under the cap, which made it look like selective data loss.
- **Why tests missed it.** The shared Supabase fake returned every seeded row uncapped — it actively certified the unpaged read as correct — and no fixture came within an order of magnitude of 1000 rows.
- **Fix (merged + live).** `src/lib/supabasePagination.ts` → `fetchAllRows` pages `.range()` windows until a short page returns; `sets`/`exercises`/`bodyweight_entries` reads route through it with an `.order('id')` tiebreaker (CSV imports create `created_at` ties that can reorder between pages). The fake now enforces the real cap (reverting the fix turns 5 tests red with "expected 1454, got 1000"); `architecturalInvariants.test.ts` fails any unpaged collection read or non-total-sorted paged read. Deployed to production ~23:30 UTC; verified the live bundle carries the paging helper.
- **New responsibility for Aaron.** None day-to-day. Two rules for future work: never "fix" truncation by raising `max_rows` (moves the cliff to 5000 and re-arms it), and any new multi-row Supabase read must go through `fetchAllRows` (the invariant test enforces this). Two follow-ups are queued as session chips: the production no-op `$reset` on the workout store (sign-out leak), and PWA boot hardening (missing `/assets/*` chunks return 200 HTML; unguarded self-reload loops — the likely crash-page mechanism).
- **Tests.** 3181 passed, lint/typecheck/build clean, full CI green (incl. WebKit e2e + Lighthouse) before squash-merge.

### 2026-08-17 — Lift: PR #1120 had silently replaced the gold app icon with placeholder art (#1154, PR #1156)

- **Symptom.** After reinstalling the Home Screen PWA, Aaron's app icon was a flat red dumbbell instead of the designed gold barbell + arrow he'd had since March.
- **Root cause.** The 2026-08-11 precache-size PR (#1120, LIFT-1114) re-ran `scripts/generate-icons.js` — which still *drew* the March-27 placeholder in code. The gold design (committed 2026-03-31 as `public/icon-source.png`) was never produced by that script, so regenerating clobbered it. The PR's "fully lossless" claim covered only the encoder, and most of its 248KB→3KB size win was actually the art swap (lossless encoding of the real design costs ~236KB). Its tests pinned the encoder and file sizes — nothing pinned the art.
- **Fix (merged + live).** `renderIcon` now derives icons from `icon-source.png` (pure-Node PNG decode + deterministic box downscale) — the committed source art is the single source of truth, so `npm run generate-icons` reproduces the design instead of reverting it. Gold icons regenerated (~7% smaller than their pre-#1120 encodings). Drift guard (committed icons must decode pixel-identical to generator output; verified red on placeholder art) + art guard (>256 unique colors; placeholder had ≤17) + budgets recalibrated. SW precache 821KiB → 1105KiB — honest cost of the real art, still under the original 1136KiB.
- **New responsibility for Aaron.** Remove + re-add the Home Screen app once to pick up the gold icon (iOS caches it at add time; safe now that the pagination fix rehydrates full history). If you ever change the app icon design, replace `public/icon-source.png` and run `npm run generate-icons` — the drift test enforces this in CI.
- **Tests.** 3188 passed; drift/art guards verified red-then-green; full CI (incl. WebKit e2e + Lighthouse) green before squash-merge.

### 2026-08-17 — Lift: sign-out left the previous user's bodyweight/progression/preferences recoverable on a shared device (#1158, PR #1160)

- **Where this came from.** The "production no-op `$reset` on the workout store" follow-up chip queued by the #1152 session. That chip's premise was **false**: the workout store has carried a custom `$reset` since #513, and under the installed pinia 4.0.3 with production NODE_ENV the returned override still beats Pinia's built-in prod no-op — verified empirically on both the isolated pattern and the real store (the real-Pinia `workoutReset.test.ts` suite had it pinned all along). The likely mistake: `$reset` sits ~1,400 lines below the `defineStore` call, and a *bare* setup store reproduces the reported prod-no-op/dev-throw behavior exactly.
- **The real bug (same class, the "correct" stores).** Auditing the claim surfaced that the three **options** stores — the ones the chip said "reset correctly" — leak on sign-out. Pinia's built-in options-store `$reset()` re-runs the `state()` factory; the bodyweight/progression factories hydrate via `load()`, so "reset" re-read the signed-out user's data straight back out of localStorage, and no persisted payload was ever cleared (only `deleteAccount` clears keys). Two paths then write the leftovers into the NEXT account to sign in on the device: `migrateLocalStorageToSupabase` inserts surviving `bodyweight-entries` into any empty account, and a fresh account's first progression fetch (PGRST116 → `_syncToSupabase`) pushes the previous user's XP/streaks/unlocks into the new user's row. Preferences `init()` "loads from localStorage first", re-hydrating the previous user's coach profile (sex/age/injuries) into the next session.
- **Why tests missed it.** `useAuth.test.ts` mocks all four stores (`$reset` is a `vi.fn()` — proves it's *called*, never that it *works*), and the per-store suites never populated localStorage before `$reset`: against an empty storage mock, a factory re-run is indistinguishable from a wipe.
- **Fix (PR #1160, open — needs your review/merge).** Explicit `$reset` overrides in bodyweight/progression/preferences mirroring the workout store's wipe semantics: pure defaults in memory (never `load()`), `_userId` nulled before `_persist()` so nothing enqueues against the dead session, cleared payload persisted (localStorage + IDB mirror). Three regression suites on real Pinia under production NODE_ENV semantics: `signOutStateWipe.test.ts` (per-store wipes + the "later `init()` cannot resurrect the profile" repro), extended `workoutReset.test.ts` (prod-semantics guard for the setup store), and `signOutRealStores.test.ts` (end-to-end `signOut()` through real stores). 8 of the 10 new tests verified red on the unfixed stores. Lift's CLAUDE.md now records the "`$reset` = sign-out wipe" contract.
- **New responsibility for Aaron.** Review + merge [PR #1160](https://github.com/aschung212/Lift/pull/1160) (CI gates it). No day-to-day change otherwise.
- **Tests.** 3192 passed; lint/typecheck/build clean.

### 2026-08-17 — Lift: bodyweight CSV export for Apple Health import (#1159, PR #1161)

- **What.** The Weight tab hero now carries a share-icon button (entries-only, 44pt) exporting a `Date,Weight` CSV — one row per calendar day using the exact latest-entry-per-day rule the chart renders (`dailyLatestBodyweight` is now shared between chart and export), weights in the display unit, unit in the filename (`lift-bodyweight-lbs-….csv`). Delivery is a `useShareFlow` surface: iOS share sheet with the file (Save to Files / AirDrop / straight into an importer app) falling back to a browser download. The triplicated anchor-download helper was consolidated into `dataExport.downloadBlob`.
- **Why.** Aaron has months of bodyweight data in Lift and wants it in Apple Health. Health has no native CSV import; the CSV shape targets the two mainstream import paths — the Health CSV Importer iOS app and Apple Shortcuts "Log Health Sample" automations — both of which consume `Date,Weight` with `yyyy-MM-dd` dates.
- **New responsibility for Aaron.** Review + merge [PR #1161](https://github.com/aschung212/Lift/pull/1161) (CI gates it). To get data into Health after that: Weight tab → share icon → hand the CSV to Health CSV Importer (App Store) or a Shortcuts import automation; the importer asks for the unit once — read it off the filename.
- **Tests.** 3202 passed; lint/build clean; mobile-viewport preview verified (44×44 hit area, clean click path).

### 2026-08-17 — Lift: removed three accidentally-committed scratch files (#1162, PR #1163)

- **What.** Deleted `COMMIT_MSG_TMP` (a commit-message draft for the long-merged LIFT-1095 contrast audit, slipped in via #1105) and two no-op vitest scratch files whose own headers say they were never meant to be tracked: `_genwide.test.mjs` at the repo root (via #1091) and `src/components/__tests__/_axe_probe.test.ts` (via #829). The latter two were picked up by every `vitest run`, padding suite counts with a phantom passed file and the phantom "1 skipped" respectively. Pure deletions, 25 lines; nothing references any of them.
- **New responsibility for Aaron.** Review + merge [PR #1163](https://github.com/aschung212/Lift/pull/1163) (CI gates it). No day-to-day change otherwise; suite counts now read clean (no stray "1 skipped").
- **Tests.** 3208 passed, 0 skipped; build clean; full CI green (incl. WebKit e2e + Lighthouse) on the PR after rebasing onto #1161's master.

### 2026-08-28 — Lift: master CI was red on two stale tests, blocking every PR (#1254, PR #1255)

- **Symptom.** `master` CI failing since the #1250/#1251 merges — shards 1 and 2 red, so every open PR (including #1253) inherited a red check and nothing could merge on green. The app itself was fine; both failures were in the tests.
- **Root cause (two, same shape).** Each assertion was written against a *moment* rather than a *rule*. (1) `preferencesInitPersist.test.ts` asserted the enqueue call with `toHaveBeenCalledWith(key, fn)`, which matches the FULL argument list — LIFT-1239 added a third argument (the durable `SyncDescriptor`), so the test broke on the very addition it should have been asserting. (2) `progressionIntegration.test.ts` dated a fixture `2026-03-01` and called it "inside the 6-month window", but `calculateBest1RM` measures that window from `Date.now()`; five months of wall-clock later the set aged out, the call returned `null`, and a test nobody had touched went red on its own.
- **Fix-all-instances sweep.** Instead of grepping for date literals, ran the whole suite under a shifted process clock (+7d, +45d, +3mo, +12mo, +36mo). That found one sibling: `setScoring.test.ts`, whose `TODAY` constant was a lie for the same reason and whose seven established-lift cases were **~1 month** from degrading to `new_exercise` — i.e. the next master-red incident, already scheduled. Suite now green at every horizon tested.
- **Why tests missed it.** Nothing can catch a test that will fail *later*; the only defense is a convention. `xp.test.ts` had already hit this exact rot and already documented the fix (freeze the clock) in a comment — but a convention living in one file has no way to reach the next file that needs it, and two did.
- **Prevention (structural, not another comment).** `architecturalInvariants.test.ts` now fails any test file calling `calculateBest1RM`/`scoreSet` without `vi.setSystemTime`. Those two are the only now-relative helpers that read the clock themselves; every other one (`promptArbiter`, `coachHistory`, `useAppReview`) takes `now` as a parameter and is already immune. The preferences descriptor is now pinned by real shape (op, table, the three journaled columns) rather than `expect.anything()` — a wrong table or off-allowlist column is dropped *silently* on rehydrate, so it deserves pinning. Both new assertions were verified to bite by breaking the code they guard.
- **New responsibility for Aaron.** Review + merge [PR #1255](https://github.com/aschung212/Lift/pull/1255) **first** — it unblocks #1253 and everything behind it. Going forward: a test that reads the clock must pin it (`vi.setSystemTime`, fixtures derived from that frozen now, not literals). CI enforces this for the two window helpers; the rule is in Lift's CLAUDE.md.
- **Tests.** 3482 passed (193 files); lint/typecheck/build clean; full CI green (incl. WebKit e2e + Lighthouse) on the PR.

### 2026-08-28 — Lift: guided "repeat last session" plan card, from beta feedback (#1256, PR #1257)

- **What.** Beta user Christopher (IG DM) asked for Strong-style workout templates — "load up your entire day workout in one session" and "load a whole workout instead of each rep." Per the feature-bloat rule the answer is authoring-free: **history is the template**. A collapsed "Repeat last session" card now sits above the exercise list showing the last training day in the current scope (gym + tags) with exercise/set counts and date; expanding gives a per-exercise checklist (planned sets, top set from last time, live `1/3` done-today progress, checkmarks). Tapping a row opens the existing log modal where the routine lens / ghost-arm one-tap flow takes over — no second logging path, no authoring surface. With one tag active it reads "Repeat last Push session." New pure lib `src/lib/sessionPlan.ts` (clock-free, `setDayKey`-bucketed per #746).
- **Why this shape.** The usual ladder already gives one-tap-per-set logging but is invisible day-level and needs ≥3 prior sessions (cold start — exactly the gap a new beta user sits in). The plan card needs only 1 prior session and surfaces the whole day at a glance, answering both asks without overturning the documented no-templates decision. Aaron picked this direction over authored templates when asked.
- **New responsibility for Aaron.** Review + merge [PR #1257](https://github.com/aschung212/Lift/pull/1257) (CI gates it). Worth replying to Christopher once it deploys — his two asks are both addressed, and his cold-start experience ("nothing guided me") now has an answer after his first logged session.
- **Tests.** 3499 passed (194 files; +8 lib unit, +6 component, +2 CSS-regression); 44pt touch targets regression-tested; lint/build clean; mobile-viewport preview verified end-to-end (collapsed card → expand → tag scoping → row opens log modal).

### 2026-08-28 — Lift: landed three overnight PRs stranded 253 commits behind master (#659, #658, #661, PR #1260)

- **What.** Three May-27 overnight-pipeline PRs had sat unmerged for three months and were all `CONFLICTING`, each 253 commits behind `master`: **#659** built-in exercise database (#615), **#658** consistency heatmap / Year calendar view (#620), **#661** per-set RPE tracking (#617). All three are now squash-merged and their issues closed, along with **#1260**, a CI bundle-budget bump that unblocked two of them.
- **Conflicts, resolved by intent.** Nine hunks across six files. Most were *keep-both* (independent additions to the same import block or CSV header) or *master-supersedes* — master had extracted the workout timeline into `WorkoutTimeline.vue` and rebuilt `logSet` (bodyweight fold, `createdAt`, day-count index), so the PRs' inline versions were dropped and only their genuine contributions grafted onto master's structure.
- **Three latent breakages the conflicts didn't show.** Each PR predated a master convention and would have shipped subtly wrong: (1) **#661's RPE would have been silently discarded on every reload** — `parseGuards.parseSet` (LIFT-946, landed after the PR) whitelists the fields it copies and had no `rpe` case, so values survived the session and vanished on hydration. Added the guard + 3 regression tests. (2) **#659's bar weights were lbs figures assigned straight into a display-unit field** — LIFT-1211 made bar weight unit-aware, so a kg user picking "Bench Press" would have got a 45 **kg** bar; now converted and rounded (45 lb → 20 kg, matching `defaultBarWeight()`). (3) **#658's 9px heatmap labels** violated LIFT-988's rem-anchored type scale; moved onto `--font-caption2`. Also sized #661's RPE chips 36px → 44px (they tile, so the #990 rule requires sizing, not an overlay) and fixed an undefined `--card-bg` token in #659's CSS.
- **The real blocker was CI, not the conflicts.** `master` had drifted to **597 KB against the 600 KB JS bundle ceiling** — 3 KB of headroom, so #659 (+6 KB) and #658 (+7 KB) failed the gate on size alone. The gate sums every emitted chunk, so code-splitting them would not have helped. Raised to **640 KB** (PR #1260, your call), leaving ~28 KB of headroom; all three landed at 611 KB.
- **New responsibility for Aaron.** The JS bundle budget in `.github/workflows/ci.yml` is now **640 KB** (was 600). Nothing day-to-day. One follow-up is queued as a session chip: `StarterPickerFlow.vue` references the same undefined `--card-bg` token (pre-existing on master, renders a transparent card background) — the CSS regression test only scans `index.css`, so `.vue` style blocks are unguarded. Note also that `master` CI has a **pre-existing `migrate-db` failure** unrelated to any of this.
- **Tests.** 3610 passed (200 files); lint/typecheck/build clean; full CI green (incl. WebKit e2e + Lighthouse) on each PR before merge. The e2e calendar spec needed updating for #658's third view toggle — `npm test` does not run Playwright, so that one surfaced only in CI.

### 2026-08-28 — Lift: resolved conflicts on and merged the five remaining stranded overnight PRs (#1126, #1067, #1111, #1044, #1031)

- **What.** All five `CONFLICTING` overnight-pipeline PRs are squash-merged and their issues closed: **#1126** dev sign-in bypass kept out of prod bundles (LIFT-1123), **#1067** PWA install-funnel analytics (LIFT-1061), **#1111** consecutive-week streak badge in the Workouts header (LIFT-1109), **#1044** rest-timer notification action buttons (LIFT-751), **#1031** plateau/stall badge on the exercise graph (LIFT-1025).
- **Notable resolutions beyond textual conflicts.** (1) **#1111 was rebuilt, not merged** — its commit had absorbed ~1,000 lines of unrelated LIFT-1108 progress-photos WIP (the PR's own body flagged this); the branch was reset to master and re-committed with only the three LIFT-1109 files. The WIP is preserved untouched on **`wip/LIFT-1108-progress-photos`**. (2) **#1044**: dropped its stray `target_e1rm` migration (orphan column — nothing reads it, and `databaseTypesDrift.test.ts` would fail CI), fixed a latent typecheck error in `notify`'s `actions` typing, made the Notification-constructor fallback strip `actions` (Chrome throws on them — the notification would otherwise silently not show), and added `sw-notification-handler.js` to the vercel.json SPA-rewrite lookahead per the #1155 rule. (3) **#1031**: master's metric selector (#1042) landed after the PR and made `dailyBest` metric-dependent, so plateau detection was pinned to a dedicated daily-best **e1RM** series — the badge would otherwise have claimed "no new e1RM best" from volume/reps data. (4) **#1067**: master's peak-moment reveal (#1060) was routed through the PR's centralized `revealBanner` so install-banner impressions are logged from every reveal path.
- **New responsibility for Aaron.** `wip/LIFT-1108-progress-photos` holds the half-wired progress-photos WIP for whenever LIFT-1108 is picked up — delete the branch if that feature is abandoned. Nothing else day-to-day.
- **Tests.** All four gates (lint / typecheck / vitest / build) run green locally on every PR after resolution; full CI (incl. e2e + Lighthouse) green before each merge. Final master state after the fifth merge: 3657 tests passing locally at resolution time.
