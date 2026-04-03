#!/bin/bash
# Adapter: AI Code Review — 3-layer cross-model pipeline
#
# Layer 1 (Gemini Flash):  Mechanical gate — bugs, types, CSS, security
# Layer 2 (Gemini Pro):    Architecture — cross-component, edge cases, what's missing
# Layer 3 (Claude Sonnet): Self-check — known Opus patterns, validate Gemini findings
#
# Each layer has a fallback chain and timeout. The build never blocks on a failed review.
#
# Usage:
#   ai-review.sh layer1 <diff_file> <output_file>
#   ai-review.sh layer2 <diff_file> <output_file> [--prior-findings <file>]
#   ai-review.sh layer3 <diff_file> <output_file> [--prior-findings <file>]
#
# Output format (in output_file):
#   REVIEW_FIX:<severity>:<file>:<description>
#   REVIEW_VERDICT:<MERGE|REVIEW|DO_NOT_MERGE>
#   REVIEW_MODEL:<model-that-ran>
#   REVIEW_CROSSCHECK:<confirmed|new|disputed>:<description>  (layers 2+3 only)

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
DATE=$(date +%Y-%m-%d)

# Models and timeouts from project.env
L1_MODEL="${AI_REVIEW_MODEL_L1:-gemini-2.5-flash}"
L2_MODEL="${AI_REVIEW_MODEL_L2:-gemini-2.5-pro}"
L3_MODEL="${AI_REVIEW_MODEL_L3:-sonnet}"
L1_FALLBACK="${AI_REVIEW_FALLBACK_L1:-sonnet}"
L2_FALLBACK="${AI_REVIEW_FALLBACK_L2:-gemini-2.5-flash}"
L3_FALLBACK="${AI_REVIEW_FALLBACK_L3:-haiku}"
L1_TIMEOUT="${AI_REVIEW_TIMEOUT_L1:-90}"
L2_TIMEOUT="${AI_REVIEW_TIMEOUT_L2:-120}"
L3_TIMEOUT="${AI_REVIEW_TIMEOUT_L3:-90}"

GEMINI_FILTER='grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt"'

# Review learnings (injected into all prompts)
REVIEW_LEARNINGS=$(cat "$OUTPUT_DIR/lift-review-learnings.md" 2>/dev/null || echo "No learnings yet.")

