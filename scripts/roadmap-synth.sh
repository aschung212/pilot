#!/bin/bash
# Roadmap Synthesiser — clusters the Lift backlog into themes, proposes epics,
# flags orphan issues, and writes a Markdown roadmap to the Obsidian vault.
#
# Usage:
#   ./roadmap-synth.sh           # writes to Obsidian vault
#   ./roadmap-synth.sh --dry-run # writes to data/roadmap-YYYY-MM-DD.md instead
#
# Outputs:
#   1. Obsidian Markdown  → <vault>/40_Career/Portfolio/Lift Roadmap.md
#   2. Slack digest       → automation channel
#   3. History CSV        → data/roadmap-history.csv
#
# Logs: data/roadmap-YYYY-MM-DD.log

set -uo pipefail
# Not using -e: individual command failures are handled per-step.

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/roadmap-utils.sh"
LOG_COMPONENT="roadmap"

# ── Config ───────────────────────────────────────────────────────────────────
DATE=$(date +%Y-%m-%d)
DRY_RUN="${1:-}"
PROJECT_NAME="${PROJECT_NAME:-Lift}"
GITHUB_REPO="${GITHUB_REPO:-aschung212/Lift}"
ISSUE_PREFIX="${ISSUE_PREFIX:-LIFT}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../data}"
mkdir -p "$OUTPUT_DIR"

HISTORY_CSV="$OUTPUT_DIR/roadmap-history.csv"
RUN_LOG="$OUTPUT_DIR/roadmap-${DATE}.log"

# Obsidian path (verified: vault has 40_Career/Portfolio/)
VAULT_DIR="${OBSIDIAN_VAULT:-$HOME/Documents/Obsidian Vault}"
ROADMAP_DOC="${VAULT_DIR}/40_Career/Portfolio/Lift Roadmap.md"

# In dry-run mode, write locally so we don't clobber the vault during testing
if [ "$DRY_RUN" = "--dry-run" ]; then
  ROADMAP_DOC="$OUTPUT_DIR/roadmap-${DATE}.md"
  log_info "DRY RUN — roadmap will be written to $ROADMAP_DOC (not vault)"
fi

log_info "Roadmap Synthesiser starting — $DATE"
echo "== Roadmap Synthesiser $DATE ==" | tee "$RUN_LOG"

# ── Step 1: Fetch backlog issues ──────────────────────────────────────────────
log_info "Fetching open issues from tracker"
echo "[1/5] Fetching open issues..." | tee -a "$RUN_LOG"

OPEN_ISSUES=$(bash "$TRACKER" list unstarted started 2>&1 || true)
# Some tracker setups expose additional states; try them gracefully
BACKLOG_ISSUES=$(bash "$TRACKER" list backlog 2>&1 || true)
TODO_ISSUES=$(bash "$TRACKER" list todo 2>&1 || true)

# Merge into one list (dedup by line content is fine — tracker uses fixed-width)
ALL_OPEN=$(printf '%s\n%s\n%s\n' "$OPEN_ISSUES" "$BACKLOG_ISSUES" "$TODO_ISSUES" \
  | grep -E "${ISSUE_PREFIX}-[0-9]+" | sort -u || true)

TOTAL_OPEN=$({ echo "$ALL_OPEN" | grep -c "${ISSUE_PREFIX}-" || echo "0"; } | head -1)
echo "  Found $TOTAL_OPEN open issues" | tee -a "$RUN_LOG"

# Fetch recent done issues for historical context (last 30 days worth)
DONE_ISSUES=$(bash "$TRACKER" list done 2>&1 | head -50 || true)

# Fetch full details for open issues (up to 20 for the clustering prompt)
TOP_IDS=$(echo "$ALL_OPEN" | grep -oE "${ISSUE_PREFIX}-[0-9]+" | head -20 || true)
ISSUE_DETAILS=""
for iid in $TOP_IDS; do
  detail=$(bash "$TRACKER" view "$iid" 2>/dev/null | head -20 || true)
  ISSUE_DETAILS+="--- ${iid} ---
${detail}

"
done

# GitHub labels for context
GH_LABELS=$(gh label list --repo "$GITHUB_REPO" 2>/dev/null | awk '{print $1}' | tr '\n' ', ' || echo "Performance,Accessibility,UI/UX,Testing,Security,PWA,Improvement,Infrastructure,Growth")

# ── Step 2: Cluster with Claude SDK ─────────────────────────────────────────
log_info "Invoking Claude for clustering synthesis"
echo "[2/5] Clustering issues with Claude..." | tee -a "$RUN_LOG"

SYNTH_JSON="$OUTPUT_DIR/roadmap-synth-${DATE}.json"

# Tight (~50-line) clustering prompt that requests structured JSON output
CLUSTER_PROMPT="You are analyzing the Lift app backlog for a solo developer (ex-AWS SDE2 building a portfolio fitness app). Synthesise the open issues into a coherent roadmap.

