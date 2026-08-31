# Pilot — Claude Guidelines

## About This Project
Pilot is an autonomous multi-agent pipeline that discovers, triages, implements, and reviews improvements to the Lift workout tracker. It runs overnight via launchd, creating PRs that Aaron reviews in the morning.

**Repo:** github.com/aschung212/pilot
**Target project:** github.com/aschung212/Lift
**Slack channels:** #lift-automation, #daily-review, #pilot
**Runtime data:** pilot/data/ (gitignored)

## Documentation Mandate

Documentation is a first-class deliverable, not an afterthought. Every change to pipeline logic, adapters, scripts, scheduling, or configuration MUST include corresponding documentation updates in the SAME commit or PR. Do not create follow-up tasks for documentation — do it now.

**Documentation surface area:**
- `README.md` — project overview, quick start, architecture summary
- `CLAUDE.md` — this file, guidelines for Claude sessions working on this repo
- `init.sh` — interactive setup wizard (this IS documentation — keep prompts, options, and defaults current)
- `project.env.example` — annotated example config (keep in sync with init.sh and project.env)
- `docs/pilot-responsibilities.md` — what Aaron does vs. what's automated, changelog
- `docs/pilot-architecture.md` — pipeline stages, data flow, scheduling, adapters

**When you change:**
- A script's behavior → update the architecture doc and README if the change is user-visible
- An adapter's interface → update the adapter contract description in architecture doc
- A new focus area, model, or schedule → update init.sh options, architecture doc, and responsibilities doc
- Environment variables → update project.env.example and init.sh
- The data directory structure → update architecture doc

**Changelog:** Append to the changelog in `docs/pilot-responsibilities.md` for every significant change. Include the date and what changed.

**Drift check:** `scripts/doc-drift-audit.sh` verifies the docs against the repo mechanically — undocumented scripts/adapters/env vars, dead references, plists missing from the schedule tables, stale test counts, and broken Obsidian vault paths. It runs biweekly, but run it by hand after any structural change; it is a reporter, never an editor. Changelog sections and deliberate tombstones ("the old `x.sh` was deleted 2026-07-17") are exempt by design.

## Issue Tracking
Lift uses GitHub Issues (`gh` CLI). Issue IDs use `LIFT-XXX` format via the `ISSUE_PREFIX` env var.
Other projects (Technical Prep, Applications, AI Competency) use Linear (`linear` CLI).
The `tracker.sh` adapter routes automatically based on project name or issue ID prefix.

## Adapter Pattern
All external tools are accessed through adapters in `adapters/`:
- `tracker.sh` — issue tracking (GitHub Issues + Linear dual-backend)
- `notify.sh` — Slack notifications (webhooks + Bot API)
- `ai-code.sh` — code generation (Claude)
- `ai-research.sh` — web research (two backends: Claude `WebSearch` or Gemini REST API; `--backend`)

Adversarial code review is **not** an adapter — it runs inline via
`~/.claude/scripts/review-router.sh` (headless `claude -p`) as a PostToolUse hook.
The old `adapters/ai-review.sh` was deleted 2026-07-17; see the changelog.

Never call external tools directly from scripts — always go through the adapter. This enables swapping backends without touching every script.

## Code Standards
- All scripts must pass `bash -n` syntax check
- Use `set -uo pipefail` (not `-e` for scripts with expected failures)
- Source `project.env` and `lib/log.sh` at the top of every script
- Guard env sourcing with `[ -z "${_PILOT_TEST_MODE:-}" ]` for testability
- Use `$TRACKER` adapter for all issue operations, `$NOTIFY` for all Slack operations
- Use `${ISSUE_PREFIX}-[0-9]+` pattern (not hardcoded `MAS-` or `LIFT-`) for issue ID matching

## Known Builder Failure Modes

These have happened in production. Watch for them:

