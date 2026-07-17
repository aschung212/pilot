#!/bin/bash
# Adapter: AI Research (Gemini API — Flash with Google Search grounding)
# Provides a unified interface for web research / general AI queries.
# To swap to ChatGPT/Perplexity/etc, rewrite this file.
#
# Usage:
#   ai-research.sh prompt <text> [--model <model>] [--output <file>] [--no-grounding]
#
# Prints the model's answer to stdout (or --output file). Diagnostics and error
# reasons go to stderr. Exit 0 = answer produced; non-zero = FAIL LOUD (caller
# should alert). Grounding (Google Search) is ON by default so research returns
# real URLs/versions instead of hallucinations; pass --no-grounding for pure
# reasoning tasks (e.g. triage) that don't need the web.
#
# Auth: uses the Gemini API key (GEMINI_API_KEY, exported from ~/.zshenv), NOT
# the `gemini` CLI. Google retired the free "Gemini Code Assist for individuals"
# OAuth tier on 2026-06-18 (IneligibleTierError / UNSUPPORTED_CLIENT), which
# silently broke every CLI research call. The API key works free for Flash
# models (Pro is billed). This talks to the REST endpoint directly, so it does
# not touch or depend on the interactive `gemini` CLI at all.

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
# Self-sufficient env loading: callers (discover.sh/triage.sh) already source
# ~/.zshenv, but make direct/manual invocation work too. GEMINI_API_KEY is
# exported from ~/.zshenv; project.env may override AI_RESEARCH_MODEL etc.
if [ -z "${_PILOT_TEST_MODE:-}" ]; then
  [ -z "${GEMINI_API_KEY:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null
  [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env" 2>/dev/null
fi

MODEL="${AI_RESEARCH_MODEL:-gemini-2.5-flash}"
TIMEOUT="${AI_RESEARCH_TIMEOUT:-120}"
GROUNDING="on"
OUTPUT_FILE=""
PROMPT_TEXT=""
API_BASE="${GEMINI_API_BASE:-https://generativelanguage.googleapis.com/v1beta}"

cmd="${1:-}"
shift || true

case "$cmd" in
  prompt)
    PROMPT_TEXT="${1:-}"; shift || true
    while [ $# -gt 0 ]; do
      case "$1" in
        --model)        MODEL="$2"; shift 2 ;;
        --output)       OUTPUT_FILE="$2"; shift 2 ;;
        --grounding)    GROUNDING="$2"; shift 2 ;;
        --no-grounding) GROUNDING="off"; shift ;;
        *) shift ;;
      esac
    done

    if [ -z "$PROMPT_TEXT" ]; then
      echo "ai-research: empty prompt" >&2
      exit 2
    fi
    if [ -z "${GEMINI_API_KEY:-}" ]; then
      echo "ai-research: GEMINI_API_KEY not set — cannot reach the Gemini API." >&2
      echo "ai-research: (the free 'gemini' CLI OAuth tier was retired 2026-06-18; this adapter needs the API key from ~/.zshenv)" >&2
      exit 3
    fi

    REQ_FILE=$(mktemp); RESP_FILE=$(mktemp); ERR_FILE=$(mktemp)
    trap 'rm -f "$REQ_FILE" "$RESP_FILE" "$ERR_FILE"' EXIT

    # Build the request body via python3 so prompt text is safely JSON-escaped
    # and the google_search grounding tool is attached when enabled.
    if ! PROMPT_TEXT="$PROMPT_TEXT" GROUNDING="$GROUNDING" python3 -c '
import json, os, sys
body = {"contents": [{"parts": [{"text": os.environ["PROMPT_TEXT"]}]}]}
if os.environ.get("GROUNDING", "on") != "off":
    body["tools"] = [{"google_search": {}}]
sys.stdout.write(json.dumps(body))
' > "$REQ_FILE" 2>"$ERR_FILE"; then
      echo "ai-research: failed to build request JSON — $(head -1 "$ERR_FILE" 2>/dev/null)" >&2
      exit 1
    fi

    URL="$API_BASE/models/${MODEL}:generateContent"
    HTTP_CODE=$(curl -sS --connect-timeout 20 --max-time "$TIMEOUT" \
      -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$URL" \
      -H 'Content-Type: application/json' \
      -H "x-goog-api-key: ${GEMINI_API_KEY}" \
      --data-binary @"$REQ_FILE" 2>"$ERR_FILE")
    CURL_RC=$?

    if [ "$CURL_RC" -ne 0 ]; then
      echo "ai-research: request failed (curl rc=$CURL_RC, timeout ${TIMEOUT}s?) model=$MODEL — $(head -1 "$ERR_FILE" 2>/dev/null)" >&2
      exit 1
    fi

    # Parse the response: extract candidate text, surface API errors.
    RESULT=$(HTTP_CODE="$HTTP_CODE" python3 -c '
import json, os, sys
code = os.environ.get("HTTP_CODE", "")
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("__ERR__ non-JSON response (HTTP %s)" % code); sys.exit(0)
if isinstance(d, dict) and d.get("error"):
    e = d["error"]
    print("__ERR__ API error %s: %s" % (e.get("code", code), (e.get("message") or "")[:200])); sys.exit(0)
try:
    parts = d["candidates"][0]["content"]["parts"]
    txt = "".join(p.get("text", "") for p in parts).strip()
except Exception:
    txt = ""
if not txt:
    fr = ""
    try: fr = d["candidates"][0].get("finishReason", "")
    except Exception: pass
    print("__ERR__ empty result (HTTP %s%s)" % (code, ", finishReason=%s" % fr if fr else "")); sys.exit(0)
sys.stdout.write(txt)
' "$RESP_FILE" 2>/dev/null)

    if [ "$HTTP_CODE" != "200" ] || [ -z "$RESULT" ] || [ "${RESULT#__ERR__}" != "$RESULT" ]; then
      REASON="${RESULT#__ERR__ }"
      { [ -z "$REASON" ] || [ "$REASON" = "$RESULT" ]; } && REASON="HTTP $HTTP_CODE ($(head -c 200 "$RESP_FILE" 2>/dev/null))"
      echo "ai-research: Gemini request failed — $REASON (model=$MODEL)" >&2
      exit 1
    fi

    if [ -n "$OUTPUT_FILE" ]; then
      printf '%s\n' "$RESULT" > "$OUTPUT_FILE"
    else
      printf '%s\n' "$RESULT"
    fi
    ;;

  *)
    echo "Unknown ai-research command: $cmd" >&2
    echo "Usage: ai-research.sh prompt <text> [--model <model>] [--output <file>] [--no-grounding]" >&2
    exit 1
    ;;
esac
