#!/bin/bash
# Pilot — Interactive Setup Wizard
# Walks you through configuring the pipeline for your project.
#
# Usage:
#   ./init.sh           # interactive setup
#   ./init.sh --check   # verify existing installation

set -euo pipefail

PILOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Colors ────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
RESET='\033[0m'

say()  { echo -e "${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET} $1"; }
fail() { echo -e "${RED}✗${RESET} $1"; }
ask()  { echo -en "${BLUE}?${RESET} $1"; }

# ── Check mode ────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  say "Pilot Installation Check"
  echo ""
  ERRORS=0

  # Check project.env
  if [ -f "$PILOT_DIR/project.env" ]; then
    ok "project.env exists"
    source "$PILOT_DIR/project.env"
  else
    fail "project.env not found — run ./init.sh to create it"
    ERRORS=$((ERRORS + 1))
  fi

  # Check tools
  for tool in claude gemini linear gh git node npm; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool installed ($(command -v "$tool"))"
    else
      if [ "$tool" = "gemini" ]; then
        warn "$tool not found (optional — discovery research will be limited)"
      else
        fail "$tool not found"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done

  # Check optional tools
  if command -v bats &>/dev/null; then
    ok "bats installed"
  else
    warn "bats not found — test suite won't run"
  fi

  if command -v parallel &>/dev/null; then
    ok "parallel installed"
  else
    warn "parallel not found — tests run slower"
  fi

  if command -v gtimeout &>/dev/null; then
    ok "gtimeout installed"
  else
    warn "gtimeout not found — review timeouts use fallback"
  fi

  # Check launchd
  LOADED=$(launchctl list 2>/dev/null | grep -c "pilot" || echo "0")
  if [ "$LOADED" -gt 0 ]; then
    ok "$LOADED launchd services loaded"
  else
    warn "No launchd services loaded — run ./init.sh to install them"
  fi

  # Check Slack
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    ok "SLACK_BOT_TOKEN set (threading enabled)"
  elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    ok "SLACK_WEBHOOK_URL set (webhooks only, no threading)"
  else
    warn "No Slack config — notifications disabled"
  fi

  [ "$ERRORS" -eq 0 ] && ok "All checks passed" || fail "$ERRORS issues found"
  exit "$ERRORS"
fi

# ── Interactive Setup ─────────────────────────────────────────
echo ""
say "╔══════════════════════════════════════╗"
say "║         Pilot — Setup Wizard         ║"
say "╚══════════════════════════════════════╝"
echo ""
echo "This will configure the autonomous pipeline for your project."
echo "Press Ctrl+C at any time to abort."
echo ""

# ── 1. Project Basics ─────────────────────────────────────────
say "1. Project Basics"
echo ""

ask "Project name: "
read -r PROJECT_NAME
[ -z "$PROJECT_NAME" ] && { fail "Project name required"; exit 1; }

ask "Path to your project repo: "
read -r REPO_PATH
REPO_PATH="${REPO_PATH/#\~/$HOME}"
[ ! -d "$REPO_PATH/.git" ] && { fail "$REPO_PATH is not a git repo"; exit 1; }
ok "Found git repo at $REPO_PATH"

ask "GitHub remote (e.g., username/repo): "
read -r GITHUB_REPO

ask "Default branch (main/master) [main]: "
read -r DEFAULT_BRANCH
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

ask "Brief project description (for AI prompts): "
read -r PROJECT_DESC

ask "Tech stack (e.g., 'Vue 3 + TypeScript PWA', 'Next.js + Prisma'): "
read -r TECH_STACK

echo ""

# ── 2. Issue Tracker ──────────────────────────────────────────
say "2. Issue Tracker"
echo ""
echo "  1) Linear (recommended)"
echo "  2) GitHub Issues"
echo ""
ask "Choose [1]: "
read -r TRACKER_CHOICE
TRACKER_CHOICE="${TRACKER_CHOICE:-1}"

LINEAR_TEAM=""
LINEAR_PROJECT=""
LINEAR_ORG=""

