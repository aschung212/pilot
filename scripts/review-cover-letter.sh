#!/bin/bash
# Cover Letter Reviewer — gets a Gemini second opinion before sending applications.
# Uses Google AI Plus subscription (zero extra cost).
#
# Usage:
#   ./review-cover-letter.sh "path/to/cover-letter.md"
#   ./review-cover-letter.sh "path/to/cover-letter.md" "path/to/job-description.md"

set -euo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

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

echo "🔍 Reviewing cover letter with Gemini 2.5 Pro..."

REVIEW=$(cat <<PROMPT | gemini -p "" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached\|^Attempt"
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

# Fall back to Flash if Pro fails
if [ -z "$REVIEW" ]; then
  echo "  ⚠️ Pro unavailable, using Flash..."
  REVIEW=$(cat <<PROMPT | gemini -p "" -m gemini-2.5-flash --sandbox 2>&1 | grep -v "^Registering\|^Server\|^Scheduling\|^Executing\|^MCP\|^Loaded cached"
Review this cover letter for a senior SWE role. Score 1-10, give 3 specific improvements.

$LETTER_CONTENT

$JD_SECTION
PROMPT
)
fi

echo ""
echo "━━━ Gemini Review ━━━"
echo "$REVIEW"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━"
