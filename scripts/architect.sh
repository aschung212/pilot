#!/bin/bash
# Lift Codebase Architect — deep-read critic for architectural drift and structural debt.
# Runs one architectural axis per invocation. Rotates across 8 axes (weekly cadence).
# Produces: GitHub issues, a markdown report, a Slack digest, and a history CSV.
#
# Usage:
#   ./scripts/architect.sh               # auto-selects axis via round-robin
#   ./scripts/architect.sh --axis store-coherence  # override axis

set -uo pipefail
# Note: not using -e (errexit) — failures in individual sections should not abort the run.

# Source env vars when run by launchd (no login shell)
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/architect-utils.sh"
LOG_COMPONENT="architect"

REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
HISTORY_CSV="$OUTPUT_DIR/architect-history.csv"
RUN_LOG="$OUTPUT_DIR/architect-$DATE.log"
REPORT_MD="$OUTPUT_DIR/architect-$DATE.md"

mkdir -p "$OUTPUT_DIR"

# ── Argument parsing ──────────────────────────────────────────────────────────
AXIS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --axis)
      AXIS_OVERRIDE="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
export AXIS_OVERRIDE

# ── Axis selection ────────────────────────────────────────────────────────────
# Ensure history CSV has a header
if [ ! -f "$HISTORY_CSV" ]; then
  echo "date,axis,files_scanned,findings,issues_filed,top_finding_summary" > "$HISTORY_CSV"
fi

AXIS=$(select_axis "$HISTORY_CSV")
AXIS_DISPLAY=$(axis_display_name "$AXIS")

# Validate axis if overridden
if [ -n "$AXIS_OVERRIDE" ]; then
  if ! axis_is_valid "$AXIS_OVERRIDE"; then
    echo "  ❌ Unknown axis: $AXIS_OVERRIDE" >&2
    echo "  Valid axes: ${ARCHITECT_AXES[*]}" >&2
    exit 1
  fi
  AXIS="$AXIS_OVERRIDE"
  AXIS_DISPLAY=$(axis_display_name "$AXIS")
fi

ARCHITECT_START=$(date +%s)
log_info "Architect run starting — axis: $AXIS"
echo "🏛️  Codebase Architect — $DATE — Axis: $AXIS_DISPLAY" | tee "$RUN_LOG"
echo "" | tee -a "$RUN_LOG"

# ── Build prompt ──────────────────────────────────────────────────────────────
PROMPT_FILE=$(mktemp)
build_architect_prompt "$AXIS" "$REPO" "${PROJECT_NAME:-Lift}" > "$PROMPT_FILE"

# ── Run Claude (read-only Opus) ───────────────────────────────────────────────
ARCHITECT_JSON="$OUTPUT_DIR/architect-$DATE-output.json"
ARCHITECT_ALLOWED_TOOLS="Read,Grep,Glob,Bash(git log:*),Bash(git diff:*),Bash(rg:*),Bash(find:*),Bash(wc:*),Bash(ls:*)"

echo "  🧠 Running Claude Opus analysis (axis: $AXIS)..." | tee -a "$RUN_LOG"
CLAUDE_EXIT=0
if [ -n "${MOCK_CLAUDE_OUTPUT:-}" ]; then
  # Test mode: skip the live Claude call and write the mock JSON directly.
  printf '%s\n' "$MOCK_CLAUDE_OUTPUT" > "$ARCHITECT_JSON"
  CLAUDE_EXIT="${MOCK_CLAUDE_EXIT:-0}"
elif ! claude \
    --allowedTools "$ARCHITECT_ALLOWED_TOOLS" \
    --output-format json \
    --model "${AI_CODE_MODEL:-claude-opus-4-8[1m]}" \
    --effort "${AI_CODE_EFFORT:-max}" \
    --max-turns "${ARCHITECT_MAX_TURNS:-40}" \
    -p "$(cat "$PROMPT_FILE")" \
    > "$ARCHITECT_JSON" 2>>"$RUN_LOG"; then
  CLAUDE_EXIT=$?
  echo "  ❌ Claude exited with code $CLAUDE_EXIT" | tee -a "$RUN_LOG"
fi
rm -f "$PROMPT_FILE"

# ── Parse Claude output ───────────────────────────────────────────────────────
FINDINGS_RAW=""
FILES_SCANNED=0
FINDINGS_COUNT=0
TOP_FINDING=""
SUMMARY_TEXT=""