case "$TRACKER_CHOICE" in
  1)
    if ! command -v linear &>/dev/null; then
      warn "Linear CLI not found. Install: npm install -g @anthropic-ai/linear-cli"
      warn "Then run: linear auth"
    else
      ok "Linear CLI found"
    fi
    ask "Linear team key (e.g., MAS, ENG): "
    read -r LINEAR_TEAM
    ask "Linear project name: "
    read -r LINEAR_PROJECT
    ask "Linear org slug (from your Linear URL): "
    read -r LINEAR_ORG
    TRACKER_ADAPTER="linear"
    ;;
  2)
    TRACKER_ADAPTER="github"
    warn "GitHub Issues adapter — you may need to customize adapters/tracker.sh"
    ;;
esac

echo ""

# ── 3. AI Models ──────────────────────────────────────────────
say "3. AI Models"
echo ""

if command -v claude &>/dev/null; then
  ok "Claude CLI found"
else
  fail "Claude CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
fi

ask "Code generation model [opus]: "
read -r AI_CODE_MODEL
AI_CODE_MODEL="${AI_CODE_MODEL:-opus}"

if command -v gemini &>/dev/null; then
  ok "Gemini CLI found"
  ask "Research model [gemini-2.5-flash]: "
  read -r AI_RESEARCH_MODEL
  AI_RESEARCH_MODEL="${AI_RESEARCH_MODEL:-gemini-2.5-flash}"
else
  warn "Gemini CLI not found (optional). Skipping research model."
  AI_RESEARCH_MODEL=""
fi

echo ""
say "   Review Pipeline"
echo ""
echo "  The review pipeline uses 3 layers with different models:"
echo "    L1 — mechanical gate (per-iteration, fast)"
echo "    L2 — architecture review (per-PR, thorough)"
echo "    L3 — self-check (per-PR, catches what L1+L2 missed)"
echo ""
ask "Use 3-layer cross-model review? (y/n) [y]: "
read -r USE_3LAYER
USE_3LAYER="${USE_3LAYER:-y}"

if [ "$USE_3LAYER" = "y" ]; then
  ask "L1 model (mechanical gate) [gemini-2.5-flash]: "
  read -r AI_REVIEW_MODEL_L1
  AI_REVIEW_MODEL_L1="${AI_REVIEW_MODEL_L1:-gemini-2.5-flash}"

  ask "L2 model (architecture) [gemini-2.5-pro]: "
  read -r AI_REVIEW_MODEL_L2
  AI_REVIEW_MODEL_L2="${AI_REVIEW_MODEL_L2:-gemini-2.5-pro}"

  ask "L3 model (self-check) [sonnet]: "
  read -r AI_REVIEW_MODEL_L3
  AI_REVIEW_MODEL_L3="${AI_REVIEW_MODEL_L3:-sonnet}"

  AI_REVIEW_FALLBACK_L1="sonnet"
  AI_REVIEW_FALLBACK_L2="gemini-2.5-flash"
  AI_REVIEW_FALLBACK_L3="haiku"
  AI_REVIEW_TIMEOUT_L1=90
  AI_REVIEW_TIMEOUT_L2=120
  AI_REVIEW_TIMEOUT_L3=90
else
  ask "Single review model [sonnet]: "
  read -r SINGLE_REVIEW_MODEL
  SINGLE_REVIEW_MODEL="${SINGLE_REVIEW_MODEL:-sonnet}"
  AI_REVIEW_MODEL_L1="$SINGLE_REVIEW_MODEL"
  AI_REVIEW_MODEL_L2="$SINGLE_REVIEW_MODEL"
  AI_REVIEW_MODEL_L3="$SINGLE_REVIEW_MODEL"
  AI_REVIEW_FALLBACK_L1="haiku"
  AI_REVIEW_FALLBACK_L2="haiku"
  AI_REVIEW_FALLBACK_L3="haiku"
  AI_REVIEW_TIMEOUT_L1=90
  AI_REVIEW_TIMEOUT_L2=90
  AI_REVIEW_TIMEOUT_L3=90
fi

echo ""

# ── 4. Notifications ──────────────────────────────────────────
say "4. Slack Notifications (optional)"
echo ""
echo "  For threading support, you need a Slack Bot Token (chat:write scope)."
echo "  For basic notifications, incoming webhooks are sufficient."
echo ""

SLACK_CHANNEL_AUTOMATION=""
SLACK_CHANNEL_REVIEW=""
SLACK_CHANNEL_CHANGELOG=""