# ── Helper: run a Gemini model with timeout ──────────────────────────────────
# Returns 0 on success, 1 on failure. Output written to $2.
run_gemini() {
  local model="$1" output_file="$2" prompt_file="$3" timeout_sec="$4"
  local start_time=$(date +%s)

  # Use gtimeout (GNU coreutils) if available, else bash background+wait
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" gemini -p "$(cat "$prompt_file")" -m "$model" --sandbox 2>&1 \
      | eval "$GEMINI_FILTER" > "$output_file" 2>/dev/null
  else
    gemini -p "$(cat "$prompt_file")" -m "$model" --sandbox 2>&1 \
      | eval "$GEMINI_FILTER" > "$output_file" 2>/dev/null &
    local pid=$!
    ( sleep "$timeout_sec" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local exit_code=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    if [ "$exit_code" -ne 0 ]; then
      return 1
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Validate output
  if [ ! -s "$output_file" ]; then
    echo "  ⚠️  $model returned empty output after ${duration}s" >&2
    return 1
  fi
  if grep -qi "exhausted your capacity\|rate limit\|MODEL_CAPACITY_EXHAUSTED" "$output_file" 2>/dev/null; then
    echo "  ⚠️  $model rate limited after ${duration}s" >&2
    return 1
  fi

  echo "$duration"
  return 0
}

# ── Helper: run a Claude model with timeout ──────────────────────────────────
# Returns 0 on success, 1 on failure. Output written to $2.
run_claude() {
  local model="$1" output_file="$2" prompt_file="$3" timeout_sec="$4"
  local json_file="${output_file}.json"
  local start_time=$(date +%s)

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" claude --dangerously-skip-permissions --output-format json --model "$model" \
      -p "$(cat "$prompt_file")" --max-turns 15 2>&1 > "$json_file"
  else
    claude --dangerously-skip-permissions --output-format json --model "$model" \
      -p "$(cat "$prompt_file")" --max-turns 15 2>&1 > "$json_file" &
    local pid=$!
    ( sleep "$timeout_sec" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local exit_code=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    if [ "$exit_code" -ne 0 ]; then
      return 1
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Extract result from JSON
  python3 -c "
import json
try:
    with open('$json_file') as f:
        data = json.load(f)
    if data.get('is_error'):
        exit(1)
    result = data.get('result', '')
    if result:
        print(result)
    else:
        exit(1)
except:
    exit(1)
" > "$output_file" 2>/dev/null

  if [ ! -s "$output_file" ]; then
    echo "  ⚠️  claude $model returned empty/error after ${duration}s" >&2
    return 1
  fi

  echo "$duration"
  return 0
}

# ── Helper: ensure output has a verdict line ─────────────────────────────────
ensure_verdict() {
  local output_file="$1"
  if ! grep -q "^REVIEW_VERDICT:" "$output_file" 2>/dev/null; then
    echo "REVIEW_VERDICT:REVIEW" >> "$output_file"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════

cmd="${1:-}"
shift || true

case "$cmd" in
  layer1)
    # ── Layer 1: Gemini Flash — mechanical gate ────────────────────────────
    DIFF_FILE="$1"; OUTPUT_FILE="$2"
    DIFF_CONTENT=$(head -3000 "$DIFF_FILE")
    PROMPT_FILE=$(mktemp)

    cat > "$PROMPT_FILE" <<PROMPT
You are a code reviewer for a $TECH_STACK app ($PROJECT_NAME). Focus ONLY on mechanical issues — do NOT comment on architecture, naming, or style.

## Diff
$DIFF_CONTENT

## Checklist
1. Bugs — logic errors, null/undefined, off-by-one, race conditions
2. Security — XSS, injection, exposed secrets, CSP violations
3. Types — type mismatches, missing type annotations on public APIs
4. CSS — wrong values, hardcoded colors (should use CSS custom properties), missing safe-area-inset
5. CLAUDE.md violations — touch targets below 44px, missing aria-labels, hardcoded spacing
6. Tests — are changes tested? Missing edge cases?
7. Regressions — does this break existing behavior?

## Learnings from past reviews (PAY ATTENTION)
$REVIEW_LEARNINGS

## Output format
If the code is clean, output ONLY: REVIEW_CLEAN
Then: REVIEW_VERDICT:MERGE

If there are findings, output each on its own line:
REVIEW_FIX:<severity>:<file_path>:<one-line description>

Severity: critical, high, medium, low
Only emit findings that are actual bugs, regressions, or checklist violations. NOT style preferences.

Then output exactly one of:
REVIEW_VERDICT:MERGE (no blockers)
REVIEW_VERDICT:REVIEW (has findings needing human judgment)
REVIEW_VERDICT:DO_NOT_MERGE (critical unfixed issues)
PROMPT

    # Save prompt for transparency
    cp "$PROMPT_FILE" "$OUTPUT_DIR/lift-review-prompt-$DATE-layer1.txt" 2>/dev/null

    echo "  🔍 Layer 1: $L1_MODEL..."
    DURATION=$(run_gemini "$L1_MODEL" "$OUTPUT_FILE" "$PROMPT_FILE" "$L1_TIMEOUT") && {
      echo "REVIEW_MODEL:$L1_MODEL" >> "$OUTPUT_FILE"
      echo "  ✅ Layer 1 ($L1_MODEL): ${DURATION}s"
    } || {
      echo "  ⚠️  Layer 1 primary ($L1_MODEL) failed — trying $L1_FALLBACK..."
      DURATION=$(run_claude "$L1_FALLBACK" "$OUTPUT_FILE" "$PROMPT_FILE" "$L1_TIMEOUT") && {
        echo "REVIEW_MODEL:$L1_FALLBACK" >> "$OUTPUT_FILE"
        echo "  ✅ Layer 1 fallback ($L1_FALLBACK): ${DURATION}s"
      } || {
        echo "  ❌ Layer 1: all reviewers failed — skipping"
        echo "REVIEW_VERDICT:REVIEW" > "$OUTPUT_FILE"
        echo "REVIEW_MODEL:skipped" >> "$OUTPUT_FILE"
      }
    }
    ensure_verdict "$OUTPUT_FILE"
    rm -f "$PROMPT_FILE"
    ;;

  layer2)
    # ── Layer 2: Gemini Pro — architecture ─────────────────────────────────
    DIFF_FILE="$1"; OUTPUT_FILE="$2"; shift 2
    PRIOR_FINDINGS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --prior-findings) PRIOR_FINDINGS=$(cat "$2" 2>/dev/null || echo ""); shift 2 ;;
        *) shift ;;
      esac
    done

    DIFF_CONTENT=$(cat "$DIFF_FILE")
    PROMPT_FILE=$(mktemp)

    cat > "$PROMPT_FILE" <<PROMPT
