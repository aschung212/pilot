#!/bin/bash
# Adapter: AI Code Generation (default: Claude CLI)
# Provides a unified interface for code generation tasks.
# To swap models, change AI_CODE_MODEL in project.env.
#
# Usage:
#   ai-code.sh run <prompt> [--max-turns <n>] [--json-output <file>]
#
# Outputs result to stdout. If --json-output specified, writes full
# JSON response (with usage stats) to that file.

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

MODEL="${AI_CODE_MODEL:-opus}"
MAX_TURNS=100
JSON_OUTPUT=""
PROMPT_TEXT=""

cmd="${1:-}"
shift || true

case "$cmd" in
  run)
    PROMPT_TEXT="$1"; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --max-turns) MAX_TURNS="$2"; shift 2 ;;
        --json-output) JSON_OUTPUT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    if [ -n "$JSON_OUTPUT" ]; then
      claude --dangerously-skip-permissions --output-format json --model "$MODEL" \
        -p "$PROMPT_TEXT" --max-turns "$MAX_TURNS" 2>&1 > "$JSON_OUTPUT"
    else
      claude --dangerously-skip-permissions --model "$MODEL" \
        -p "$PROMPT_TEXT" --max-turns "$MAX_TURNS" 2>&1
    fi
    ;;

  *)
    echo "Unknown ai-code command: $cmd" >&2
    echo "Usage: ai-code.sh run <prompt> [--max-turns <n>] [--json-output <file>]" >&2
    exit 1
    ;;
esac
