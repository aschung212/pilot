#!/bin/bash
# Lift Discovery Agent — finds improvement opportunities without touching code
# Creates Linear issues for anything it finds. Safe to run anytime.
#
# Usage:
#   ./lift-discover.sh              # auto-picks today's focus area
#   ./lift-discover.sh competitors  # force a specific focus

set -euo pipefail

# Source env vars when run by launchd (no login shell)
[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

TRACKER="$SCRIPT_DIR/../adapters/tracker.sh"
NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"

slack_send() {
  bash "$NOTIFY" send-async automation "$1"
}

REPO="${REPO_PATH:-/Users/aaron/development/lift}"
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Documents/Claude/outputs}"
SEARCH_LOG="$OUTPUT_DIR/lift-discovery-log.md"
RUN_LOG="$OUTPUT_DIR/lift-discover-$DATE.md"

mkdir -p "$OUTPUT_DIR"
touch "$SEARCH_LOG"

# Weighted round robin — 30-slot cycle (~1 month at daily runs)
# Higher weight = more frequent. Each focus area gets enough time between
# runs for the landscape to actually change — avoids redundant findings.
#
# Frequency guide:
#   3x/cycle (~10 days apart): competitors, ui-trends — fast-moving, high value
#   2x/cycle (~15 days apart): performance, accessibility, testing — codebase evolves
#   1x/cycle (~30 days apart): pwa-patterns, security-deps, monetization,
#                               seo-aso, data-viz, onboarding, dx-cicd — slow-moving
QUEUE_FILE="$OUTPUT_DIR/lift-discovery-queue.txt"

refill_queue() {
  cat >> "$QUEUE_FILE" <<'QUEUE'
competitors
performance
ui-trends
testing
accessibility
seo-aso
competitors
data-viz
pwa-patterns
ui-trends
onboarding
performance
security-deps
competitors
accessibility
dx-cicd
ui-trends
testing
monetization
QUEUE
}

# Refill if queue is empty or missing
if [ ! -s "$QUEUE_FILE" ]; then
  refill_queue
fi

# Allow override via argument, otherwise pop from queue
if [ -n "${1:-}" ]; then
  FOCUS="${1}"
else
  FOCUS=$(head -1 "$QUEUE_FILE")
  sed -i '' '1d' "$QUEUE_FILE"
  # Refill if we just emptied it
  if [ ! -s "$QUEUE_FILE" ]; then
    refill_queue
  fi
fi

DISCOVER_START=$(date +%s)
echo "🔍 Lift Discovery Agent — $DATE — Focus: $FOCUS" | tee "$RUN_LOG"

# Get current feature list and backlog for context
cd "$REPO"
FEATURES_FILE="${PRODUCT_FEATURES_FILE:-$HOME/Documents/Obsidian Vault/20_Learning/Vibe Coding Projects/Lift - Workout Tracker PWA.md}"
CURRENT_FEATURES=$(grep -A50 '## Feature Summary' "$FEATURES_FILE" 2>/dev/null | head -40 || echo "Could not read feature list")
EXISTING_BACKLOG=$(bash "$TRACKER" list backlog unstarted started || echo "Could not fetch backlog")
COMPLETED_ISSUES=$(bash "$TRACKER" list completed || echo "None")
PREVIOUS_SEARCHES=$(tail -100 "$SEARCH_LOG" 2>/dev/null || echo "No previous searches")
LAST_RUN_DATE=$(grep "\[$FOCUS\]" "$SEARCH_LOG" 2>/dev/null | tail -1 | cut -d' ' -f1 || echo "never")

# Fetch canceled issues with full details — these represent rejected product directions
CANCELED_IDS=$({ bash "$TRACKER" list canceled | grep -oE "${LINEAR_TEAM}-[0-9]+"; } || true)
CANCELED_DETAILS=""
for cid in $CANCELED_IDS; do
  detail=$(bash "$TRACKER" view "$cid" || true)
  CANCELED_DETAILS+="
--- $cid (CANCELED) ---
$detail
"
done