You are a senior engineer reviewing a pull request for a $TECH_STACK app ($PROJECT_NAME). Focus on architecture, not mechanical issues (those were already checked).

## Full Diff
$DIFF_CONTENT

## Layer 1 Findings (already reviewed for mechanical issues)
${PRIOR_FINDINGS:-No prior findings.}

## Your focus
1. Architecture — are changes cohesive? Do they follow Vue 3 Composition API patterns?
2. Cross-component interaction — could this change break other components?
3. Edge cases — what did the developer likely not consider?
4. Performance — unnecessary re-renders, large imports, missing lazy loading?
5. Accessibility completeness — not just aria-labels, but full keyboard nav, screen reader flow
6. What's MISSING — what should have been included but wasn't?

## Learnings from past reviews
$REVIEW_LEARNINGS

## Output format
For each finding:
REVIEW_FIX:<severity>:<file_path>:<one-line description>

For each Layer 1 finding, cross-check:
REVIEW_CROSSCHECK:<confirmed|disputed|elaborated>:<description>

Then output exactly one verdict:
REVIEW_VERDICT:MERGE (no architectural concerns)
REVIEW_VERDICT:REVIEW (has concerns needing human judgment)
REVIEW_VERDICT:DO_NOT_MERGE (critical architectural issues)
PROMPT

    cp "$PROMPT_FILE" "$OUTPUT_DIR/lift-review-prompt-$DATE-layer2.txt" 2>/dev/null

    echo "  🔍 Layer 2: $L2_MODEL..."
    DURATION=$(run_gemini "$L2_MODEL" "$OUTPUT_FILE" "$PROMPT_FILE" "$L2_TIMEOUT") && {
      echo "REVIEW_MODEL:$L2_MODEL" >> "$OUTPUT_FILE"
      echo "  ✅ Layer 2 ($L2_MODEL): ${DURATION}s"
    } || {
      echo "  ⚠️  Layer 2 primary ($L2_MODEL) failed — trying $L2_FALLBACK..."
      # Use the same deep prompt with the fallback model
      DURATION=$(run_gemini "$L2_FALLBACK" "$OUTPUT_FILE" "$PROMPT_FILE" "$L1_TIMEOUT") && {
        echo "REVIEW_MODEL:$L2_FALLBACK" >> "$OUTPUT_FILE"
        echo "  ✅ Layer 2 fallback ($L2_FALLBACK): ${DURATION}s"
      } || {
        echo "  ❌ Layer 2: all reviewers failed — skipping"
        echo "REVIEW_VERDICT:REVIEW" > "$OUTPUT_FILE"
        echo "REVIEW_MODEL:skipped" >> "$OUTPUT_FILE"
      }
    }
    ensure_verdict "$OUTPUT_FILE"
    rm -f "$PROMPT_FILE"
    ;;

  layer3)
    # ── Layer 3: Claude Sonnet — self-check + meta-review ──────────────────
    DIFF_FILE="$1"; OUTPUT_FILE="$2"; shift 2
    PRIOR_FINDINGS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --prior-findings) PRIOR_FINDINGS=$(cat "$2" 2>/dev/null || echo ""); shift 2 ;;
        *) shift ;;
      esac
    done

    DIFF_CONTENT=$(head -5000 "$DIFF_FILE")
    PROMPT_FILE=$(mktemp)

    cat > "$PROMPT_FILE" <<PROMPT