ask "Set up Slack? (y/n) [y]: "
read -r SETUP_SLACK
SETUP_SLACK="${SETUP_SLACK:-y}"

if [ "$SETUP_SLACK" = "y" ]; then
  echo ""
  echo "  ⚠️  Do NOT paste tokens here if this output is being logged."
  echo "  Add SLACK_BOT_TOKEN and SLACK_WEBHOOK_URL to ~/.zshenv manually."
  echo ""
  ask "Primary notification channel ID (e.g., C0AQAEXQWBT): "
  read -r SLACK_CHANNEL_AUTOMATION
  ask "Daily review channel ID (or press Enter to skip): "
  read -r SLACK_CHANNEL_REVIEW
  ask "System changelog channel ID (or press Enter to skip): "
  read -r SLACK_CHANNEL_CHANGELOG
fi

echo ""

# ── 5. Scheduling ─────────────────────────────────────────────
say "5. Scheduling"
echo ""
echo "  Discovery + triage run on select nights (default: Sun/Tue/Thu)."
echo "  Builder runs on weeknights (default: Mon-Fri)."
echo ""

ask "Discovery days (comma-separated, 0=Sun..6=Sat) [0,2,4]: "
read -r DISCOVER_DAYS
DISCOVER_DAYS="${DISCOVER_DAYS:-0,2,4}"

ask "Builder days [1,2,3,4,5]: "
read -r BUILDER_DAYS
BUILDER_DAYS="${BUILDER_DAYS:-1,2,3,4,5}"

ask "Builder stop time [07:00]: "
read -r BUILDER_STOP_TIME
BUILDER_STOP_TIME="${BUILDER_STOP_TIME:-07:00}"

echo ""

# ── 6. Discovery Focus Areas ──────────────────────────────────
say "6. Discovery Focus Areas"
echo ""
echo "  These determine what the discovery agent researches."
echo "  Common areas based on your tech stack ($TECH_STACK):"
echo ""
echo "  1) competitors       — competitor analysis, feature gaps"
echo "  2) performance       — bundle size, rendering, caching"
echo "  3) ui-trends         — design patterns, UX improvements"
echo "  4) accessibility     — WCAG, screen readers, contrast"
echo "  5) testing           — test coverage, patterns, tools"
echo "  6) security-deps     — vulnerabilities, CSP, auth"
echo "  7) pwa-patterns      — offline, install, push notifications"
echo "  8) seo-aso           — meta tags, structured data, discoverability"
echo "  9) data-viz          — charts, dashboards, data display"
echo "  10) onboarding       — first-run UX, empty states, tutorials"
echo "  11) dx-cicd          — CI/CD, build tools, developer experience"
echo "  12) monetization     — pricing, freemium, revenue"
echo ""
ask "Enter numbers to include (comma-separated) [1,2,3,4,5,6]: "
read -r FOCUS_CHOICES
FOCUS_CHOICES="${FOCUS_CHOICES:-1,2,3,4,5,6}"

FOCUS_MAP=("" "competitors" "performance" "ui-trends" "accessibility" "testing" "security-deps" "pwa-patterns" "seo-aso" "data-viz" "onboarding" "dx-cicd" "monetization")
FOCUS_AREAS=""
IFS=',' read -ra CHOICES <<< "$FOCUS_CHOICES"
for c in "${CHOICES[@]}"; do
  c=$(echo "$c" | tr -d ' ')
  [ -n "${FOCUS_MAP[$c]:-}" ] && FOCUS_AREAS+="${FOCUS_MAP[$c]}\n"
done

echo ""

# ── Write project.env ─────────────────────────────────────────
say "Writing project.env..."

cat > "$PILOT_DIR/project.env" << ENV_EOF
# Pilot — $PROJECT_NAME Configuration
# Generated by init.sh on $(date +%Y-%m-%d)

# ── Project ──────────────────────────────────────────────────
PROJECT_NAME="$PROJECT_NAME"
PROJECT_DESC="$PROJECT_DESC"
TECH_STACK="$TECH_STACK"
REPO_PATH="$REPO_PATH"
GITHUB_REPO="$GITHUB_REPO"
DEFAULT_BRANCH="$DEFAULT_BRANCH"