# Product decisions file — Aaron maintains this in Obsidian
DECISIONS_FILE="${PRODUCT_DECISIONS_FILE:-$HOME/Documents/Obsidian Vault/20_Learning/Vibe Coding Projects/Lift - Product Decisions.md}"
PRODUCT_DECISIONS=$(cat "$DECISIONS_FILE" 2>/dev/null || echo "No product decisions file found")

# Focus-specific search instructions
case "$FOCUS" in
  competitors)
    SEARCH_PROMPT="Search the web for the top workout tracker apps in 2026 (Strong, Hevy, JEFIT, FitNotes, StrongLifts, any new ones). Look at recent app store reviews, Reddit discussions (r/fitness, r/weightroom, r/bodybuilding), and Product Hunt launches. Find features users love that Lift is missing, and common complaints about competitors that Lift could capitalize on."
    ;;
  performance)
    SEARCH_PROMPT="Search for Vue 3 + Vite performance best practices in 2026. Look for bundle optimization techniques, lazy loading patterns, service worker caching strategies, and PWA performance benchmarks. Also search for Lighthouse scoring tips for PWAs. Read the current codebase and identify specific performance opportunities."
    ;;
  ui-trends)
    SEARCH_PROMPT="Search for mobile app UI/UX trends in 2026, particularly for fitness and health apps. Look at Apple HIG updates, Material Design 3 patterns, and trending design systems. Search Dribbble, Mobbin, and UI galleries for workout tracker designs. Find specific UI improvements that would make Lift feel more modern and polished."
    ;;
  accessibility)
    SEARCH_PROMPT="Search for WCAG 2.2 requirements and mobile accessibility best practices in 2026. Look for common accessibility failures in PWAs and Vue apps. Read the current codebase and audit against WCAG AA standards. Focus on screen reader compatibility, keyboard navigation, color contrast, and motion sensitivity."
    ;;
  pwa-patterns)
    SEARCH_PROMPT="Search for progressive web app best practices in 2026. Look for install prompt patterns, offline-first UX, background sync, push notifications for PWAs, and Capacitor integration patterns. Find what the best PWAs (Starbucks, Twitter Lite, Pinterest) do that Lift could adopt."
    ;;
  security-deps)
    SEARCH_PROMPT="Run npm audit in the repo and search for known vulnerabilities in the current dependencies. Search for Supabase security best practices, CSP header configuration for PWAs, and common Vue.js security pitfalls. Check if any dependencies are deprecated or have better alternatives."
    ;;
  monetization)
    SEARCH_PROMPT="Search for how free fitness apps monetize without paywalling core features. Look at freemium models, affiliate partnerships, premium themes, data insights subscriptions, and coaching integrations. Find monetization strategies that align with Lift's anti-bloat philosophy — revenue without compromising the user experience."
    ;;
  testing)
    SEARCH_PROMPT="Search for Vue 3 testing best practices in 2026 — Vitest, Vue Test Utils, Playwright, component testing. Look for testing patterns for composables, Pinia stores, and PWA service workers. Read the current test suite and identify gaps in coverage for critical user flows (logging sets, viewing history, syncing data). Check for flaky test patterns and testing anti-patterns."
    ;;
  seo-aso)
    SEARCH_PROMPT="Search for PWA SEO best practices in 2026 — meta tags, structured data, Open Graph optimization, app store optimization for PWAs. Look at how top fitness PWAs rank in Google and what meta/schema markup they use. Search for web.dev articles on PWA discoverability. Check how Lift appears in Google search results and identify improvements to meta descriptions, canonical URLs, and social previews."
    ;;
  data-viz)
    SEARCH_PROMPT="Search for fitness data visualization trends in 2026 — chart types, progress tracking UX, personal records displays, training volume visualization. Look at how apps like Strong, Hevy, and Strava present workout data. Search for D3.js and lightweight SVG charting patterns for mobile. Read the current codebase charts and identify improvements to make data more insightful and visually compelling."
    ;;
  onboarding)
    SEARCH_PROMPT="Search for mobile app onboarding best practices in 2026 — first-run experience, progressive disclosure, sample data strategies, empty state design, feature discovery. Look at how top fitness apps handle new users who have no data yet. Search for retention research on onboarding flows. Read the current onboarding implementation and identify friction points or missed opportunities."
    ;;
  dx-cicd)
    SEARCH_PROMPT="Search for Vue 3 + Vite CI/CD best practices in 2026 — GitHub Actions optimization, build caching, preview deployments, automated dependency updates (Renovate/Dependabot), release automation. Look at how open-source Vue projects structure their CI pipelines. Read the current GitHub Actions config and identify improvements to build speed, reliability, and developer experience."
    ;;
