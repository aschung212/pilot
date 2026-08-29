#!/bin/bash
# Pipeline Auditor — self-reflective Synthesiser/Critic agent.
# Reads the past N days (default 7) of pipeline data, detects regressions
# against expected behavior, classifies them P1/P2/P3, and emits findings.
#
# Why this exists: 04-22 → 04-29 the builder's ISSUE_DONE marker rate
# decayed 75% → 0% as Opus 4.6 started delegating iterations to subagents.
# The parent's num_turns dropped to 1 with output_tokens<100 while real
# work hid in modelUsage. Aaron caught it on day 7 manually. The Auditor's
# job is to catch this kind of drift on day 2.
#
# Usage:
#   ./pipeline-auditor.sh             # audit last 7 days
#   ./pipeline-auditor.sh --days 14   # audit last 14 days
#   ./pipeline-auditor.sh --dry-run   # don't post Slack or create issues
#
# Outputs (in priority order):
#   1. Slack digest to #pilot via `changelog` channel (deployed agent only)
#   2. GitHub issues against aschung212/pilot for P1 findings (idempotent)
#   3. Audit log: data/pilot-audit-YYYY-MM-DD.md (markdown)
#   4. Audit history: data/pilot-audit-history.csv (one row per finding)

set -uo pipefail
# Note: not using -e — individual analyses should not abort the whole audit.

# ── Bootstrap (mirrors builder.sh / health-report.sh pattern) ───────────────
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/auditor-utils.sh"
LOG_COMPONENT="auditor"

# ── Args ────────────────────────────────────────────────────────────────────
DAYS=7
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --days)    DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *)         shift ;;
  esac
done
# Validate --days is a positive integer
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
  echo "❌ Invalid --days value: $DAYS (must be a positive integer)" >&2
  exit 1
fi

# ── Paths ───────────────────────────────────────────────────────────────────
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
DATE=$(date +%Y-%m-%d)
USAGE_CSV="$OUTPUT_DIR/lift-usage-tracking.csv"
METRICS_CSV="$OUTPUT_DIR/lift-metrics.csv"
TUNE_LOG="$OUTPUT_DIR/lift-tune-log.csv"
AUDIT_REPORT="$OUTPUT_DIR/pilot-audit-$DATE.md"
AUDIT_HISTORY="$OUTPUT_DIR/pilot-audit-history.csv"
ISSUE_PREFIX="${ISSUE_PREFIX:-LIFT}"
GITHUB_REPO_LIFT="${GITHUB_REPO:-aschung212/Lift}"
PILOT_REPO="aschung212/pilot"

mkdir -p "$OUTPUT_DIR"
ensure_audit_history "$AUDIT_HISTORY"
[ "${_PILOT_TEST_MODE:-}" = "1" ] || ensure_audit_labels "$PILOT_REPO"

log_info "Pipeline Auditor starting — window: ${DAYS} days, dry_run=${DRY_RUN}"
echo "🔍 Pipeline Auditor — $DATE (last ${DAYS} days)"

# ── PR data (best-effort) ────────────────────────────────────────────────────
# We pull both "open" and "all states past N days" so we can compute time-to-merge,
# duplicate-PR detection, and ci:failed retry loops.
PR_JSON_OPEN="$OUTPUT_DIR/.pilot-audit-prs-open.json"
PR_JSON_RECENT="$OUTPUT_DIR/.pilot-audit-prs-recent.json"
if [ "${_PILOT_TEST_MODE:-}" = "1" ]; then
  # In test mode, fixtures may be pre-staged; skip live gh calls.
  [ -f "$PR_JSON_OPEN" ]   || echo "[]" > "$PR_JSON_OPEN"
  [ -f "$PR_JSON_RECENT" ] || echo "[]" > "$PR_JSON_RECENT"
else
  gh pr list --repo "$GITHUB_REPO_LIFT" --state open --limit 100 \
    --json number,title,createdAt,labels,headRefName,author \
    > "$PR_JSON_OPEN" 2>/dev/null || echo "[]" > "$PR_JSON_OPEN"
  gh pr list --repo "$GITHUB_REPO_LIFT" --state all --limit 200 \
    --json number,title,createdAt,mergedAt,closedAt,state,labels,headRefName,author \
    > "$PR_JSON_RECENT" 2>/dev/null || echo "[]" > "$PR_JSON_RECENT"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Deterministic anomaly detection (Python — bash math is too brittle here)