# ── Issue Tracker ────────────────────────────────────────────
TRACKER_ADAPTER="$TRACKER_ADAPTER"
LINEAR_TEAM="$LINEAR_TEAM"
LINEAR_PROJECT="$LINEAR_PROJECT"
LINEAR_ORG="$LINEAR_ORG"

# ── AI Models ────────────────────────────────────────────────
AI_CODE_MODEL="$AI_CODE_MODEL"
AI_RESEARCH_MODEL="$AI_RESEARCH_MODEL"

# Review pipeline (3-layer cross-model)
AI_REVIEW_MODEL_L1="$AI_REVIEW_MODEL_L1"
AI_REVIEW_MODEL_L2="$AI_REVIEW_MODEL_L2"
AI_REVIEW_MODEL_L3="$AI_REVIEW_MODEL_L3"
AI_REVIEW_FALLBACK_L1="$AI_REVIEW_FALLBACK_L1"
AI_REVIEW_FALLBACK_L2="$AI_REVIEW_FALLBACK_L2"
AI_REVIEW_FALLBACK_L3="$AI_REVIEW_FALLBACK_L3"
AI_REVIEW_TIMEOUT_L1=$AI_REVIEW_TIMEOUT_L1
AI_REVIEW_TIMEOUT_L2=$AI_REVIEW_TIMEOUT_L2
AI_REVIEW_TIMEOUT_L3=$AI_REVIEW_TIMEOUT_L3

# ── Notifications ────────────────────────────────────────────
# Webhooks and bot token should be set in ~/.zshenv
SLACK_CHANNEL_AUTOMATION="$SLACK_CHANNEL_AUTOMATION"
SLACK_CHANNEL_REVIEW="$SLACK_CHANNEL_REVIEW"
SLACK_CHANNEL_CHANGELOG="$SLACK_CHANNEL_CHANGELOG"

# ── Scheduling ───────────────────────────────────────────────
DISCOVER_DAYS="$DISCOVER_DAYS"
BUILDER_DAYS="$BUILDER_DAYS"
BUILDER_STOP_TIME="$BUILDER_STOP_TIME"

# ── Paths ────────────────────────────────────────────────────
PILOT_DIR="$PILOT_DIR"
SCRIPTS_DIR="$PILOT_DIR/scripts"
ADAPTER_DIR="$PILOT_DIR/adapters"
OUTPUT_DIR="\$HOME/Documents/Claude/outputs"
PRODUCT_DECISIONS_FILE=""
PRODUCT_FEATURES_FILE=""
ENV_EOF

ok "project.env written"

# ── Git hooks ────────────────────────────────────────────────
if [ -d "$REPO_PATH/.git" ]; then
  git -C "$REPO_PATH" config core.hooksPath .githooks && ok "Git hooks configured"
fi

# ── Budget config ────────────────────────────────────────────
if [ ! -f "$PILOT_DIR/config/budget.conf" ]; then
  mkdir -p "$PILOT_DIR/config"
  cat > "$PILOT_DIR/config/budget.conf" << BUDGET_EOF
# Pilot — Budget Configuration
# Controls nightly iteration limits and alerts.

MAX_ITERATIONS_PER_NIGHT=8
MAX_OUTPUT_TOKENS_PER_NIGHT=500000
ITERATION_COOLDOWN=30
ALERT_THRESHOLD_PCT=80
DEFAULT_STOP_TIME=07:00
BUDGET_EOF
  ok "config/budget.conf created with defaults"
else
  ok "config/budget.conf already exists"
fi

# ── Discovery queue ──────────────────────────────────────────
DISCOVERY_QUEUE="$HOME/Documents/Claude/outputs/${PROJECT_NAME,,}-discovery-queue.txt"
mkdir -p "$(dirname "$DISCOVERY_QUEUE")"
echo -e "$FOCUS_AREAS" | sed '/^$/d' > "$DISCOVERY_QUEUE"
ok "Discovery queue written to $DISCOVERY_QUEUE"

# ── Generate launchd plists ───────────────────────────────────
say "Generating launchd plists..."

