#!/bin/bash
# Shared utility functions for the pipeline-auditor.
# Sourced by scripts/pipeline-auditor.sh. Tested directly by tests/pipeline-auditor.bats.
#
# Design: keep bash thin — most logic lives in Python heredocs called from
# pipeline-auditor.sh. This file provides reusable shell wrappers for things
# that don't justify a python invocation (severity mapping, idempotency,
# safe CSV parsing) plus a few small data accessors.

# ── classify_severity ────────────────────────────────────────────────────────
# Map a delta-magnitude (percentage points or ratio) to a P1/P2/P3 severity.
# Input: $1 = metric name, $2 = absolute delta value (already a positive number)
# Output: prints "P1", "P2", or "P3" to stdout
#
# Thresholds are conservative — we'd rather P1 a real regression than miss it.
# These are tunable; the rationale below documents the day-2 vs day-7 framing.
classify_severity() {
  local metric="$1" delta="$2"
  case "$metric" in
    marker_emission_pct)
      # Marker emission rate dropped: 75% → 0% over 7 days.
      # P1 if drop ≥ 25pp (caught the drop on day 2, not day 7).
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 25 else 'P2' if d >= 10 else 'P3')"
      ;;
    num_turns_one_pct)
      # DEPRECATED 2026-05-06 — replaced by subagent_delegation_pct + early_exit_pct.
      # Kept here so historical CSV rows still classify; new audits emit the split.
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 50 else 'P2' if d >= 25 else 'P3')"
      ;;
    subagent_delegation_pct)
      # Parent num_turns=1 with haiku/sonnet visible in modelUsage.
      # The 04-28/04-29 incident pattern. P1 at ≥50% (smoking gun).
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 50 else 'P2' if d >= 25 else 'P3')"
      ;;
    early_exit_pct)
      # Parent num_turns=1, opus-only, real work done, exited without markers.
      # The 2026-05-06 incident pattern. Same severity bands — both lose markers.
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 50 else 'P2' if d >= 25 else 'P3')"
      ;;
    cost_per_pr_drift_pct)
      # Cost-per-merged-PR drift week-over-week.
      # P1 if cost ≥ doubled (>=100% increase), P2 if 50%+, P3 otherwise.
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 100 else 'P2' if d >= 50 else 'P3')"
      ;;
    duplicate_prs)
      # Open PRs colliding on the same issue. Each duplicate is real waste;
      # 3+ is severe (the 12-PR incident this week was a P1 by any measure).
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 3 else 'P2' if d >= 1 else 'P3')"
      ;;
    stall_rate_pct)
      # Stall rate week-over-week. Already monitored by health-report at 40%.
      # We P1 at 50% (worse than health-report's threshold to reduce double alerts).
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 50 else 'P2' if d >= 30 else 'P3')"
      ;;
    time_to_merge_hours)
      # Median open→merged hours regression. P1 if >72h (>3 days), P2 if 24-72h.
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 72 else 'P2' if d >= 24 else 'P3')"
      ;;
    review_findings_per_pr)
      # Pro reviewer findings per PR. Spike means quality regression.
      # P1 at >=5 findings/PR, P2 at 3-4, P3 at 2.
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 5 else 'P2' if d >= 3 else 'P3')"
      ;;
    failed_pr_retries)
      # Number of consecutive nights a PR was relabeled ci:failed.
      # 2 nights = P2, 3+ = P1 (it's stuck).
      python3 -c "d=float('${delta:-0}'); print('P1' if d >= 3 else 'P2' if d >= 2 else 'P3')"
      ;;
    *)
      # Unknown metric: default to P3.
      echo "P3"
      ;;
  esac
}

# ── severity_emoji ───────────────────────────────────────────────────────────
# Map a severity string to its display emoji.
# Input: $1 = severity (P1/P2/P3)
# Output: prints emoji to stdout
severity_emoji() {
  case "${1:-}" in
    P1) echo "🚨" ;;
    P2) echo "⚠️"  ;;
    P3) echo "ℹ️"  ;;
    *)  echo "❓" ;;
  esac
}

# ── audit_history_header ─────────────────────────────────────────────────────
# Canonical CSV header for the audit history file. Centralized so the
# auditor and any downstream readers stay in sync.
# Output: prints the header line (no trailing newline)
audit_history_header() {
  echo "date,finding_id,severity,metric,metric_value,prior_value,delta,action_taken"
}

# ── ensure_audit_history ─────────────────────────────────────────────────────
# Initialize the audit history CSV with a header if it doesn't exist.
# Input: $1 = path to history CSV
ensure_audit_history() {
  local csv="$1"
  if [ ! -f "$csv" ]; then
    audit_history_header > "$csv"
  fi
}