esac

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT
You are the Lift Discovery Agent. Your job is to find improvement opportunities for the Lift workout tracker app. You do NOT write code or make changes — you only research and create Linear issues.

## Today's focus: $FOCUS (last searched: $LAST_RUN_DATE)

$SEARCH_PROMPT

## Product decisions and direction (READ THIS FIRST)

$PRODUCT_DECISIONS

## Canceled issues (Aaron explicitly rejected these — do NOT recreate or suggest variations)

$CANCELED_DETAILS

## Completed issues (already shipped — do NOT duplicate)

$COMPLETED_ISSUES

## Current Lift features

$CURRENT_FEATURES

## Open backlog (do NOT duplicate these)

$EXISTING_BACKLOG

## Previous searches (do NOT repeat these — find NEW angles)

$PREVIOUS_SEARCHES

## Your job

1. **Read the product decisions above first** — understand what Aaron wants and does NOT want
2. Search the web for relevant information based on today's focus
3. Read relevant parts of the codebase at $REPO if needed
4. Cross-reference findings against canceled issues, completed issues, open backlog, and existing features
5. Output discoveries as LINEAR_DISCOVER lines that ALIGN with the approved product direction

## Rules

- **NEVER** recommend features that match canceled issues or their variations — these were explicitly rejected
- Do NOT duplicate open backlog items or completed issues
- Do NOT repeat searches from the previous log — find new angles, new sources, new insights
- Each discovery must be specific and actionable — not vague ("improve performance" is bad, "lazy-load the CalendarView component which loads 3 heavy date libraries on mount" is good)
- Include the source URL or reasoning for each discovery
- Aim for 3-8 high-quality discoveries per run
- Priority guide: 1=urgent bug/security, 2=high-impact feature gap, 3=nice improvement, 4=low-priority polish
- When a competitor feature seems useful, check if an existing Lift feature already solves the same problem differently before recommending it

## Output format

## Search Summary
What you searched for and key findings (3-5 sentences)

## Discoveries
For each finding, output:
LINEAR_DISCOVER:priority:title|description with source URL or reasoning

Example:
LINEAR_DISCOVER:2:Add haptic feedback on set logging|Competitors Strong and Hevy both use haptic feedback when a set is logged. iOS supports this via navigator.vibrate() or Capacitor Haptics plugin. Source: https://reddit.com/r/fitness/...
LINEAR_DISCOVER:3:Add workout streak counter to home screen|Duolingo-style streak tracking increases retention 23% per Nir Eyal research. Show current streak on the main workout tab.

## Search Log
List the specific queries and URLs you searched (for the search log):
SEARCH:query or URL searched
PROMPT

# Phase 1: Gemini does web research (native Google Search — better results, saves Claude tokens)
GEMINI_RESEARCH="$OUTPUT_DIR/lift-discover-$DATE-gemini-research.md"
echo "  🔍 Phase 1: Gemini web research ($FOCUS)..." | tee -a "$RUN_LOG"
RESEARCH_PROMPT="You are a product research assistant. $SEARCH_PROMPT Be specific — include URLs, app names, version numbers, Reddit post links, dates. Structure your findings as a numbered list. Do NOT make recommendations — just report what you find."
GEMINI_RESEARCH_PROMPT_FILE=$(mktemp)
echo "$RESEARCH_PROMPT" > "$GEMINI_RESEARCH_PROMPT_FILE"
gemini -p "$(cat "$GEMINI_RESEARCH_PROMPT_FILE")" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt" > "$GEMINI_RESEARCH" 2>/dev/null || true
# Fall back to Flash if Pro fails or empty
if [ ! -s "$GEMINI_RESEARCH" ]; then
  echo "  ⚠️ Pro unavailable, falling back to Flash..." | tee -a "$RUN_LOG"
  gemini -p "$(cat "$GEMINI_RESEARCH_PROMPT_FILE")" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached" > "$GEMINI_RESEARCH" 2>/dev/null || true
