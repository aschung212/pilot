#!/bin/bash
# Captures PR screenshots from a temporary local dev server in the worktree.
# Used by builder.sh after PR creation; safe to run standalone for testing.
#
# Usage:
#   capture-pr-screenshots.sh <repo-dir> <output-dir> <route1> [route2 ...]
#
# Env vars (optional, used for INDEX.md):
#   PR_TITLE, PR_URL, ISSUE_ID
#
# Exits 0 even on capture failures — best-effort, never blocks the builder.

set -uo pipefail

REPO_DIR="${1:?repo dir required}"
OUTPUT_DIR="${2:?output dir required}"
shift 2
ROUTES="$*"

if [ -z "$ROUTES" ]; then
  echo "  ⚠️  No routes provided — skipping screenshot capture"
  exit 0
fi

if [ ! -d "$REPO_DIR/node_modules/@playwright" ]; then
  echo "  ⚠️  Playwright not installed in $REPO_DIR — skipping screenshot capture"
  exit 0
fi

# Pick a free port to avoid clashing with Aaron's local dev server on 5173.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo "5174")
BASE_URL="http://localhost:$PORT"
LOG_FILE=$(mktemp -t pr-screenshot-dev.XXXXXX.log)
DEV_PID=""

cleanup() {
  if [ -n "$DEV_PID" ] && kill -0 "$DEV_PID" 2>/dev/null; then
    # Kill the whole process group — vite spawns children that don't die with the parent.
    kill -TERM -- "-$DEV_PID" 2>/dev/null || kill -TERM "$DEV_PID" 2>/dev/null
    sleep 1
    kill -KILL -- "-$DEV_PID" 2>/dev/null || kill -KILL "$DEV_PID" 2>/dev/null
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT INT TERM

echo "  🚀 Starting dev server on port $PORT…"
cd "$REPO_DIR" || { echo "  ❌ Could not cd to $REPO_DIR"; exit 0; }
# setsid so we get a process group we can kill cleanly. macOS doesn't have setsid, so
# fall back to plain background — vite's child cleanup is mostly OK on macOS.
if command -v setsid >/dev/null 2>&1; then
  setsid npm run dev -- --port "$PORT" --strictPort > "$LOG_FILE" 2>&1 &
else
  npm run dev -- --port "$PORT" --strictPort > "$LOG_FILE" 2>&1 &
fi
DEV_PID=$!

# Wait for dev server to respond (max ~30s).
READY=false
for _ in $(seq 1 30); do
  if curl -fsS "$BASE_URL" -o /dev/null 2>&1; then
    READY=true
    break
  fi
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    echo "  ❌ Dev server died — last log lines:"
    tail -10 "$LOG_FILE" | sed 's/^/    /'
    exit 0
  fi
  sleep 1
done

if [ "$READY" != "true" ]; then
  echo "  ❌ Dev server did not become ready within 30s"
  exit 0
fi

echo "  ✓ Dev server up — capturing ${#@} route(s)"
mkdir -p "$OUTPUT_DIR"

# Pass routes to node via newline-separated env var.
ROUTES_NL=$(printf '%s\n' "$@")

BASE_URL="$BASE_URL" \
OUTPUT_DIR="$OUTPUT_DIR" \
ROUTES="$ROUTES_NL" \
REPO_DIR="$REPO_DIR" \
PR_TITLE="${PR_TITLE:-}" \
PR_URL="${PR_URL:-}" \
ISSUE_ID="${ISSUE_ID:-}" \
node "$(dirname "$0")/capture-pr-screenshots.mjs" || echo "  ⚠️  Screenshot capture had errors (continuing)"

echo "  ✓ Screenshots saved to: $OUTPUT_DIR"
