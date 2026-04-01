#!/bin/bash
# Adapter: AI Code Review (default: Claude Sonnet + Gemini Flash)
# Provides a unified interface for multi-layer PR review.
# To swap models or add/remove layers, modify this file.
#
# Usage:
#   ai-review.sh layer1 <prompt> [--json-output <file>]   # adversarial review (Claude Sonnet)
#   ai-review.sh layer2 <prompt> [--output <file>]         # architecture review (Gemini Flash)

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

REVIEW_MODEL="${AI_REVIEW_MODEL:-sonnet}"
RESEARCH_MODEL="${AI_RESEARCH_MODEL:-gemini-2.5-flash}"

cmd="${1:-}"
shift || true

case "$cmd" in
  layer1)
    # Claude adversarial review
    PROMPT_TEXT="$1"; shift
    JSON_OUTPUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json-output) JSON_OUTPUT="$2"; shift 2 ;;
        --model) REVIEW_MODEL="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    if [ -n "$JSON_OUTPUT" ]; then
      claude --dangerously-skip-permissions --output-format json --model "$REVIEW_MODEL" \
        -p "$PROMPT_TEXT" --max-turns 5 2>&1 > "$JSON_OUTPUT"
    else
      claude --dangerously-skip-permissions --model "$REVIEW_MODEL" \
        -p "$PROMPT_TEXT" --max-turns 5 2>&1
    fi
    ;;

  layer2)
    # Gemini architecture/UX review
    PROMPT_TEXT="$1"; shift
    OUTPUT_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --model) RESEARCH_MODEL="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    FILTER='grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt"'

    if [ -n "$OUTPUT_FILE" ]; then
      gemini -p "$PROMPT_TEXT" -m "$RESEARCH_MODEL" --sandbox 2>&1 | eval "$FILTER" > "$OUTPUT_FILE" 2>/dev/null || true
    else
      gemini -p "$PROMPT_TEXT" -m "$RESEARCH_MODEL" --sandbox 2>&1 | eval "$FILTER" || true
    fi
    ;;

  *)
    echo "Unknown ai-review command: $cmd" >&2
    echo "Usage: ai-review.sh {layer1|layer2} <prompt> [options]" >&2
    exit 1
    ;;
esac
