#!/bin/bash
# Cover Letter Reviewer — a Gemini second opinion before you send an application.
#
# Routes through adapters/ai-research.sh, which calls the Gemini REST API with
# GEMINI_API_KEY (free-tier Flash). The retired `gemini` CLI OAuth tier — killed
# by Google on 2026-06-18 (IneligibleTierError / UNSUPPORTED_CLIENT) — is no
# longer used here. Two passes: a full hiring-manager rubric, then a shorter
# prompt if the first comes back empty. Both use --no-grounding, since this
# reviews supplied cover-letter text rather than researching the web.
#
# Usage:
#   ./review-cover-letter.sh "path/to/cover-letter.md"
#   ./review-cover-letter.sh "path/to/cover-letter.md" "path/to/job-description.md"

set -uo pipefail

REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
AI_RESEARCH="$SCRIPT_DIR/../adapters/ai-research.sh"

# GEMINI_API_KEY (and other secrets) live in ~/.zshenv. The adapter self-sources
# it too, but export it here so the child adapter process inherits it directly.
# Skipped under tests (_PILOT_TEST_MODE) so the harness stays hermetic.
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

LETTER="${1:?Usage: review-cover-letter.sh <cover-letter-path> [job-description-path]}"
JOB_DESC="${2:-}"

if [ ! -f "$LETTER" ]; then
  echo "❌ File not found: $LETTER"
  exit 1
fi

LETTER_CONTENT=$(cat "$LETTER")
JD_SECTION=""
if [ -n "$JOB_DESC" ] && [ -f "$JOB_DESC" ]; then
  JD_SECTION="## Job Description
$(cat "$JOB_DESC")"
fi

echo "🔍 Reviewing cover letter with Gemini Flash..."

# Pass 1 — full hiring-manager rubric. Capture the prompt into a variable and
# hand it to the adapter (clean text on stdout, fails loud on stderr). An empty
# result means the call failed, so we fall through to the shorter second pass.
PRIMARY_PROMPT=$(cat <<PROMPT
You are a hiring manager at a top-tier tech company (Notion, Linear, Airtable tier). Review this cover letter critically.

## Cover Letter
$LETTER_CONTENT

$JD_SECTION

## Review Criteria
1. **First impression** — would you keep reading after the first paragraph?
2. **Specificity** — does it show genuine knowledge of the company, or could it be sent anywhere?
3. **Signal vs noise** — does every sentence earn its place?
4. **Technical credibility** — does the candidate sound like a real engineer?
5. **Red flags** — anything that would make you hesitate?
6. **Missing** — what should be added?

## Output
- Score: X/10
- Verdict: SEND / REVISE / REWRITE
- Top 3 specific improvements (with suggested rewrites)
- One thing that works well (keep this)
PROMPT
)

REVIEW=$(bash "$AI_RESEARCH" prompt "$PRIMARY_PROMPT" --no-grounding) || REVIEW=""

# Pass 2 — shorter fallback prompt if the detailed pass returned nothing.
if [ -z "$REVIEW" ]; then
  echo "  ⚠️ Detailed review came back empty — retrying with a shorter prompt..." >&2
  FALLBACK_PROMPT=$(cat <<PROMPT
Review this cover letter for a senior SWE role. Score 1-10, give 3 specific improvements.

$LETTER_CONTENT

$JD_SECTION
PROMPT
)
  REVIEW=$(bash "$AI_RESEARCH" prompt "$FALLBACK_PROMPT" --no-grounding) || REVIEW=""
fi

# Both passes failed — fail loud instead of printing an empty review. The
# adapter already explained why on stderr (missing/invalid GEMINI_API_KEY,
# exhausted quota, network error, …).
if [ -z "$REVIEW" ]; then
  echo "❌ Cover-letter review failed — Gemini returned nothing (see the reason above)." >&2
  echo "   Check GEMINI_API_KEY and adapters/ai-research.sh." >&2
  exit 1
fi

echo ""
echo "━━━ Gemini Review ━━━"
echo "$REVIEW"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━"
