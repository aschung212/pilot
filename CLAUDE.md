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

## Issue Tracking
Lift uses GitHub Issues (`gh` CLI). Issue IDs use `LIFT-XXX` format via the `ISSUE_PREFIX` env var.
Other projects (Technical Prep, Applications, AI Competency) use Linear (`linear` CLI).
The `tracker.sh` adapter routes automatically based on project name or issue ID prefix.

## Adapter Pattern
All external tools are accessed through adapters in `adapters/`:
- `tracker.sh` — issue tracking (GitHub Issues + Linear dual-backend)
- `notify.sh` — Slack notifications (webhooks + Bot API)
- `ai-code.sh` — code generation (Claude)
- `ai-research.sh` — web research (Gemini REST API)

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
- `lift-stale-pr-audit-YYYY-MM-DD.md` — stale-PR audit report (on-demand, not nightly)