if [ -f "$ARCHITECT_JSON" ] && [ -s "$ARCHITECT_JSON" ]; then
  # Extract the result text from Claude JSON envelope
  RESULT_TEXT=$(python3 -c "
import json, sys
try:
    with open('$ARCHITECT_JSON') as f:
        data = json.load(f)
    print(data.get('result', '') or '')
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null)

  if [ -n "$RESULT_TEXT" ]; then
    # Pull the inner JSON block out of the result text
    FINDINGS_RAW=$(python3 -c "
import json, re, sys

result = '''$RESULT_TEXT'''

# Find the JSON block (between \`\`\`json ... \`\`\` or raw {...})
m = re.search(r'\`\`\`json\s*(\{.*?\})\s*\`\`\`', result, re.DOTALL)
if not m:
    m = re.search(r'(\{[^{}]*\"findings\".*?\})', result, re.DOTALL)
if not m:
    # Try raw JSON (entire result is JSON)
    m = re.search(r'(\{.*\})', result, re.DOTALL)

if m:
    try:
        data = json.loads(m.group(1))
        print(json.dumps(data, indent=2))
    except Exception as e:
        print('', file=sys.stderr)
" 2>/dev/null)

    if [ -n "$FINDINGS_RAW" ]; then
      FINDINGS_COUNT=$(python3 -c "
import json, sys
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(len(d.get('findings', [])))
except: print(0)
" 2>/dev/null || echo "0")

      FILES_SCANNED=$(python3 -c "
import json, sys
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(d.get('files_scanned', 0))
except: print(0)
" 2>/dev/null || echo "0")

      TOP_FINDING=$(python3 -c "
import json, sys
try:
    d = json.loads('''$FINDINGS_RAW''')
    findings = d.get('findings', [])
    print(findings[0].get('title', 'N/A') if findings else 'N/A')
except: print('N/A')
" 2>/dev/null || echo "N/A")

      SUMMARY_TEXT=$(python3 -c "
import json, sys
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(d.get('summary', ''))
except: print('')
" 2>/dev/null || echo "")
    fi
  fi
fi

echo "  📊 Findings: $FINDINGS_COUNT | Files scanned: $FILES_SCANNED" | tee -a "$RUN_LOG"

# ── Write markdown report ─────────────────────────────────────────────────────
{
  echo "# Lift Codebase Architect — $DATE"
  echo ""
  echo "**Axis:** $AXIS_DISPLAY"
  echo ""
  echo "## Summary"
  echo ""
  echo "${SUMMARY_TEXT:-No summary generated.}"
  echo ""
  echo "## Findings ($FINDINGS_COUNT)"
  echo ""

  if [ -n "$FINDINGS_RAW" ]; then
    python3 -c "
import json, sys

# Coerce a field that may be either a string OR a list of strings into a
# bullet-formatted block. Claude's JSON output drifted on 2026-05-08:
# proposed_approach was a string with newlines on 2026-05-06 but came back
# as list[str] on 2026-05-08 (interpreting 'bullet points' literally).
# Either is acceptable; render both correctly.
def render_text_or_bullets(value):
    if isinstance(value, list):
        return '\n'.join(f'- {item}' for item in value if item)
    return value or ''

try:
    d = json.loads('''$FINDINGS_RAW''')
    for i, f in enumerate(d.get('findings', []), 1):
        print(f'### {i}. {f[\"title\"]}')
        print()
        print(f'**Priority:** {f[\"priority\"]}')
        print()
        print(f'**Motivation:** {render_text_or_bullets(f.get(\"motivation\", \"\"))}')
        print()
        files = f.get('files', [])
        if files:
            print('**Files:**')
            for fp in files:
                print(f'- \`{fp}\`')
            print()
        print('**Proposed approach:**')
        print(render_text_or_bullets(f.get('proposed_approach', '')))
        print()
        seq = f.get('sequencing_notes', '')
        if seq:
            print(f'**Sequencing:** {render_text_or_bullets(seq)}')
            print()
        print('---')
        print()
except Exception as e:
    print(f'Error rendering findings: {e}')
" 2>/dev/null
  fi

  echo ""
  echo "_Generated by Pilot Architect agent on ${DATE}_"
} > "$REPORT_MD"

echo "  📝 Report saved: $REPORT_MD" | tee -a "$RUN_LOG"

# ── Create GitHub label if needed ─────────────────────────────────────────────
echo "  🏷️  Ensuring 'architect:' label exists in GitHub repo..." | tee -a "$RUN_LOG"
if [ -z "${_PILOT_TEST_MODE:-}" ]; then
  gh label create "architect:" \
    --repo "${GITHUB_REPO}" \
    --color "5319E7" \
    --description "Findings from the Codebase Architect agent" \
    2>/dev/null || true
fi

# ── File GitHub issues for each finding ──────────────────────────────────────
ISSUES_FILED=0

if [ -n "$FINDINGS_RAW" ]; then
  FINDING_COUNT_INT=$(python3 -c "
import json
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(len(d.get('findings', [])))
except: print(0)
" 2>/dev/null || echo "0")

  for i in $(seq 0 $((FINDING_COUNT_INT - 1))); do
    FINDING_TITLE=$(python3 -c "
import json
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(d['findings'][$i]['title'])
except: print('')
" 2>/dev/null || echo "")

    [ -z "$FINDING_TITLE" ] && continue

    FINDING_PRIORITY=$(python3 -c "
import json
try:
    d = json.loads('''$FINDINGS_RAW''')
    print(d['findings'][$i]['priority'])
except: print(3)
" 2>/dev/null || echo "3")

    FINDING_BODY=$(python3 -c "
import json, sys

# String-or-list coercion — see render_text_or_bullets in the report block
# above. Claude returns either format depending on the run; both must work.
def render_text_or_bullets(value):
    if isinstance(value, list):
        return '\n'.join(f'- {item}' for item in value if item)
    return value or ''

try:
    d = json.loads('''$FINDINGS_RAW''')
    f = d['findings'][$i]
    lines = []
    lines.append('## Motivation')
    lines.append(render_text_or_bullets(f.get('motivation', '')))
    lines.append('')
    files = f.get('files', [])
    if files:
        lines.append('## Files')
        for fp in files:
            lines.append(f'- \`{fp}\`')
        lines.append('')
    lines.append('## Proposed Approach')
    lines.append(render_text_or_bullets(f.get('proposed_approach', '')))
    lines.append('')
    seq = f.get('sequencing_notes', '')
    if seq:
        lines.append('## Sequencing')
        lines.append(render_text_or_bullets(seq))
        lines.append('')
    lines.append(f'---')
    lines.append(f'_Axis: ${AXIS_DISPLAY} | Generated by Pilot Architect on ${DATE}_')
    print('\n'.join(lines))
except Exception as e:
    print(f'Error generating body: {e}')
" 2>/dev/null || echo "See architect report: $REPORT_MD")

    # Idempotency check — skip if a similar open issue exists
    SEARCH_TITLE=$(echo "$FINDING_TITLE" | cut -c1-60)
    EXISTING_ISSUE=""
    if [ -z "${_PILOT_TEST_MODE:-}" ]; then
      EXISTING_ISSUE=$(gh issue list \
        --repo "${GITHUB_REPO}" \
        --label "architect:" \
        --state open \
        --search "$SEARCH_TITLE" \
        --json number,title \
        --jq ".[0].number" 2>/dev/null || echo "")
    fi

    if [ -n "$EXISTING_ISSUE" ]; then
      echo "  ♻️  Issue already exists (#$EXISTING_ISSUE) — appending comment for: $FINDING_TITLE" | tee -a "$RUN_LOG"
      if [ -z "${_PILOT_TEST_MODE:-}" ]; then
        gh issue comment "$EXISTING_ISSUE" \
          --repo "${GITHUB_REPO}" \
          --body "Architect re-observed this finding on $DATE (axis: $AXIS_DISPLAY).

$FINDING_BODY" 2>/dev/null || true
      fi
    else
      echo "  📋 Filing: $FINDING_TITLE (P$FINDING_PRIORITY)" | tee -a "$RUN_LOG"
      if [ -z "${_PILOT_TEST_MODE:-}" ]; then
        # --state unstarted is the default in tracker.sh's gh_create, but pass
        # it explicitly so the contract is obvious at the call site. The
        # 2026-05-06 backfill script (now deleted) bypassed tracker.sh entirely
        # and forgot the state label, leaving #500-505 stuck without
        # state:unstarted. Architect issues going through this path get the
        # label correctly — discover-created issues are proof.
        bash "$TRACKER" create \
          "[Architect] $FINDING_TITLE" \
          "$FINDING_PRIORITY" \
          --state "unstarted" \
          --label "architect:" \
          --description "$FINDING_BODY" \
          2>&1 | tee -a "$RUN_LOG" || true
      else
        echo "  [TEST MODE] Would file: [Architect] $FINDING_TITLE (P$FINDING_PRIORITY)" | tee -a "$RUN_LOG"
      fi
      ISSUES_FILED=$((ISSUES_FILED + 1))
    fi
  done
fi

echo "  ✅ Issues filed: $ISSUES_FILED" | tee -a "$RUN_LOG"

# ── Update history CSV ────────────────────────────────────────────────────────
TOP_SUMMARY_ESCAPED=$(echo "$TOP_FINDING" | tr ',' ';' | head -c 100)
echo "$DATE,$AXIS,$FILES_SCANNED,$FINDINGS_COUNT,$ISSUES_FILED,$TOP_SUMMARY_ESCAPED" >> "$HISTORY_CSV"

# ── Post Slack digest ─────────────────────────────────────────────────────────
ARCHITECT_END=$(date +%s)
ARCHITECT_DURATION=$((ARCHITECT_END - ARCHITECT_START))

SLACK_MSG="🏛️ *Lift Architect — Axis: $AXIS_DISPLAY*
Date: $DATE | Duration: ${ARCHITECT_DURATION}s

${SUMMARY_TEXT:+_${SUMMARY_TEXT}_

}*$FINDINGS_COUNT findings* | *$ISSUES_FILED issues filed*
Top finding: $TOP_FINDING

Report: \`$REPORT_MD\`"

if [ -z "${_PILOT_TEST_MODE:-}" ]; then
  bash "$NOTIFY" --as architect send automation "$SLACK_MSG" 2>/dev/null || true
fi

echo "" | tee -a "$RUN_LOG"
echo "━━━ Architect run complete ━━━" | tee -a "$RUN_LOG"
echo "Axis: $AXIS_DISPLAY | Findings: $FINDINGS_COUNT | Issues filed: $ISSUES_FILED | Duration: ${ARCHITECT_DURATION}s" | tee -a "$RUN_LOG"
echo "Report: $REPORT_MD"
echo "History: $HISTORY_CSV"
