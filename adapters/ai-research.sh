#!/bin/bash
# Adapter: AI Research — web research / general AI queries.
# Two backends behind one interface:
#   gemini (default) — Gemini API Flash + Google Search grounding. Free, fast (~50s),
#                      but returns UNCITED prose: measured 2026-08-30, 0 URLs on a
#                      prompt explicitly demanding them (0 URLs in 13 of 14 runs since
#                      the REST migration). Grounding citations do come back in
#                      `groundingMetadata` but this adapter does not surface them yet.
#   claude          — headless `claude -p` with WebSearch/WebFetch. Costs plan tokens,
#                      slower (~140s on Sonnet 5), but cites: 24 URLs / 14 domains on
#                      the same prompt, 13/14 resolving, with App Store versions and
#                      ratings that verify exactly against Apple's API. It also flags
#                      what it could NOT source instead of inventing it.
# To swap in ChatGPT/Perplexity/etc, add a third backend here — callers do not change.
#
# Usage:
#   ai-research.sh prompt <text> [--model <model>] [--output <file>] [--no-grounding]
#                                [--backend gemini|claude]
#
# --no-grounding means "no web access" on BOTH backends (pure reasoning over the
# prompt, e.g. triage). Backend default comes from AI_RESEARCH_BACKEND.
#
# Prints the model's answer to stdout (or --output file). Diagnostics and error
# reasons go to stderr. Exit 0 = answer produced; non-zero = FAIL LOUD (caller
# should alert). Grounding (Google Search) is ON by default so research returns
# real URLs/versions instead of hallucinations; pass --no-grounding for pure
# reasoning tasks (e.g. triage) that don't need the web. When grounding is on,
# a "Sources" section listing the domains the model actually read is appended
# to the answer (the answer text itself is never cited by the API).
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
BACKEND="${AI_RESEARCH_BACKEND:-gemini}"
# Claude-backend knobs. Sonnet 5, not Opus: on the 2026-08-30 bake-off Opus produced
# marginally better facts but took 1187s and ~6x the tokens, largely by fanning out to
# Task subagents — which is why Task is disallowed below. A nightly step that runs
# ahead of triage and the builder cannot spend 20 minutes on Phase 1.
CLAUDE_MODEL="${AI_RESEARCH_CLAUDE_MODEL:-claude-sonnet-5}"
CLAUDE_TIMEOUT="${AI_RESEARCH_CLAUDE_TIMEOUT:-420}"
CLAUDE_MAX_TURNS="${AI_RESEARCH_CLAUDE_MAX_TURNS:-30}"
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
        --backend)      BACKEND="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    if [ -z "$PROMPT_TEXT" ]; then
      echo "ai-research: empty prompt" >&2
      exit 2
    fi

    case "$BACKEND" in
      gemini|claude) ;;
      *) echo "ai-research: unknown backend '$BACKEND' (expected 'gemini' or 'claude')" >&2; exit 2 ;;
    esac

    # ── Claude backend ───────────────────────────────────────────────────────
    # Same contract as the Gemini path: answer on stdout (or --output), reason on
    # stderr, exit 0 = answer produced, non-zero = FAIL LOUD.
    if [ "$BACKEND" = "claude" ]; then
      if ! command -v claude >/dev/null 2>&1; then
        echo "ai-research: claude CLI not found on PATH — cannot use the claude backend." >&2
        exit 3
      fi

      # Task is disallowed on purpose: an unbounded subagent fan-out is what made the
      # Opus arm of the 2026-08-30 bake-off take 1187s. Bash/Edit/Write are disallowed
      # because research reads the web, it does not touch the machine.
      if [ "$GROUNDING" = "off" ]; then
        C_ALLOW=""
        C_DENY="WebSearch,WebFetch,Task,Bash,Edit,Write"
        C_TURNS=1
      else
        C_ALLOW="WebSearch,WebFetch"
        C_DENY="Task,Bash,Edit,Write"
        C_TURNS="$CLAUDE_MAX_TURNS"
      fi

      C_JSON=$(mktemp); C_ERR=$(mktemp); C_FIRED=$(mktemp)
      rm -f "$C_FIRED"
      trap 'rm -f "$C_JSON" "$C_ERR" "$C_FIRED"' EXIT

      # Wall-clock guard. There is no gtimeout on this host, so poll-and-kill the
      # process tree the way lib/builder-utils.sh does — a hung claude call silently
      # blocked the launchd builder for 5 days on 2026-07-09.
      if [ -n "$C_ALLOW" ]; then
        claude --allowedTools "$C_ALLOW" --disallowedTools "$C_DENY" --model "$CLAUDE_MODEL" \
          --output-format json -p "$PROMPT_TEXT" --max-turns "$C_TURNS" > "$C_JSON" 2>"$C_ERR" &
      else
        claude --disallowedTools "$C_DENY" --model "$CLAUDE_MODEL" \
          --output-format json -p "$PROMPT_TEXT" --max-turns "$C_TURNS" > "$C_JSON" 2>"$C_ERR" &
      fi
      C_PID=$!
      (
        waited=0
        while [ "$waited" -lt "$CLAUDE_TIMEOUT" ]; do
          kill -0 "$C_PID" 2>/dev/null || exit 0
          sleep 1
          waited=$((waited + 1))
        done
        # Sentinel so the caller can say "timed out" instead of "unparseable output" —
        # a killed claude leaves a truncated JSON file, and reporting that as a parse
        # error sends whoever reads the 3am Slack alert after the wrong bug.
        : > "$C_FIRED"
        pkill -P "$C_PID" 2>/dev/null
        kill -9 "$C_PID" 2>/dev/null
      ) >/dev/null 2>&1 &
      C_WATCHDOG=$!
      wait "$C_PID" 2>/dev/null; C_RC=$?
      kill "$C_WATCHDOG" 2>/dev/null; wait "$C_WATCHDOG" 2>/dev/null

      # Bun prints "warn: CPU lacks AVX support ..." on this host, so a captured
      # stream is not valid JSON at line 1 — scan for the first line starting with
      # '{' rather than json.load()-ing the whole file, and strip a ```json fence
      # off the inner result. This broke every pre-pick on 2026-05-19.
      C_RESULT=$(python3 -c '
import json, re, sys
try:
    lines = open(sys.argv[1]).read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.lstrip().startswith("{"))
    d = json.loads("\n".join(lines[start:]))