## Open issues

${ALL_OPEN}

## Issue details (top 20)

${ISSUE_DETAILS}

## Recently completed

${DONE_ISSUES}

## GitHub labels

${GH_LABELS}

## Your task

Produce a JSON object with exactly these keys (no markdown fences, just raw JSON):

{
  \"themes\": [
    { \"name\": \"string (3-6 words)\", \"description\": \"1-sentence description\", \"issues\": [\"${ISSUE_PREFIX}-N\", ...] }
  ],
  \"epics\": [
    { \"name\": \"string\", \"motivation\": \"why this arc matters to a user\", \"issues\": [\"${ISSUE_PREFIX}-N\", ...], \"sequence\": \"brief order note\" }
  ],
  \"orphans\": [
    { \"id\": \"${ISSUE_PREFIX}-N\", \"title\": \"issue title\", \"age_days\": N, \"reason\": \"why it's an orphan\" }
  ],
  \"risks\": [
    { \"type\": \"theme_imbalance|priority_inversion|stale_accumulation|other\", \"description\": \"concise risk description\" }
  ]
}

Rules:
- Aim for 5-10 themes (not one per issue, not one for everything).
- Propose 2-3 epics — multi-issue arcs delivering visible user value.
- An issue is an orphan if: open >30 days with no clear theme fit, OR clearly superseded.
- Detect risks: one area dominating (>40%), P3s active while P1s wait, stale accumulation.
- Return ONLY the JSON object. No prose, no markdown, no commentary."

# Run Claude SDK for synthesis
if [ -z "${_PILOT_TEST_MODE:-}" ]; then
  claude \
    --allowedTools "Read,Bash(gh:*)" \
    --output-format json \
    --model sonnet \
    --effort "${AI_ROADMAP_EFFORT:-high}" \
    --max-turns "${ROADMAP_MAX_TURNS:-3}" \
    -p "$CLUSTER_PROMPT" > "$SYNTH_JSON" 2>&1
  CLAUDE_EXIT=$?
else
  # In test mode, use a fixture if available, else write minimal valid JSON
  FIXTURE="$SCRIPT_DIR/../tests/fixtures/roadmap-synth-fixture.json"
  if [ -f "$FIXTURE" ]; then
    cp "$FIXTURE" "$SYNTH_JSON"
  else
    cat > "$SYNTH_JSON" << 'FIXTURE_EOF'
{"result":"{\"themes\":[{\"name\":\"Test Theme\",\"description\":\"A test theme.\",\"issues\":[\"LIFT-1\"]}],\"epics\":[{\"name\":\"Test Epic\",\"motivation\":\"Ship value.\",\"issues\":[\"LIFT-1\"],\"sequence\":\"1 first\"}],\"orphans\":[],\"risks\":[]}"}
FIXTURE_EOF
  fi
  CLAUDE_EXIT=0
fi

if [ $CLAUDE_EXIT -ne 0 ]; then
  log_error "Claude synthesis failed (exit $CLAUDE_EXIT)"
  echo "  ERROR: Claude synthesis failed — check $SYNTH_JSON" | tee -a "$RUN_LOG"
  exit 1
fi

# Extract the result text from the SDK JSON envelope.
# Claude SDK wraps output as {"result": "<synthesis JSON string>"}.
# In test mode the fixture is already the raw synthesis object, so we handle
# both shapes: envelope-with-result-key and bare synthesis object.
SYNTH_RESULT_FILE="$OUTPUT_DIR/roadmap-result-${DATE}.json"
python3 - "$SYNTH_JSON" "$SYNTH_RESULT_FILE" << 'PYEOF'
import json, sys

in_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(in_path) as f:
        data = json.load(f)

    # Shape 1: SDK envelope — {"result": "<JSON string or dict>"}
    if "result" in data:
        result = data["result"]
        if isinstance(result, str) and result.strip():
            # result is a JSON string — parse it
            try:
                parsed = json.loads(result)
            except json.JSONDecodeError:
                # Claude returned prose with JSON embedded; write raw for renderer
                with open(out_path, "w") as f:
                    f.write(result)
                sys.exit(0)
        elif isinstance(result, dict):
            parsed = result
        else:
            # Empty or unexpected — treat the whole file as the synthesis object
            parsed = data
    else:
        # Shape 2: bare synthesis object (test fixture or direct JSON output)
        parsed = data

    with open(out_path, "w") as f:
        json.dump(parsed, f, indent=2)