# ══════════════════════════════════════════════════════════════════════════════
# All eight detectors run inside one Python invocation so we can share parsed
# state. Each detector emits a finding dict; we collect them into a JSON array
# on stdout, which the bash wrapper then iterates and routes (Slack, gh issue,
# history CSV).
FINDINGS_JSON=$(
  ISSUE_PREFIX="$ISSUE_PREFIX" \
  USAGE_CSV="$USAGE_CSV" \
  METRICS_CSV="$METRICS_CSV" \
  PR_JSON_OPEN="$PR_JSON_OPEN" \
  PR_JSON_RECENT="$PR_JSON_RECENT" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  AUDIT_DAYS="$DAYS" \
  python3 << 'PYEOF'
import csv, glob, json, os, re, sys
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone

prefix      = os.environ.get("ISSUE_PREFIX", "LIFT")
usage_csv   = os.environ["USAGE_CSV"]
metrics_csv = os.environ["METRICS_CSV"]
pr_open     = os.environ["PR_JSON_OPEN"]
pr_recent   = os.environ["PR_JSON_RECENT"]
output_dir  = os.environ["OUTPUT_DIR"]
days        = int(os.environ.get("AUDIT_DAYS", "7"))

today      = datetime.now().date()
window_lo  = today - timedelta(days=days)
# "Prior week" reference for week-over-week comparisons.
prior_lo   = today - timedelta(days=days * 2)
prior_hi   = window_lo - timedelta(days=1)

def safe_int(v, default=0):
    try: return int(v)
    except (TypeError, ValueError):
        try: return int(float(v))
        except (TypeError, ValueError): return default

def safe_float(v, default=0.0):
    try: return float(v)
    except (TypeError, ValueError): return default

def parse_date(s):
    try: return datetime.strptime(s, "%Y-%m-%d").date()
    except (TypeError, ValueError): return None

def in_window(d, lo, hi=None):
    """d is a date; lo/hi are dates inclusive."""
    if d is None: return False
    if hi is None: hi = today
    return lo <= d <= hi

def read_csv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

# ── Load enhance-output JSONs in window for num_turns analysis ──────────────
enhance_jsons = []
for path in sorted(glob.glob(f"{output_dir}/lift-enhance-*-output.json")):
    m = re.search(r"lift-enhance-(\d{4}-\d{2}-\d{2})-run(\d+)-output\.json", os.path.basename(path))
    if not m: continue
    d = parse_date(m.group(1))
    if d is None: continue
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        continue
    enhance_jsons.append({
        "date": d,
        "run": safe_int(m.group(2)),
        "path": path,
        "num_turns": safe_int(data.get("num_turns", 0)),
        "output_tokens": safe_int((data.get("usage") or {}).get("output_tokens", 0)),
        "total_cost_usd": safe_float(data.get("total_cost_usd", 0)),
        "model_usage": data.get("modelUsage") or {},
        "result_text": data.get("result", "") or "",
    })

# Load enhance markdown logs (ISSUE_DONE markers + review-finding density)
def load_md(path):
    try:
        with open(path) as f: return f.read()
    except OSError: return ""

enhance_mds = []
for path in sorted(glob.glob(f"{output_dir}/lift-enhance-*-run*.md")):
    m = re.search(r"lift-enhance-(\d{4}-\d{2}-\d{2})-run(\d+)\.md", os.path.basename(path))
    if not m: continue
    d = parse_date(m.group(1))
    if d is None: continue
    body = load_md(path)
    enhance_mds.append({
        "date": d,
        "run": safe_int(m.group(2)),
        "path": path,
        "body": body,
        "issue_done_count": len(re.findall(rf"^ISSUE_DONE:{prefix}-\d+", body, re.M)),
    })

# ── Detector 1: ISSUE_DONE marker emission collapse, week over week ─────────
# Per-day rate = runs that emitted ≥1 ISSUE_DONE / total runs that day.
# Then compare current window mean vs prior window mean.
findings = []

def marker_rate(rows):
    by_day = defaultdict(lambda: {"runs": 0, "with_marker": 0})
    for r in rows:
        d = r["date"]
        by_day[d]["runs"] += 1
        if r["issue_done_count"] > 0:
            by_day[d]["with_marker"] += 1
    if not by_day:
        return None, 0
    pcts = [v["with_marker"] / v["runs"] * 100 for v in by_day.values() if v["runs"] > 0]
    if not pcts:
        return None, 0
    return sum(pcts) / len(pcts), sum(v["runs"] for v in by_day.values())

cur_rows   = [r for r in enhance_mds if in_window(r["date"], window_lo)]
prior_rows = [r for r in enhance_mds if in_window(r["date"], prior_lo, prior_hi)]
cur_pct,   cur_n   = marker_rate(cur_rows)
prior_pct, prior_n = marker_rate(prior_rows)

if cur_pct is not None and prior_pct is not None and cur_n >= 3 and prior_n >= 3:
    delta_pp = prior_pct - cur_pct  # positive = drop in current week
    if delta_pp >= 10:  # 10pp drop → at minimum P3
        findings.append({
            "id": "marker_emission_collapse",
            "metric": "marker_emission_pct",
            "title": f"ISSUE_DONE marker emission dropped {prior_pct:.0f}% → {cur_pct:.0f}%",
            "metric_value": round(cur_pct, 1),
            "prior_value": round(prior_pct, 1),
            "delta": round(delta_pp, 1),
            "summary": (
                f"Builder runs that emitted at least one ISSUE_DONE marker fell from "
                f"{prior_pct:.0f}% (prior window, n={prior_n}) to {cur_pct:.0f}% (current "
                f"window, n={cur_n}). Two distinct failure modes can drive this: "
                f"(a) subagent delegation (parent calls haiku/sonnet) — see "
                f"`subagent_delegation` finding if present; (b) early-exit (parent "
                f"does the work itself but exits with a one-liner instead of emitting "
                f"the structured response) — see `early_exit_no_markers` finding if "
                f"present. Check those companion findings before remediating."
            ),
            "remediation": (
                "Cross-reference with the subagent_delegation and early_exit_no_markers "
                "findings (also emitted by this auditor). If subagent_delegation fires, "
                "verify --disallowedTools blocks Task/Agent in scripts/builder.sh. If "
                "early_exit_no_markers fires, the prompt fix is in scripts/builder.sh "
                "Step 4 (require structured response before exit) and Rules (forbid "
                "backgrounded git operations)."
            ),
            "evidence_files": sorted({r["path"] for r in cur_rows[-5:]}),
        })

# ── Detector 2: num_turns=1 with tiny parent output ──────────────────────────
# Two distinct failure modes share this top-level signature; we split them by
# inspecting modelUsage so the remediation actually matches the cause.
#
#   (a) DELEGATION   — parent calls a subagent (haiku/sonnet appears in
#                      modelUsage). Real work hides in the subagent. Fix:
#                      tighten --disallowedTools or pin model.
#                      Example: 2026-04-29 runs (12 with haiku usage).
#
#   (b) EARLY-EXIT   — opus is the only model in modelUsage AND opus
#                      outputTokens are large (≥500). The parent did the work
#                      itself but exited with a one-liner instead of emitting
#                      the structured ## Issue updates block. Fix: prompt
#                      change requiring structured response before exit.
#                      Example: 2026-05-04..05 runs (background-task pattern).
#
# Lumping these as "delegation" (which the original detector did) led to the
# 2026-05-06 misdiagnosis — the haiku problem had been fixed weeks earlier
# but the symptom looked the same from top-level usage stats.
PARENT_MODELS = ("opus",)  # parent model family — anything else in modelUsage = subagent
def _is_subagent_model(name: str) -> bool:
    n = (name or "").lower()
    return ("haiku" in n) or ("sonnet" in n)
def _max_parent_out(mu: dict) -> int:
    if not mu: return 0
    out = 0
    for k, v in mu.items():
        if any(p in (k or "").lower() for p in PARENT_MODELS):
            out = max(out, safe_int((v or {}).get("outputTokens", 0)))
    return out

cur_window  = [j for j in enhance_jsons if in_window(j["date"], window_lo)]
prior_window = [j for j in enhance_jsons if in_window(j["date"], prior_lo, prior_hi)]

def _split_nt1(rows):
    """Return (delegated, early_exit) lists for nt==1, parent_out<100 rows."""
    suspects = [j for j in rows if j["num_turns"] == 1 and j["output_tokens"] < 100]
    delegated, early_exit = [], []
    for j in suspects:
        mu = j["model_usage"] or {}
        has_subagent = any(_is_subagent_model(k) for k in mu.keys())
        opus_out = _max_parent_out(mu)
        if has_subagent:
            delegated.append(j)
        elif opus_out >= 500:
            # Real implementation work happened, but parent exited tiny.
            early_exit.append(j)
        else:
            # Genuinely a no-op turn (e.g. agent decided "nothing to do").
            # Don't classify as either failure mode.
            pass
    return delegated, early_exit

cur_delegated, cur_early = _split_nt1(cur_window)
prior_delegated, prior_early = _split_nt1(prior_window)

# (a) Delegation finding ─ only fires if subagents are actually visible.
if cur_window and len(cur_delegated) >= 2 and (100.0 * len(cur_delegated) / len(cur_window)) >= 10:
    cur_pct = 100.0 * len(cur_delegated) / len(cur_window)
    prior_pct = (100.0 * len(prior_delegated) / len(prior_window)) if prior_window else 0
    examples = [{
        "date": j["date"].isoformat(),
        "run": j["run"],
        "parent_out": j["output_tokens"],
        "model_usage": {k: v.get("outputTokens", 0) for k, v in (j["model_usage"] or {}).items()},
    } for j in cur_delegated[:5]]
    findings.append({
        "id": "subagent_delegation",
        "metric": "subagent_delegation_pct",
        "title": f"Subagent delegation in {cur_pct:.0f}% of runs (haiku/sonnet in modelUsage)",
        "metric_value": round(cur_pct, 1),
        "prior_value": round(prior_pct, 1),
        "delta": round(cur_pct, 1),
        "summary": (
            f"{len(cur_delegated)}/{len(cur_window)} runs in the current window have "
            f"parent num_turns=1, parent output<100, AND a subagent model (haiku/sonnet) "
            f"present in modelUsage. The real work is happening inside the subagent — "
            f"the builder's ISSUE_DONE markers, which the parent emits, get lost."
        ),
        "remediation": (
            "Verify --disallowedTools includes Task,Agent in scripts/builder.sh "
            "(BUILDER_DISALLOWED_TOOLS). If it already does, the subagent is being "
            "invoked through a path that isn't blocked — pin to a model without "
            "auto-delegation behavior, or constrain --allowedTools further."
        ),
        "evidence_examples": examples,
    })

# (b) Early-exit finding ─ opus-only, real work done, exited without markers.
if cur_window and len(cur_early) >= 2 and (100.0 * len(cur_early) / len(cur_window)) >= 10:
    cur_pct = 100.0 * len(cur_early) / len(cur_window)
    prior_pct = (100.0 * len(prior_early) / len(prior_window)) if prior_window else 0
    examples = [{
        "date": j["date"].isoformat(),
        "run": j["run"],
        "parent_out": j["output_tokens"],
        "opus_out": _max_parent_out(j["model_usage"] or {}),
        "result_tail": (j.get("result_text") or "")[-160:],
    } for j in cur_early[:5]]
    findings.append({
        "id": "early_exit_no_markers",
        "metric": "early_exit_pct",
        "title": f"Early-exit without markers in {cur_pct:.0f}% of runs",
        "metric_value": round(cur_pct, 1),
        "prior_value": round(prior_pct, 1),
        "delta": round(cur_pct, 1),
        "summary": (
            f"{len(cur_early)}/{len(cur_window)} runs in the current window have "
            f"parent num_turns=1, parent output<100, opus-only modelUsage, AND opus "
            f"output ≥500 tokens. The parent did the real work itself but exited with "
            f"a chatty one-liner instead of emitting the structured ## Issue updates block. "
            f"Common signal: result text ends with phrases like 'background task completed' "
            f"or 'pipeline will handle PR creation'."
        ),
        "remediation": (
            "Builder prompt change: require the structured response (Plan / Changes / "
            "Issue updates / Verification / Screenshots / Summary) BEFORE exit, and "
            "forbid backgrounding git operations (background-task completion is what "
            "triggers the early exit). See scripts/builder.sh Step 4 + Rules."
        ),
        "evidence_examples": examples,
    })

# ── Detector 3: Cost-per-merged-PR drift, week over week ────────────────────
# Sum total_cost_usd across enhance JSONs, divide by merged PRs in same window.
recent_prs = load_json(pr_recent)

def parse_iso(ts):
    if not ts: return None
    try: return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (TypeError, ValueError): return None

merged_in_window = [pr for pr in recent_prs
                    if pr.get("mergedAt") and parse_iso(pr["mergedAt"])
                    and parse_iso(pr["mergedAt"]).date() >= window_lo]
merged_in_prior  = [pr for pr in recent_prs
                    if pr.get("mergedAt") and parse_iso(pr["mergedAt"])
                    and prior_lo <= parse_iso(pr["mergedAt"]).date() <= prior_hi]

def total_cost(rows):
    return sum(j["total_cost_usd"] for j in rows)

cost_cur   = total_cost([j for j in enhance_jsons if in_window(j["date"], window_lo)])
cost_prior = total_cost([j for j in enhance_jsons if in_window(j["date"], prior_lo, prior_hi)])
cpp_cur    = (cost_cur   / len(merged_in_window)) if merged_in_window else 0
cpp_prior  = (cost_prior / len(merged_in_prior))  if merged_in_prior  else 0

if cpp_prior > 0 and cpp_cur > 0:
    drift_pct = ((cpp_cur - cpp_prior) / cpp_prior) * 100
    if drift_pct >= 25:
        findings.append({
            "id": "cost_per_pr_drift",
            "metric": "cost_per_pr_drift_pct",
            "title": f"Cost-per-merged-PR up {drift_pct:.0f}% (${cpp_prior:.2f} → ${cpp_cur:.2f})",
            "metric_value": round(cpp_cur, 2),
            "prior_value": round(cpp_prior, 2),
            "delta": round(drift_pct, 1),
            "summary": (
                f"Total Claude spend across enhance runs: ${cost_cur:.2f} this window "
                f"vs ${cost_prior:.2f} prior. Merged PRs: {len(merged_in_window)} vs "
                f"{len(merged_in_prior)} prior. Cost-per-PR drifted "
                f"${cpp_prior:.2f} → ${cpp_cur:.2f} ({drift_pct:+.0f}%)."
            ),
            "remediation": (
                "Possible causes: model upgrade with higher per-token cost, prompt "
                "bloat (review prior_summaries growth), more retries via subagent "
                "delegation, or merge rate dropping while spend stays constant. "
                "Cross-reference with the num_turns=1 finding if both fired."
            ),
        })

# ── Detector 4: Duplicate PRs (open) ─────────────────────────────────────────
# Group open PRs by issue number found in title; flag any group of size >= 2.
open_prs = load_json(pr_open)
by_issue = defaultdict(list)
for pr in open_prs:
    title = pr.get("title", "") or ""
    nums  = re.findall(rf"#(\d+)|{prefix}-(\d+)", title)
    seen = set()
    for a, b in nums:
        n = a or b
        if n and n not in seen:
            seen.add(n)
            by_issue[n].append(pr)
duplicates = {iss: prs for iss, prs in by_issue.items() if len(prs) >= 2}

if duplicates:
    total_dups = sum(len(prs) - 1 for prs in duplicates.values())
    examples = []
    for issue_id, prs in sorted(duplicates.items(), key=lambda kv: -len(kv[1]))[:5]:
        examples.append({
            "issue": issue_id,
            "pr_numbers": [p.get("number") for p in prs],
            "pr_titles": [p.get("title", "")[:80] for p in prs[:3]],
        })
    findings.append({
        "id": "duplicate_prs",
        "metric": "duplicate_prs",
        "title": f"{total_dups} duplicate PR(s) open across {len(duplicates)} issue(s)",
        "metric_value": total_dups,
        "prior_value": 0,
        "delta": total_dups,
        "summary": (
            f"Found {total_dups} extra PR(s) (excess beyond 1 per issue) currently "
            f"open against {len(duplicates)} distinct issue(s) on {os.environ.get('GITHUB_REPO_LIFT', 'aschung212/Lift')}. "
            f"This usually means the builder's dedupe guard fired too late or didn't fire — "
            f"often correlated with marker-emission collapse."
        ),
        "remediation": (
            "Close the older duplicates (or the ones with fewer commits) and verify "
            "the dedupe guard at scripts/builder.sh is matching both #NNN and "
            f"{prefix}-NNN shapes. If marker emission also collapsed, fix that root cause first."
        ),
        "evidence_examples": examples,
    })

# ── Detector 5: Stall rate week over week ────────────────────────────────────
metrics_rows = read_csv(metrics_csv)
def stall_pct(rows):
    if not rows: return None, 0
    stalls = sum(1 for r in rows if (r.get("success") or "").strip() == "stall")
    return (100.0 * stalls / len(rows)), len(rows)

cur_metrics   = [r for r in metrics_rows if (parse_date(r.get("date","")) or today) >= window_lo]
prior_metrics = [r for r in metrics_rows
                 if (pd := parse_date(r.get("date",""))) is not None
                 and prior_lo <= pd <= prior_hi]
sp_cur,   sp_cur_n   = stall_pct(cur_metrics)
sp_prior, sp_prior_n = stall_pct(prior_metrics)
if sp_cur is not None and sp_cur_n >= 3 and sp_cur >= 30:
    delta_pp = sp_cur - (sp_prior or 0)
    findings.append({
        "id": "stall_rate_high",
        "metric": "stall_rate_pct",
        "title": f"Stall rate {sp_cur:.0f}% (was {(sp_prior or 0):.0f}%)",
        "metric_value": round(sp_cur, 1),
        "prior_value": round(sp_prior or 0, 1),
        "delta": round(sp_cur, 1),  # absolute, not delta — health-report uses absolute too
        "summary": (
            f"{int(round(sp_cur * sp_cur_n / 100))}/{sp_cur_n} iterations stalled "
            f"(produced 0 commits) in the current window. Prior window: "
            f"{int(round((sp_prior or 0) * sp_prior_n / 100))}/{sp_prior_n}. "
            f"Stalls usually mean the picker keeps choosing issues with no actionable backlog "
            f"or that Claude's plan exceeds the work in the codebase."
        ),
        "remediation": (
            "Check if backlog is exhausted (bash adapters/tracker.sh list unstarted), "
            "or if discovery is failing to refill it. The budget tuner already lowers "
            "MAX_ITERATIONS_PER_NIGHT on stalls; if it hasn't, investigate why."
        ),
    })

# ── Detector 6: Time-to-merge regression ─────────────────────────────────────
def median(xs):
    if not xs: return 0
    xs = sorted(xs)
    n = len(xs)
    return xs[n//2] if n % 2 == 1 else (xs[n//2 - 1] + xs[n//2]) / 2

def merge_hours(prs):
    out = []
    for pr in prs:
        c = parse_iso(pr.get("createdAt"))
        m = parse_iso(pr.get("mergedAt"))
        if c and m and m > c:
            out.append((m - c).total_seconds() / 3600.0)
    return out

cur_h   = merge_hours(merged_in_window)
prior_h = merge_hours(merged_in_prior)
med_cur   = median(cur_h)
med_prior = median(prior_h)
if med_cur >= 24 and len(cur_h) >= 3:
    findings.append({
        "id": "time_to_merge_regression",
        "metric": "time_to_merge_hours",
        "title": f"Median time-to-merge {med_cur:.1f}h (was {med_prior:.1f}h)",
        "metric_value": round(med_cur, 1),
        "prior_value": round(med_prior, 1),
        "delta": round(med_cur, 1),
        "summary": (
            f"Median time from PR open to merge: {med_cur:.1f} hours over "
            f"{len(cur_h)} merged PRs this window (prior: {med_prior:.1f}h over "
            f"{len(prior_h)} PRs). Long times-to-merge usually mean Aaron is buried "
            f"in review or PRs are getting blocked on CI."
        ),
        "remediation": (
            "Spot-check the slowest 3 PRs — if they're blocked on CI failures, the "
            "ci:failed retry loop is probably the upstream cause. Otherwise, this is "
            "an Aaron-attention bottleneck and the auditor should keep flagging it."
        ),
    })

# ── Detector 7: Review-finding density (Gemini Pro findings/PR) ─────────────
# Heuristic: count "REVIEW_FIX:" or "Critical|High|Medium" entries in the
# review-router log files in the window.
review_logs = sorted(glob.glob(f"{output_dir}/lift-review-*-run*.log"))
def review_findings_count(path):
    try:
        with open(path) as f: txt = f.read()
    except OSError: return 0
    count = len(re.findall(r"^REVIEW_FIX:", txt, re.M))
    if count == 0:
        # Heuristic fallback for free-form review prose.
        count = len(re.findall(r"\b(Critical|High|Medium)\b", txt, re.I))
    return count

cur_log_paths   = [p for p in review_logs
                   if (m := re.search(r"lift-review-(\d{4}-\d{2}-\d{2})-run\d+", os.path.basename(p)))
                   and (d := parse_date(m.group(1))) is not None and in_window(d, window_lo)]
prior_log_paths = [p for p in review_logs
                   if (m := re.search(r"lift-review-(\d{4}-\d{2}-\d{2})-run\d+", os.path.basename(p)))
                   and (d := parse_date(m.group(1))) is not None and in_window(d, prior_lo, prior_hi)]
def avg(xs): return (sum(xs) / len(xs)) if xs else 0
cur_avg   = avg([review_findings_count(p) for p in cur_log_paths])
prior_avg = avg([review_findings_count(p) for p in prior_log_paths])

if cur_avg >= 2 and len(cur_log_paths) >= 3:
    delta = cur_avg - prior_avg
    if cur_avg >= 3 or (prior_avg > 0 and (cur_avg / max(prior_avg, 0.01)) >= 1.5):
        findings.append({
            "id": "review_finding_density",
            "metric": "review_findings_per_pr",
            "title": f"Review findings {cur_avg:.1f}/PR (was {prior_avg:.1f}/PR)",
            "metric_value": round(cur_avg, 1),
            "prior_value": round(prior_avg, 1),
            "delta": round(cur_avg, 1),
            "summary": (
                f"Gemini-Pro review log lines averaged {cur_avg:.1f} findings/PR over "
                f"{len(cur_log_paths)} PRs this window vs {prior_avg:.1f}/PR over "
                f"{len(prior_log_paths)} PRs prior. Trending up usually means the builder "
                f"is rushing implementation or skipping its own self-check."
            ),
            "remediation": (
                "Sample 2-3 of the noisiest reviews from this window. If they're "
                "all P2/P3 nits, raise the review threshold. If they're catching real "
                "regressions, tighten the builder's pre-push self-check prompt."
            ),
        })

# ── Detector 8: Failed-PR retry loop ────────────────────────────────────────
# A PR labeled ci:failed across more than 2 nights' worth of metrics events
# means the auto-fix loop in builder.sh isn't healing. Heuristic: ci:failed
# label currently set AND PR was created >2 days ago.
failed_loop = []
for pr in open_prs:
    labels = [l.get("name") for l in (pr.get("labels") or [])]
    if "ci:failed" not in labels: continue
    created = parse_iso(pr.get("createdAt"))
    if not created: continue
    # Convert today to aware datetime for consistent comparison.
    today_utc = datetime.combine(today, datetime.min.time(), tzinfo=timezone.utc)
    age_days  = (today_utc - created).total_seconds() / 86400
    if age_days >= 2:
        failed_loop.append({
            "number": pr.get("number"),
            "title": pr.get("title", "")[:80],
            "age_days": round(age_days, 1),
            "branch": pr.get("headRefName", ""),
        })
if len(failed_loop) >= 1:
    findings.append({
        "id": "failed_pr_retry_loop",
        "metric": "failed_pr_retries",
        "title": f"{len(failed_loop)} ci:failed PR(s) older than 2 days",
        "metric_value": len(failed_loop),
        "prior_value": 0,
        "delta": len(failed_loop),
        "summary": (
            f"{len(failed_loop)} open PR(s) currently labeled ci:failed have been "
            f"in that state for >=2 days. The builder's auto-fix loop only attempts "
            f"once per night before opening the PR; if the failure persists, the PR "
            f"sits there until Aaron intervenes."
        ),
        "remediation": (
            "Either (a) raise MAX_FIX_ATTEMPTS in builder.sh, (b) close stale "
            "ci:failed PRs in cleanup.sh, or (c) add a pre-CI lint to the builder's "
            "implementation phase to catch the failures earlier."
        ),
        "evidence_examples": failed_loop[:5],
    })

# ── Output ──────────────────────────────────────────────────────────────────
print(json.dumps({
    "date": today.isoformat(),
    "window_days": days,
    "window_start": window_lo.isoformat(),
    "prior_start": prior_lo.isoformat(),
    "n_enhance_jsons_in_window": len([j for j in enhance_jsons if in_window(j["date"], window_lo)]),
    "n_metrics_rows_in_window": len(cur_metrics),
    "n_open_prs": len(open_prs),
    "n_merged_in_window": len(merged_in_window),
    "findings": findings,
}))
PYEOF
)

# ── Validate Python output (defensive — never fail silently) ────────────────
if [ -z "$FINDINGS_JSON" ]; then
  log_error "Auditor analysis produced no output — check Python heredoc"
  exit 1
fi
if ! echo "$FINDINGS_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  log_error "Auditor analysis produced invalid JSON"
  echo "$FINDINGS_JSON" >&2
  exit 1
fi

# ── Render markdown report and history CSV ──────────────────────────────────
echo "$FINDINGS_JSON" | python3 -c "
import json, sys, os
data = json.load(sys.stdin)
report_path  = '$AUDIT_REPORT'
history_path = '$AUDIT_HISTORY'
date         = data['date']

findings = data.get('findings', [])
findings_by_sev = {'P1': [], 'P2': [], 'P3': []}

# Severity classification mirrors lib/auditor-utils.sh::classify_severity.
# Keeping it inline here so the markdown render and CSV append don't need
# to shell out per finding.
def classify(metric, delta):
    d = abs(float(delta or 0))
    if metric == 'marker_emission_pct':   return 'P1' if d >= 25 else 'P2' if d >= 10 else 'P3'
    if metric == 'num_turns_one_pct':     return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'subagent_delegation_pct': return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'early_exit_pct':        return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'cost_per_pr_drift_pct': return 'P1' if d >= 100 else 'P2' if d >= 50 else 'P3'
    if metric == 'duplicate_prs':         return 'P1' if d >= 3  else 'P2' if d >= 1  else 'P3'
    if metric == 'stall_rate_pct':        return 'P1' if d >= 50 else 'P2' if d >= 30 else 'P3'
    if metric == 'time_to_merge_hours':   return 'P1' if d >= 72 else 'P2' if d >= 24 else 'P3'
    if metric == 'review_findings_per_pr':return 'P1' if d >= 5  else 'P2' if d >= 3  else 'P3'
    if metric == 'failed_pr_retries':     return 'P1' if d >= 3  else 'P2' if d >= 2  else 'P3'
    return 'P3'

for f in findings:
    f['severity'] = classify(f.get('metric',''), f.get('delta', 0))
    findings_by_sev[f['severity']].append(f)

# ── Markdown ──
lines = [
    f'# Pilot Audit — {date}',
    '',
    f'**Window:** {data[\"window_start\"]} to {date} ({data[\"window_days\"]} days)',
    f'**Builder runs analyzed:** {data[\"n_enhance_jsons_in_window\"]}',
    f'**Builder iterations (metrics rows):** {data[\"n_metrics_rows_in_window\"]}',
    f'**Open PRs:** {data[\"n_open_prs\"]}',
    f'**Merged PRs in window:** {data[\"n_merged_in_window\"]}',
    '',
]
total = sum(len(v) for v in findings_by_sev.values())
if total == 0:
    lines += ['## Findings', '', 'No anomalies detected. ✅']
else:
    lines += [f'## Findings ({total} — P1: {len(findings_by_sev[\"P1\"])}, P2: {len(findings_by_sev[\"P2\"])}, P3: {len(findings_by_sev[\"P3\"])})', '']
    for sev in ('P1','P2','P3'):
        bucket = findings_by_sev[sev]
        if not bucket: continue
        emoji = {'P1':'🚨','P2':'⚠️','P3':'ℹ️'}[sev]
        lines.append(f'### {emoji} {sev} ({len(bucket)})')
        lines.append('')
        for f in bucket:
            lines.append(f'#### {f[\"title\"]}')
            lines.append('')
            lines.append(f'- **Metric:** {f[\"metric\"]}')
            lines.append(f'- **Current:** {f[\"metric_value\"]}')
            lines.append(f'- **Prior window:** {f[\"prior_value\"]}')
            lines.append(f'- **Delta:** {f[\"delta\"]}')
            lines.append('')
            lines.append('**Summary:**')
            lines.append('')
            lines.append(f'> {f[\"summary\"]}')
            lines.append('')
            lines.append('**Remediation:**')
            lines.append('')
            lines.append(f'> {f[\"remediation\"]}')
            ex = f.get('evidence_examples') or f.get('evidence_files')
            if ex:
                lines.append('')
                lines.append('**Evidence:**')
                lines.append('')
                if isinstance(ex, list):
                    for e in ex[:5]:
                        lines.append(f'- \`{e}\`' if isinstance(e, str) else f'- {json.dumps(e, default=str)}')
            lines.append('')

with open(report_path, 'w') as f:
    f.write('\n'.join(lines))
print(f'WROTE_REPORT:{report_path}')

# ── History CSV append ──
header = 'date,finding_id,severity,metric,metric_value,prior_value,delta,action_taken'
if not os.path.exists(history_path):
    with open(history_path, 'w') as f: f.write(header + '\n')
with open(history_path, 'a') as f:
    for fnd in findings:
        action = 'logged'  # filled in by bash wrapper if a gh issue gets created
        # Escape any double-quotes in action by doubling them (CSV convention).
        a = action.replace('\"','\"\"')
        f.write(f'{date},{fnd[\"id\"]},{fnd[\"severity\"]},{fnd[\"metric\"]},{fnd[\"metric_value\"]},{fnd[\"prior_value\"]},{fnd[\"delta\"]},\"{a}\"\n')

# Emit findings JSON to stderr-tagged sentinel so bash can re-parse without
# re-running the analysis. (Stdout is already used for WROTE_REPORT line.)
print('FINDINGS_WITH_SEVERITY:' + json.dumps(findings))
"

# Re-extract findings (now with severity classifications) for downstream steps.
FINDINGS_WITH_SEV=$(echo "$FINDINGS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
def classify(metric, delta):
    d = abs(float(delta or 0))
    if metric == 'marker_emission_pct':   return 'P1' if d >= 25 else 'P2' if d >= 10 else 'P3'
    if metric == 'num_turns_one_pct':     return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'subagent_delegation_pct': return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'early_exit_pct':        return 'P1' if d >= 50 else 'P2' if d >= 25 else 'P3'
    if metric == 'cost_per_pr_drift_pct': return 'P1' if d >= 100 else 'P2' if d >= 50 else 'P3'
    if metric == 'duplicate_prs':         return 'P1' if d >= 3  else 'P2' if d >= 1  else 'P3'
    if metric == 'stall_rate_pct':        return 'P1' if d >= 50 else 'P2' if d >= 30 else 'P3'
    if metric == 'time_to_merge_hours':   return 'P1' if d >= 72 else 'P2' if d >= 24 else 'P3'
    if metric == 'review_findings_per_pr':return 'P1' if d >= 5  else 'P2' if d >= 3  else 'P3'
    if metric == 'failed_pr_retries':     return 'P1' if d >= 3  else 'P2' if d >= 2  else 'P3'
    return 'P3'
out = []
for f in data.get('findings', []):
    f['severity'] = classify(f.get('metric',''), f.get('delta', 0))
    out.append(f)
print(json.dumps(out))
")

P1_COUNT=$(echo "$FINDINGS_WITH_SEV" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin) if f['severity']=='P1'))")
P2_COUNT=$(echo "$FINDINGS_WITH_SEV" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin) if f['severity']=='P2'))")
P3_COUNT=$(echo "$FINDINGS_WITH_SEV" | python3 -c "import json,sys; print(sum(1 for f in json.load(sys.stdin) if f['severity']=='P3'))")
TOTAL=$(echo "$FINDINGS_WITH_SEV" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
log_info "Audit complete — $TOTAL findings (P1=$P1_COUNT, P2=$P2_COUNT, P3=$P3_COUNT). Report: $AUDIT_REPORT"

# ══════════════════════════════════════════════════════════════════════════════
# Optional AI synthesis layer (Sonnet 4.6) — generates a human-readable Slack
# digest with prose explanations, prioritized recommendations, and config
# suggestions. Skipped if `claude` is unavailable, in test mode, or AI synth
# is disabled. v1 acceptance criterion: deterministic output is sufficient,
# this is a polish layer.
# ══════════════════════════════════════════════════════════════════════════════
SYNTHESIS=""
if [ "${_PILOT_TEST_MODE:-}" != "1" ] \
   && [ "${AUDITOR_USE_AI_SYNTHESIS:-1}" = "1" ] \
   && command -v claude >/dev/null 2>&1 \
   && [ "$TOTAL" -gt 0 ]; then
  AI_PROMPT=$(cat <<EOF
You are the Pilot Auditor's synthesis layer. The deterministic detector found
$TOTAL anomalies in the past $DAYS days of pipeline data for Aaron's Lift PWA.

Findings (JSON):
$FINDINGS_WITH_SEV

Aaron is an ex-AWS SDE2 running an autonomous overnight pipeline. He cares
about catching regressions early and preserving his Sunday review cycle.

Generate a Slack digest in Slack mrkdwn. Constraints:
- Lead with the most severe finding
- Each finding: 2-3 sentences max + ONE concrete remediation suggestion
- Use \`*bold*\`, \`_italic_\`, and bullet points (•). No markdown headers (#).
- End with a one-line recommendation of the single highest-leverage change
- Total length: <500 words
- Do NOT invent metrics not in the JSON above
EOF
)
  log_info "Running AI synthesis (Sonnet 4.6)…"
  SYNTHESIS=$(claude --model sonnet \
    --allowedTools "Read,Grep,Bash(gh:*)" \
    --output-format json \
    -p "$AI_PROMPT" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('result') or '').strip())" \
    2>/dev/null || true)
  if [ -z "$SYNTHESIS" ] || [ "${#SYNTHESIS}" -lt 40 ]; then
    log_warn "AI synthesis returned empty or too short — falling back to deterministic digest"
    SYNTHESIS=""
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Slack digest — posts to #pilot via the `changelog` channel (deployed only)
# ══════════════════════════════════════════════════════════════════════════════
build_deterministic_digest() {
  local body
  body=$(echo "$FINDINGS_WITH_SEV" | python3 -c "
import json, sys
findings = json.load(sys.stdin)
if not findings:
    print('No anomalies detected. ✅')
    sys.exit(0)
emoji = {'P1':'🚨','P2':'⚠️','P3':'ℹ️'}
buckets = {'P1':[], 'P2':[], 'P3':[]}
for f in findings: buckets[f['severity']].append(f)
out = []
for sev in ('P1','P2','P3'):
    if not buckets[sev]: continue
    out.append(f'{emoji[sev]} *{sev} ({len(buckets[sev])})*')
    for f in buckets[sev]:
        out.append(f'  • {f[\"title\"]}')
        # one-line summary trimmed to ~140 chars
        summ = f.get('summary','')
        if len(summ) > 140: summ = summ[:137] + '…'
        out.append(f'    _{summ}_')
print('\n'.join(out))
")
  echo "$body"
}

DIGEST_BODY=""
if [ -n "$SYNTHESIS" ]; then
  DIGEST_BODY="$SYNTHESIS"
else
  DIGEST_BODY=$(build_deterministic_digest)
fi

SLACK_MSG="🔍 *Pilot Audit — $DATE*
_Window: ${DAYS} days | Findings: $TOTAL (P1: $P1_COUNT, P2: $P2_COUNT, P3: $P3_COUNT)_

$DIGEST_BODY

📋 Full report: \`$AUDIT_REPORT\`"

if [ "$DRY_RUN" = "true" ]; then
  echo "──── (dry-run) Slack digest ────"
  echo "$SLACK_MSG"
  echo "────────────────────────────────"
else
  bash "$NOTIFY" --as auditor send changelog "$SLACK_MSG" 2>/dev/null \
    && log_info "Posted audit digest to #pilot" \
    || log_warn "Slack post failed — see notify.sh logs"
fi

# ══════════════════════════════════════════════════════════════════════════════
# GitHub issues for P1 findings (idempotent)
# ══════════════════════════════════════════════════════════════════════════════
ISSUES_OPENED=0
ISSUES_REUSED=0
if [ "$P1_COUNT" -gt 0 ]; then
  echo "$FINDINGS_WITH_SEV" \
    | python3 -c "
import json, sys
findings = json.load(sys.stdin)
for f in findings:
    if f['severity'] != 'P1': continue
    print(json.dumps({
        'id': f['id'],
        'title': f['title'],
        'summary': f['summary'],
        'remediation': f['remediation'],
        'metric': f['metric'],
        'metric_value': f['metric_value'],
        'prior_value': f['prior_value'],
        'delta': f['delta'],
    }))
" \
    | while IFS= read -r p1_json; do
      [ -z "$p1_json" ] && continue
      P1_TITLE=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
      P1_ID=$(echo "$p1_json"    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      # Merge-bandwidth metrics never file issues — they measure Aaron's
      # review latency, not a pipeline defect. See audit_issue_worthy in
      # lib/auditor-utils.sh for the ruling. They stay in the report/digest.
      if ! audit_issue_worthy "$P1_ID"; then
        echo "  ⏭️  $P1_ID is P1 but backpressure-only — no issue filed (report/digest only)"
        continue
      fi
      # The stable finding ID goes IN the title: find_existing_audit_issue
      # matches on title, and titles embed current metric numbers that change
      # every run. Without the ID there, the dedupe can never fire — that is
      # how #9–#19 piled up as weekly re-filings of two findings.
      ISSUE_TITLE="[Audit P1] [$P1_ID] $P1_TITLE"
      EXISTING=$(find_existing_audit_issue "$P1_ID")
      if [ -n "$EXISTING" ]; then
        ISSUES_REUSED=$((ISSUES_REUSED + 1))
        EX_NUM=$(echo "$EXISTING" | head -1)
        echo "  ♻️ Reusing audit issue #$EX_NUM for $P1_ID"
        if [ "$DRY_RUN" != "true" ]; then
          # Add a comment with the latest snapshot.
          P1_SUMMARY=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['summary'])")
          P1_REMEDIATION=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['remediation'])")
          gh issue comment "$EX_NUM" --repo "$PILOT_REPO" --body "$(cat <<COMMENT
**Audit re-run on $DATE** — finding still present.

$P1_SUMMARY

**Remediation:** $P1_REMEDIATION
COMMENT
)" 2>/dev/null || log_warn "Failed to comment on #$EX_NUM"
        fi
      else
        ISSUES_OPENED=$((ISSUES_OPENED + 1))
        if [ "$DRY_RUN" = "true" ]; then
          echo "  📋 (dry-run) Would open audit issue: $ISSUE_TITLE"
        else
          P1_SUMMARY=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['summary'])")
          P1_REMEDIATION=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['remediation'])")
          P1_METRIC=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['metric'])")
          P1_VAL=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['metric_value'])")
          P1_PRIOR=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['prior_value'])")
          P1_DELTA=$(echo "$p1_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['delta'])")
          BODY=$(cat <<BODY
## Pilot Auditor — P1 finding

**Finding ID:** \`$P1_ID\`
**Detected:** $DATE
**Window:** $DAYS days

### What changed
- **Metric:** \`$P1_METRIC\`
- **Current:** $P1_VAL
- **Prior window:** $P1_PRIOR
- **Delta:** $P1_DELTA

### Summary
$P1_SUMMARY

### Suggested remediation
$P1_REMEDIATION

### Source data
- Audit report: \`$AUDIT_REPORT\`
- History CSV: \`$AUDIT_HISTORY\`

---
_Filed automatically by \`scripts/pipeline-auditor.sh\`. This issue is **idempotent** — subsequent audit runs will comment here rather than open duplicates._
BODY
)
          NEW_URL=$(gh issue create --repo "$PILOT_REPO" \
            --title "$ISSUE_TITLE" \
            --label audit --label severity:p1 \
            --body "$BODY" 2>&1 || echo "")
          if echo "$NEW_URL" | grep -q "github.com"; then
            log_info "Opened audit issue: $NEW_URL"
          else
            log_warn "gh issue create failed: $NEW_URL"
          fi
        fi
      fi
    done
fi

# ══════════════════════════════════════════════════════════════════════════════
# Final summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━ Audit complete ━━━"
echo "  Findings: $TOTAL (P1: $P1_COUNT, P2: $P2_COUNT, P3: $P3_COUNT)"
echo "  Issues opened: $ISSUES_OPENED"
echo "  Issues reused: $ISSUES_REUSED"
echo "  Report: $AUDIT_REPORT"
echo "  History: $AUDIT_HISTORY"

# Log rotation — best-effort, mirrors health-report.sh.
log_rotate 2>/dev/null || true

exit 0