except Exception as e:
    print("__ERR__ unparseable claude output (%s)" % type(e).__name__); sys.exit(0)
if d.get("is_error"):
    print("__ERR__ claude reported is_error (subtype=%s)" % d.get("subtype", "?")); sys.exit(0)
txt = (d.get("result") or "").strip()
txt = re.sub(r"^```(?:json|markdown)?\s*\n", "", txt)
txt = re.sub(r"\n```\s*$", "", txt)
if not txt:
    print("__ERR__ empty result from claude"); sys.exit(0)
sys.stdout.write(txt)
' "$C_JSON" 2>/dev/null)

      if [ -f "$C_FIRED" ]; then
        echo "ai-research: Claude request timed out after ${CLAUDE_TIMEOUT}s — killed the hung call (model=$CLAUDE_MODEL)" >&2
        exit 1
      fi

      if [ "$C_RC" -ne 0 ] || [ -z "$C_RESULT" ] || [ "${C_RESULT#__ERR__}" != "$C_RESULT" ]; then
        C_REASON="${C_RESULT#__ERR__ }"
        { [ -z "$C_REASON" ] || [ "$C_REASON" = "$C_RESULT" ]; } && C_REASON="exit $C_RC — $(head -c 200 "$C_ERR" 2>/dev/null)"
        echo "ai-research: Claude request failed — $C_REASON (model=$CLAUDE_MODEL)" >&2
        exit 1
      fi

      if [ -n "$OUTPUT_FILE" ]; then
        printf '%s\n' "$C_RESULT" > "$OUTPUT_FILE"
      else
        printf '%s\n' "$C_RESULT"
      fi
      exit 0
    fi

    # ── Gemini backend (default) ─────────────────────────────────────────────
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

    # Parse the response: extract candidate text, append grounding citations,
    # surface API errors.
    RESULT=$(HTTP_CODE="$HTTP_CODE" GROUNDING="$GROUNDING" python3 -c '
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

# Grounding citations. A grounded call returns the pages it actually read in
# candidates[0].groundingMetadata.groundingChunks[].web{title,uri}; the answer
# text itself carries no URLs. Discarding the metadata is why research arrived
# uncited (0 URLs in 13 of 14 runs after the REST migration) even though the
# discovery prompt demands them. The web.title is a real domain and is the
# durable half of a citation; web.uri is an opaque
# vertexaisearch.cloud.google.com redirect that expires, so it is secondary.
# Best-effort by design: any malformed metadata is skipped rather than allowed
# to cost us an otherwise-good answer.
if os.environ.get("GROUNDING", "on") != "off":
    try:
        meta = d["candidates"][0].get("groundingMetadata") or {}
        chunks = meta.get("groundingChunks") or []
        seen = set()
        sources = []
        for c in chunks:
            web = (c or {}).get("web") or {}
            title = (web.get("title") or "").strip()
            uri = (web.get("uri") or "").strip()
            if not title and not uri:
                continue
            key = title.lower() or uri
            if key in seen:
                continue
            seen.add(key)
            sources.append("%s%s" % (title or "(untitled source)", " — %s" % uri if uri else ""))
        if sources:
            txt += "\n\n---\nSources (%d, via Google Search grounding). " % len(sources)
            txt += "The domain is the durable reference; the vertexaisearch.cloud.google.com links are grounding redirects that expire:\n"
            txt += "\n".join("%d. %s" % (i, s) for i, s in enumerate(sources, 1))
    except Exception:
        pass

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