except Exception as e:
    print(f"Failed to extract synthesis result: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

if [ $? -ne 0 ]; then
  log_error "Failed to extract synthesis result from Claude output"
  echo "  ERROR: Could not parse Claude JSON output" | tee -a "$RUN_LOG"
  exit 1
fi

echo "  Synthesis complete" | tee -a "$RUN_LOG"

# ── Step 3: Parse synthesis metrics ─────────────────────────────────────────
log_info "Parsing synthesis metrics"
echo "[3/5] Parsing synthesis output..." | tee -a "$RUN_LOG"

# Evaluate key=value pairs from the parser
eval "$(roadmap_parse_synthesis "$SYNTH_RESULT_FILE")" || true
THEME_COUNT="${THEME_COUNT:-0}"
EPIC_COUNT="${EPIC_COUNT:-0}"
ORPHAN_COUNT="${ORPHAN_COUNT:-0}"
RISK_COUNT="${RISK_COUNT:-0}"

echo "  Themes: $THEME_COUNT | Epics: $EPIC_COUNT | Orphans: $ORPHAN_COUNT | Risks: $RISK_COUNT" | tee -a "$RUN_LOG"

# Oldest orphan age (walk the orphans array for the max)
OLDEST_ORPHAN_AGE=$(python3 - "$SYNTH_RESULT_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    ages = [o.get("age_days", 0) for o in data.get("orphans", [])]
    print(max(ages) if ages else 0)
except Exception:
    print(0)
PYEOF
)

# ── Step 4: Write Markdown roadmap ───────────────────────────────────────────
log_info "Writing roadmap document"
echo "[4/5] Writing roadmap to: $ROADMAP_DOC" | tee -a "$RUN_LOG"

# Render and write (idempotent — overwrites same file each run)
roadmap_render_markdown "$SYNTH_RESULT_FILE" "$DATE" "$PROJECT_NAME" > "$ROADMAP_DOC"

if [ $? -eq 0 ]; then
  echo "  Roadmap written: $ROADMAP_DOC" | tee -a "$RUN_LOG"
  log_info "Roadmap written to $ROADMAP_DOC"
else
  log_error "Failed to write roadmap doc"
  echo "  ERROR: Failed to write roadmap doc" | tee -a "$RUN_LOG"
  exit 1
fi

# ── Step 5: Append to history CSV ────────────────────────────────────────────
roadmap_csv_init "$HISTORY_CSV"
roadmap_csv_append "$HISTORY_CSV" "$DATE" "$TOTAL_OPEN" "$THEME_COUNT" "$EPIC_COUNT" "$ORPHAN_COUNT" "$OLDEST_ORPHAN_AGE"
echo "  History CSV updated: $HISTORY_CSV" | tee -a "$RUN_LOG"

# ── Step 6: Slack digest ─────────────────────────────────────────────────────
log_info "Sending Slack digest"
echo "[5/5] Sending Slack digest..." | tee -a "$RUN_LOG"

# Build a one-line theme summary from the top two themes
THEME_SUMMARY=$(python3 - "$SYNTH_RESULT_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    themes = data.get("themes", [])
    if not themes:
        print("no themes identified")
        sys.exit(0)
    names = [t.get("name", "") for t in themes[:3]]
    print(", ".join(n for n in names if n))
except Exception:
    print("(parse error)")
PYEOF
)

TOP_EPIC=$(python3 - "$SYNTH_RESULT_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    epics = data.get("epics", [])
    if epics:
        e = epics[0]
        print(e.get("name", "—") + ": " + e.get("motivation", ""))
    else:
        print("no epics proposed")
except Exception:
    print("(parse error)")
PYEOF
)

OBSIDIAN_LINK=$(roadmap_obsidian_url "$ROADMAP_DOC")

SLACK_MSG="🗺️ *Lift Roadmap — ${DATE}*

*Themes (${THEME_COUNT}):* ${THEME_SUMMARY}
*Top Epic:* ${TOP_EPIC}
*Orphans:* ${ORPHAN_COUNT} issue(s) need review
*Risks:* ${RISK_COUNT} flagged

📄 <${OBSIDIAN_LINK}|Open in Obsidian>"

if [ "$DRY_RUN" != "--dry-run" ]; then
  bash "$NOTIFY" --as roadmap send automation "$SLACK_MSG" 2>/dev/null || \
    log_warn "Slack notification failed (non-fatal)"
  echo "  Slack digest sent" | tee -a "$RUN_LOG"
else
  echo "  [dry-run] Slack digest skipped" | tee -a "$RUN_LOG"
  echo "  Would send: $SLACK_MSG" | tee -a "$RUN_LOG"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log_info "Roadmap synthesis complete"
echo "" | tee -a "$RUN_LOG"
echo "== Done ==" | tee -a "$RUN_LOG"
echo "  Themes: $THEME_COUNT | Epics: $EPIC_COUNT | Orphans: $ORPHAN_COUNT | Risks: $RISK_COUNT" | tee -a "$RUN_LOG"
echo "  Roadmap: $ROADMAP_DOC" | tee -a "$RUN_LOG"
echo "  History: $HISTORY_CSV" | tee -a "$RUN_LOG"