generate_plist() {
  local name="$1" script="$2" days_str="$3" hour="$4" minute="$5"
  local plist_path="$HOME/Library/LaunchAgents/com.pilot.${name}.plist"
  local script_path="$PILOT_DIR/scripts/${script}"

  cat > "$plist_path" << PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pilot.${name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_path}</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
PLIST_HEAD

  IFS=',' read -ra DAYS <<< "$days_str"
  for day in "${DAYS[@]}"; do
    day=$(echo "$day" | tr -d ' ')
    cat >> "$plist_path" << PLIST_DAY
        <dict>
            <key>Weekday</key>
            <integer>${day}</integer>
            <key>Hour</key>
            <integer>${hour}</integer>
            <key>Minute</key>
            <integer>${minute}</integer>
        </dict>
PLIST_DAY
  done

  cat >> "$plist_path" << PLIST_TAIL
    </array>
    <key>StandardOutPath</key>
    <string>$HOME/Documents/Claude/outputs/pilot-${name}-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Documents/Claude/outputs/pilot-${name}-launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.npm-global/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
</dict>
</plist>
PLIST_TAIL

  echo "$plist_path"
}

# Generate plists
PLIST_DISCOVER=$(generate_plist "discover" "discover.sh" "$DISCOVER_DAYS" 22 0)
ok "Created: $PLIST_DISCOVER"

PLIST_TRIAGE=$(generate_plist "triage" "triage.sh" "$DISCOVER_DAYS" 22 30)
ok "Created: $PLIST_TRIAGE"

PLIST_BUILDER=$(generate_plist "builder" "builder.sh" "$BUILDER_DAYS" 23 0)
ok "Created: $PLIST_BUILDER"

PLIST_TUNER=$(generate_plist "tune-budget" "tune-budget.sh" "0" 21 0)
ok "Created: $PLIST_TUNER"

PLIST_REVIEWS=$(generate_plist "tune-reviews" "tune-reviews.sh" "0" 21 15)
ok "Created: $PLIST_REVIEWS"

PLIST_HEALTH=$(generate_plist "health" "health-report.sh" "0" 8 0)
ok "Created: $PLIST_HEALTH"

PLIST_DIGEST=$(generate_plist "digest" "digest.sh" "$BUILDER_DAYS" 6 15)
ok "Created: $PLIST_DIGEST"

echo ""

# ── Load plists ───────────────────────────────────────────────
ask "Load launchd services now? (y/n) [y]: "
read -r LOAD_PLISTS
LOAD_PLISTS="${LOAD_PLISTS:-y}"

if [ "$LOAD_PLISTS" = "y" ]; then
  for plist in "$PLIST_DISCOVER" "$PLIST_TRIAGE" "$PLIST_BUILDER" "$PLIST_TUNER" "$PLIST_REVIEWS" "$PLIST_HEALTH" "$PLIST_DIGEST"; do
    launchctl load "$plist" 2>/dev/null && ok "Loaded: $(basename "$plist")" || warn "Failed to load: $(basename "$plist")"
  done
fi

echo ""

# ── Create output directory ───────────────────────────────────
mkdir -p "$HOME/Documents/Claude/outputs"
ok "Output directory ready"

# ── Summary ───────────────────────────────────────────────────
echo ""
say "════════════════════════════════════════"
say "  Setup Complete!"
say "════════════════════════════════════════"
echo ""
echo "  Project:    $PROJECT_NAME"
echo "  Repo:       $REPO_PATH"
echo "  Tracker:    $TRACKER_ADAPTER"
echo "  Builder:    ${AI_CODE_MODEL} ($(echo "$BUILDER_DAYS" | tr ',' '/' | sed 's/1/Mon/;s/2/Tue/;s/3/Wed/;s/4/Thu/;s/5/Fri/'))"
echo "  Discovery:  ${AI_RESEARCH_MODEL:-disabled} ($(echo "$DISCOVER_DAYS" | tr ',' '/' | sed 's/0/Sun/;s/2/Tue/;s/4/Thu/'))"
echo ""
echo "  Next steps:"
echo "  1. Add SLACK_BOT_TOKEN and SLACK_WEBHOOK_URL to ~/.zshenv"
echo "  2. Run: ./init.sh --check  to verify everything"
echo "  3. The pipeline will start on the next scheduled night"
echo ""
echo "  To run manually:  bash scripts/discover.sh"
echo "  To check health:  bash scripts/health-report.sh --dry-run"
echo ""