You are Claude Sonnet reviewing code written by Claude Opus for $PROJECT_NAME ($TECH_STACK). You have a unique role: you understand Opus's coding patterns and tendencies.

## Diff
$DIFF_CONTENT

## Findings from Gemini reviewers (Layers 1 + 2)
${PRIOR_FINDINGS:-No prior findings.}

## Your focus (self-check + meta-review)
1. Known Opus failure patterns — check the learnings below for patterns Opus consistently gets wrong
2. Validate Gemini findings — are they real or hallucinated? Gemini sometimes flags non-issues
3. Dispute false positives — if a Gemini finding is wrong, say so clearly
4. Catch what Gemini missed — things only someone who understands Opus's patterns would notice
5. Theme/contrast check — verify changes work on both light and dark themes
6. Safe-area/touch-target check — iOS PWA requirements

## Learnings from past reviews (CRITICAL — these are real patterns Opus gets wrong)
$REVIEW_LEARNINGS

## Output format
For each NEW finding (not already caught by Gemini):
REVIEW_FIX:<severity>:<file_path>:<one-line description>

For each Gemini finding, cross-check:
REVIEW_CROSSCHECK:<confirmed|disputed>:<description>

If you find a Gemini finding is a hallucination or false positive, mark it:
REVIEW_CROSSCHECK:disputed:<finding was incorrect because...>

Then output exactly one verdict:
REVIEW_VERDICT:MERGE (Gemini findings validated, no new concerns)
REVIEW_VERDICT:REVIEW (found new issues or disputed critical Gemini findings)
REVIEW_VERDICT:DO_NOT_MERGE (critical issues Gemini missed)
PROMPT

    cp "$PROMPT_FILE" "$OUTPUT_DIR/lift-review-prompt-$DATE-layer3.txt" 2>/dev/null

    echo "  🔍 Layer 3: $L3_MODEL..."
    DURATION=$(run_claude "$L3_MODEL" "$OUTPUT_FILE" "$PROMPT_FILE" "$L3_TIMEOUT") && {
      echo "REVIEW_MODEL:claude-$L3_MODEL" >> "$OUTPUT_FILE"
      echo "  ✅ Layer 3 ($L3_MODEL): ${DURATION}s"
    } || {
      echo "  ⚠️  Layer 3 primary ($L3_MODEL) failed — trying $L3_FALLBACK..."
      DURATION=$(run_claude "$L3_FALLBACK" "$OUTPUT_FILE" "$PROMPT_FILE" 60) && {
        echo "REVIEW_MODEL:claude-$L3_FALLBACK" >> "$OUTPUT_FILE"
        echo "  ✅ Layer 3 fallback ($L3_FALLBACK): ${DURATION}s"
      } || {
        echo "  ❌ Layer 3: all reviewers failed — skipping"
        echo "REVIEW_VERDICT:REVIEW" > "$OUTPUT_FILE"
        echo "REVIEW_MODEL:skipped" >> "$OUTPUT_FILE"
      }
    }
    ensure_verdict "$OUTPUT_FILE"
    rm -f "$PROMPT_FILE"
    ;;

  *)
    echo "Unknown ai-review command: $cmd" >&2
    echo "Usage: ai-review.sh {layer1|layer2|layer3} <diff_file> <output_file> [--prior-findings <file>]" >&2
    exit 1
    ;;
esac