fi
rm -f "$GEMINI_RESEARCH_PROMPT_FILE"
# If Gemini failed entirely, skip Phase 1 gracefully
if [ ! -s "$GEMINI_RESEARCH" ]; then
  echo "  ⚠️ Gemini research unavailable, Claude will do its own research." | tee -a "$RUN_LOG"
  echo "Gemini research was unavailable for this run." > "$GEMINI_RESEARCH"
fi
GEMINI_FINDINGS=$(cat "$GEMINI_RESEARCH" 2>/dev/null || echo "Gemini research unavailable.")
echo "  ✅ Gemini research complete ($(wc -l < "$GEMINI_RESEARCH" | tr -d ' ') lines)" | tee -a "$RUN_LOG"

# Append Gemini research to the Claude prompt file
cat >> "$PROMPT_FILE" <<GEMINI_APPEND

## Gemini Research Findings (use these as your primary source — verify and cross-reference)

$GEMINI_FINDINGS
GEMINI_APPEND

# Phase 2: Claude analyzes findings + reads codebase + creates issues
echo "  🧠 Phase 2: Claude analysis and issue creation..." | tee -a "$RUN_LOG"
DISCOVER_JSON="$OUTPUT_DIR/lift-discover-$DATE-output.json"
if ! claude --dangerously-skip-permissions --output-format json -p "$(cat "$PROMPT_FILE")" --max-turns 30 2>&1 > "$DISCOVER_JSON"; then
  echo "  ❌ Claude analysis failed (exit code $?)" | tee -a "$RUN_LOG"
  slack_send "🚨 *Discovery Agent — Claude analysis failed*
Focus: $FOCUS | Date: $DATE
Gemini research completed but Claude could not analyze. Check logs: lift-discover-$DATE.md"
fi
# Check for empty/invalid output
if [ ! -s "$DISCOVER_JSON" ]; then
  echo "  ❌ Claude produced no output (empty JSON)" | tee -a "$RUN_LOG"
  slack_send "🚨 *Discovery Agent — Claude produced no output*
Focus: $FOCUS | Date: $DATE
Possible rate limit or timeout. Gemini research saved at lift-discover-$DATE-gemini-research.md"
else
  # Extract text result to run log
  python3 -c "
import json
try:
    with open('$DISCOVER_JSON') as f:
        data = json.load(f)
    result = data.get('result', '')
    if not result:
        print('  ⚠️ Claude returned empty result')
    else:
        print(result)
except Exception as e:
    print(f'  ❌ Failed to parse Claude output: {e}')
" >> "$RUN_LOG" 2>/dev/null
fi

# Track token usage
USAGE_CSV="$OUTPUT_DIR/lift-usage-tracking.csv"
if [ ! -f "$USAGE_CSV" ]; then
  echo "date,run,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens,nightly_output_total,duration_sec" > "$USAGE_CSV"
