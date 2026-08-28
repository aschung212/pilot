#!/bin/bash
# Adapter: AI Code Generation (default: Claude CLI)
# Provides a unified interface for code generation tasks.
# To swap models, change AI_CODE_MODEL in project.env.
#
# Usage:
#   ai-code.sh run <prompt> [--max-turns <n>] [--json-output <file>] [--model <model>] [--effort <level>]
#   Defaults: model = $AI_CODE_MODEL, effort = $AI_CODE_EFFORT (see project.env)
#
# Outputs result to stdout. If --json-output specified, writes full
# JSON response (with usage stats) to that file.

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

MODEL="${AI_CODE_MODEL:-claude-opus-5[1m]}"
EFFORT="${AI_CODE_EFFORT:-max}"
MAX_TURNS="${BUILDER_MAX_TURNS:-100}"
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
        --effort) EFFORT="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    if [ -n "$JSON_OUTPUT" ]; then
      claude --allowedTools "Read,Edit,Write,Glob,Grep,Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git checkout:*),Bash(git branch:*),Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git fetch:*),Bash(git merge:*),Bash(git show:*),Bash(git rev-parse:*),Bash(gh:*),Bash(npm:*),Bash(npx:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(mkdir:*)" --output-format json --model "$MODEL" --effort "$EFFORT" \
        -p "$PROMPT_TEXT" --max-turns "$MAX_TURNS" 2>&1 > "$JSON_OUTPUT"
    else
      claude --allowedTools "Read,Edit,Write,Glob,Grep,Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git checkout:*),Bash(git branch:*),Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git fetch:*),Bash(git merge:*),Bash(git show:*),Bash(git rev-parse:*),Bash(gh:*),Bash(npm:*),Bash(npx:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(mkdir:*)" --model "$MODEL" --effort "$EFFORT" \
        -p "$PROMPT_TEXT" --max-turns "$MAX_TURNS" 2>&1
    fi
    ;;

  *)
    echo "Unknown ai-code command: $cmd" >&2
    echo "Usage: ai-code.sh run <prompt> [--max-turns <n>] [--json-output <file>] [--model <model>] [--effort <level>]" >&2
    exit 1
    ;;
esac