- **Hallucinated values.** The builder fabricated `liftracker.app` as our deployment URL. Any URL, domain, or external identifier in a diff MUST be verified against an authoritative source (CLAUDE.md, package.json, git remote). The Lift CLAUDE.md has a SEV1 rule about this.
- **Stale worktree branches.** `git branch --list` prefixes worktree branches with `+`, which broke `git push`. Always strip `+`, `*`, and spaces from branch name output.
- **Detached HEAD from lint-staged.** The pre-commit hook's stash/unstash can detach HEAD. After committing, verify `git branch --show-current` returns a branch name. If empty, cherry-pick onto the correct branch.
- **Daytime time check.** The builder's `should_continue` function treats morning hours as "past stop time" for overnight mode. Daytime manual runs must use an explicit iteration count (`builder.sh N`).
- **`grep -c` with pipes.** Returns trailing whitespace/newlines that break arithmetic comparisons. Always `tr -d ' \n'` before using in `[ ]` tests.
- **Marker separators the prompt asks for vs. the ones the agent emits.** The builder prompt documents `ISSUE_DONE:LIFT-N|summary`, but the agent has only ever emitted the colon form. Four parsers required the pipe and were dead code for the life of the repo — silently costing the `state:started` flip, the completion comment, the PR title, and the digest links. When you add a marker parser, accept every separator seen in `data/lift-enhance-*.md` (`_marker_lines` in `builder-utils.sh` does this) and never assume the prompt's format is the observed format.
- **Silent `gh` list truncation.** `gh issue list --limit N` returns a short list with no error when there are more than N. A cap below the real open-issue count removes issues from the builder's picking pool and from triage with no visible symptom. This has bitten twice (100 → 200 in 2026-07, 200 → 1000 in 2026-08). Open-issue queries share `GH_OPEN_LIMIT`; keep it well above the issue count and heed the at-cap warning.
- **Heredoc args after the terminator.** `python3 << 'EOF'` … `EOF` followed by `"$A" "$B")` on the next line does NOT pass arguments — the args become a separate command, and bash tries to *execute* the first one (exit 126, "Permission denied" on a data file). Positional args must be on the redirect line: `python3 - "$A" "$B" << 'EOF'`. This left `tune-budget.sh` completely inert from inception to 2026-08-28.
- **`int(row.get('x', 0))` on csv.DictReader.** A short row fills missing columns with `None`, so the key *exists* and the `get` default never applies — `int(None)` raises. Use `int(row.get('x') or 0)`. `lift-metrics.csv` has 30 such rows.
- **Bun preamble in `claude --output-format json` output.** Bun prints `warn: CPU lacks AVX support …` on this machine, so a captured stream is not valid JSON at line 1. Scan for the first line starting with `{` rather than `json.load()`-ing the whole file, and strip a leading ```json fence off the inner `result`. This broke every pre-pick on 2026-05-19 and every `roadmap-synth` run for 17 consecutive weeks.
- **Tests that re-implement the logic they test.** `tune-budget.bats` had five green tests while the script had never once worked, because each test pasted the Python into the test file instead of running the script. Prefer driving the real script end-to-end; a unit test over a copy proves nothing about the copy's original.
- **A detector that reports instead of acting.** `cleanup.sh` step 2 classified "state:started issue whose PR already merged" correctly from the day it was written, then `continue`d with a comment deferring to "the close path". There was no close path: step 1's `tracker.sh list completed` runs `gh issue list --state closed`, so it can only re-close what is already closed. Meanwhile the builder prompt asked the agent for a `Closes #N` commit body that the agent never once wrote. Three mechanisms, each assuming one of the others closed the issue, and nothing did for the life of the GitHub backend — visible only as a nightly "📋 N issue(s) still state:started with a MERGED PR" line that reached 150 and was documented as expected behaviour. When you write a counter for a condition nobody acts on, name the thing that is supposed to act on it and go read it.
- **`gh issue close --reason not_planned` is invalid.** gh accepts exactly `{completed|not planned}` and **errors before closing** — it does not close and then complain. Every caller in this repo spelled it `not_planned` (the Linear enum `tracker.sh` grew out of), so cleanup's dedupe and backlog-expiry closes were silent no-ops while their counters incremented and the summary reported success. `gh_close` normalizes both spellings now. The general lesson is the `✓ Closed` that printed unconditionally after a `>/dev/null 2>&1` call: never report success you did not check.
- **`gh pr list` truncates as silently as `gh issue list`.** The `--limit 500` in `cleanup.sh` was below the repo's 558 merged / 687 total PRs, so the oldest PRs were invisible — and an issue whose only PR fell off the end reads as "no PR ever" and gets **recycled**, rebuilding work that already shipped. PR queries share `GH_PR_LIMIT`, the way open-issue queries share `GH_OPEN_LIMIT`. Both warn at the cap; heed the warning rather than discovering it after something is rebuilt.
- **Dedupe keyed only on issue identity.** Discovery's do-not-duplicate lists, the builder's picking-time filter, the pre-PR guard, and the auditor's collision detector all ask "does *this issue* already have a PR?" None of them can see work rebuilt under a *different* issue number — which is exactly how LIFT-1039 duplicated LIFT-783. When work can be re-identified (splits, rescopes, manual re-files), the ground truth is the PR set and the codebase, not the issue ID.

## Infrastructure Change Protocol

Before making changes to the pipeline infrastructure (tracker migration, data directory moves, adapter rewrites):

1. **Stop the builder** — kill the overnight loop process, let the current Claude session finish
2. **Make all changes** — scripts, config, adapters, env vars
3. **Syntax check every modified script** — `bash -n <file>`
4. **Dry run each affected script** — `digest.sh --dry-run`, `cleanup.sh --dry-run`, etc.
5. **Run one builder iteration** — `builder.sh 1` to verify end-to-end
6. **Re-enable the builder** — restart launchd services

Never make pipeline changes while the builder is running. It will read a mix of old and new state.

## Runtime Data
All logs, metrics, queues, and outputs live in `pilot/data/` (gitignored). Key files:
- `lift-discovery-queue.txt` — discovery focus area rotation
- `lift-usage-tracking.csv` — token usage per run
- `lift-metrics.csv` — builder iteration metrics
- `lift-enhance-YYYY-MM-DD-runN.md` — per-iteration build logs
- `lift-discover-YYYY-MM-DD.md` — discovery run logs
- `lift-discover-YYYY-MM-DD-research.md` — Phase 1 web research, whichever backend produced it
  (files before 2026-08-30 are named `-gemini-research.md`, from when Gemini was the only backend)
- `lift-stale-pr-audit-YYYY-MM-DD.md` — stale-PR audit report (weekly, Sun 08:15)
- `lift-claim-manual-YYYY-MM-DD.md` — hand-filed issues promoted to top priority (pre-step of triage and the builder)
- `lift-doc-drift-YYYY-MM-DD.md` — doc-drift audit report (biweekly, Sun 09:00)
- `lift-build-learnings.md` — Aaron's closing comments on rejected (closed-unmerged) PRs; harvested by cleanup.sh, injected into the builder prompt
- `lift-needs-decision.txt` — nightly snapshot of rejected-PR issues awaiting Aaron's decision; read by digest.sh