# ── append_audit_history ─────────────────────────────────────────────────────
# Append a row to the audit history CSV. Quotes the action_taken field so
# embedded commas don't break the CSV.
# Args: csv_path date finding_id severity metric metric_value prior_value delta action_taken
append_audit_history() {
  local csv="$1" date="$2" fid="$3" sev="$4" metric="$5"
  local mval="$6" pval="$7" delta="$8" action="$9"
  ensure_audit_history "$csv"
  # Escape any double-quotes in action by doubling them (CSV convention).
  local action_escaped
  action_escaped=$(printf '%s' "$action" | sed 's/"/""/g')
  printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$date" "$fid" "$sev" "$metric" "$mval" "$pval" "$delta" "$action_escaped" >> "$csv"
}

# ── find_existing_audit_issue ────────────────────────────────────────────────
# Search aschung212/pilot for an open audit issue whose title contains the
# given fragment. Returns the issue number (one per line) or empty if none.
# Idempotency primitive — call before `gh issue create` to avoid dup issues.
#
# Input: $1 = title fragment to match (case-sensitive)
# Output: issue number(s), one per line; empty if none found or gh is unavailable.
find_existing_audit_issue() {
  local fragment="$1"
  [ -z "$fragment" ] && return 0
  # --search runs through GitHub's search; we then post-filter on title to be
  # safe (search matches body too, which can give false positives).
  gh issue list --repo aschung212/pilot --label audit --state open \
    --search "$fragment in:title" \
    --json number,title --limit 30 2>/dev/null \
    | python3 -c "
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
frag = '''$fragment'''
for it in items:
    if frag in it.get('title', ''):
        print(it.get('number', ''))
" 2>/dev/null || true
}

# ── ensure_audit_labels ──────────────────────────────────────────────────────
# Idempotently create the labels the auditor needs in the pilot repo. Without
# these, `gh issue create --label audit --label severity:p1` rejects the whole
# call (observed 2026-05-06: 2 P1 findings silently dropped because the labels
# didn't exist on aschung212/pilot).
#
# Input: $1 = repo (e.g. aschung212/pilot)
# Behavior: best-effort — failures are logged but don't abort the auditor.
ensure_audit_labels() {
  local repo="$1"
  [ -z "$repo" ] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  # name|color|description, tab-separated rows. --force makes create idempotent
  # (overwrites color/description if the label already exists, no error if so).
  local rows='audit	FBCA04	Filed by pipeline-auditor.sh
severity:p1	B60205	Critical pipeline regression
severity:p2	D93F0B	Notable pipeline regression
severity:p3	FBCA04	Minor pipeline regression'
  while IFS=$'\t' read -r name color desc; do
    [ -z "$name" ] && continue
    gh label create "$name" --repo "$repo" --color "$color" \
      --description "$desc" --force >/dev/null 2>&1 || true
  done <<< "$rows"
}

# ── audit_window_dates ───────────────────────────────────────────────────────
# Print dates (YYYY-MM-DD) for the last N days (inclusive of today).
# Input: $1 = days (default 7)
# Output: one date per line, most recent first.
audit_window_dates() {
  local days="${1:-7}"
  python3 -c "
from datetime import datetime, timedelta
n = int('$days')
today = datetime.now().date()
for i in range(n):
    print((today - timedelta(days=i)).isoformat())
"
}

# ── csv_safe_field ───────────────────────────────────────────────────────────
# Read a numeric CSV field with a default. Trims whitespace, returns default
# if empty or non-numeric. Used for defending against missing columns in old
# rows of metrics.csv (the corrupted-row regression we hit before).
# Input: $1 = raw value, $2 = default (default "0")
csv_safe_field() {
  local raw="${1:-}" default="${2:-0}"
  local trimmed
  trimmed=$(printf '%s' "$raw" | tr -d '[:space:]')
  if [ -z "$trimmed" ]; then
    echo "$default"
    return 0
  fi
  # Accept integer or float; otherwise default.
  if [[ "$trimmed" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$trimmed"
  else
    echo "$default"
  fi
}

# ── pretty_pct ───────────────────────────────────────────────────────────────
# Format a 0..1 ratio as an integer percentage. Empty/non-numeric → "—".
# Input: $1 = ratio
pretty_pct() {
  local raw="${1:-}"
  python3 -c "
v = '$raw'
try:
    f = float(v)
    print(f'{int(round(f*100))}%')
except Exception:
    print('—')
" 2>/dev/null
}