fi
if [ -f "$DISCOVER_JSON" ]; then
  DISCOVER_USAGE=$(python3 -c "
import json
try:
    with open('$DISCOVER_JSON') as f:
        data = json.load(f)
    usage = data.get('usage', {})
    inp = usage.get('input_tokens', 0)
    out = usage.get('output_tokens', 0)
    cr = usage.get('cache_read_input_tokens', 0)
    cc = usage.get('cache_creation_input_tokens', 0)
    print(f'{inp},{out},{cr},{cc}')
except: print('0,0,0,0')
" 2>/dev/null)
  DISC_OUTPUT=$(echo "$DISCOVER_USAGE" | cut -d',' -f2)
  DISC_END=$(date +%s)
  DISC_DUR=$((DISC_END - DISCOVER_START))
  echo "$DATE,discover,$DISCOVER_USAGE,$DISC_OUTPUT,$DISC_DUR" >> "$USAGE_CSV"
  echo "  📊 Discovery output tokens: ${DISC_OUTPUT}" | tee -a "$RUN_LOG"
fi

rm -f "$PROMPT_FILE"

echo "" | tee -a "$RUN_LOG"
echo "✅ Discovery complete at $(date)" | tee -a "$RUN_LOG"

# Discovery metrics tracking
DISCOVERY_METRICS="$OUTPUT_DIR/lift-discovery-metrics.csv"
if [ ! -f "$DISCOVERY_METRICS" ]; then
  echo "date,focus,discoveries_count,priorities,duration_sec" > "$DISCOVERY_METRICS"
fi
DISCOVER_END=$(date +%s)
DISCOVER_DURATION=$((DISCOVER_END - DISCOVER_START))

# Create Linear issues for discoveries — skip if Claude already created them inline
DISCOVER_COUNT=0
DISCOVER_PRIORITIES=""
CLAUDE_CREATED=$(grep -c "linear.app/$LINEAR_ORG/issue/${LINEAR_TEAM}-" "$RUN_LOG" 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
if [ "$CLAUDE_CREATED" -gt 0 ]; then
  echo "  ℹ️  Claude already created $CLAUDE_CREATED issues inline — skipping duplicate creation." | tee -a "$RUN_LOG"
else
  { grep -oE 'LINEAR_DISCOVER:[1-4]:.*' "$RUN_LOG" 2>/dev/null || true; } | sort -u | while IFS='|' read -r marker desc; do
    priority=$(echo "$marker" | sed 's/LINEAR_DISCOVER:\([1-4]\):.*/\1/')
    title=$(echo "$marker" | sed 's/LINEAR_DISCOVER:[1-4]://')
    desc=${desc:-No description}
    echo "  📋 Creating: $title (P$priority)" | tee -a "$RUN_LOG"
    bash "$TRACKER" create "$title" "$priority" --description "Source: Discovery agent ($FOCUS focus, $DATE). $desc" 2>&1 | tee -a "$RUN_LOG"
  done
fi
DISCOVER_COUNT=$({ grep -oE 'LINEAR_DISCOVER:[1-4]:' "$RUN_LOG" 2>/dev/null || true; } | wc -l | tr -d ' ')
DISCOVER_PRIORITIES=$({ grep -oE 'LINEAR_DISCOVER:[1-4]:' "$RUN_LOG" 2>/dev/null || true; } | grep -oE '[1-4]' | sort | tr '\n' '/' | sed 's/$//')
echo "$DATE,$FOCUS,$DISCOVER_COUNT,$DISCOVER_PRIORITIES,$DISCOVER_DURATION" >> "$DISCOVERY_METRICS"

# Append searches to the search log for deduplication
{ grep -oE 'SEARCH:.*' "$RUN_LOG" 2>/dev/null || true; } | while read -r line; do
  echo "$DATE [$FOCUS] $line" >> "$SEARCH_LOG"
done

# Post discovery digest to Slack — include Linear links
DISCOVERY_LIST=$(python3 -c "
import re
with open('$RUN_LOG') as f:
    log = f.read()

# Extract titles from LINEAR_DISCOVER lines
titles = re.findall(r'LINEAR_DISCOVER:[1-4]:([^|]+)', log)
# Extract Linear URLs with issue IDs
urls = re.findall(r'(https://linear\.app/[^/]+/issue/([A-Z]+-\d+)[^\s)\"]*)', log)

# Pair them up (best effort — same order)
lines = []
for i, title in enumerate(titles):
    title = title.strip()
    if i < len(urls):
        url, issue_id = urls[i]
        lines.append(f'  • <{url}|{issue_id}: {title}>')
    else:
        lines.append(f'  • {title}')
print('\n'.join(lines) if lines else '  (none)')
" 2>/dev/null)
SEARCH_SUMMARY=$({ sed -n '/^## Search Summary/,/^## /p' "$RUN_LOG" 2>/dev/null || true; } | grep -v '^## ' | head -3 | tr '\n' ' ')
slack_send "*Discovery Agent — ${FOCUS}* (${DISCOVER_DURATION}s)
${SEARCH_SUMMARY}
*${DISCOVER_COUNT} discoveries:*
${DISCOVERY_LIST}"

echo ""
echo "📊 Results saved to: $RUN_LOG"
echo "📋 Search log updated: $SEARCH_LOG"
echo "📈 Metrics: $DISCOVER_COUNT discoveries ($DISCOVER_DURATION sec)"
