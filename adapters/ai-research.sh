#!/bin/bash
# Adapter: AI Research (default: Gemini CLI)
# Provides a unified interface for web research / general AI queries.
# To swap to ChatGPT/Perplexity/etc, rewrite this file.
#
# Usage:
#   ai-research.sh prompt <text> [--model <model>] [--output <file>]
#
# Outputs result to stdout (or file if --output specified).
# Filters Gemini's noisy startup lines automatically.

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

MODEL="${AI_RESEARCH_MODEL:-gemini-2.5-flash}"
OUTPUT_FILE=""
PROMPT_TEXT=""

cmd="${1:-}"
shift || true

case "$cmd" in
  prompt)
    PROMPT_TEXT="$1"; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    FILTER='grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt"'

    if [ -n "$OUTPUT_FILE" ]; then
      gemini -p "$PROMPT_TEXT" -m "$MODEL" --sandbox 2>&1 | eval "$FILTER" > "$OUTPUT_FILE" 2>/dev/null || true
    else
      gemini -p "$PROMPT_TEXT" -m "$MODEL" --sandbox 2>&1 | eval "$FILTER" || true
    fi
    ;;

  *)
    echo "Unknown ai-research command: $cmd" >&2
    echo "Usage: ai-research.sh prompt <text> [--model <model>] [--output <file>]" >&2
    exit 1
    ;;
esac
