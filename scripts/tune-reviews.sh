#!/bin/bash
# Lift Review Auto-Tuner — learns from PR outcomes to improve reviewer prompts.
# Runs after each overnight session. Analyzes:
#   1. What each reviewer flagged
#   2. What Aaron commented/requested on the PR
#   3. What was merged without changes (reviewers were right)
#   4. What Aaron caught that reviewers missed
#
# Updates lift-review-learnings.md which is injected into reviewer prompts.

set -euo pipefail

[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true

OUTPUT_DIR="$HOME/Documents/Claude/outputs"
LEARNINGS="$OUTPUT_DIR/lift-review-learnings.md"
REVIEW_HISTORY="$OUTPUT_DIR/lift-review-history.json"
REPO="/Users/aaron/development/lift"

# Initialize history if needed
if [ ! -f "$REVIEW_HISTORY" ]; then
  echo '[]' > "$REVIEW_HISTORY"
fi

# Find recently merged PRs that had automated reviews
cd "$REPO"
MERGED_PRS=$(gh pr list --state merged --limit 10 --json number,mergedAt,headRefName,title 2>/dev/null || echo "[]")

# Process each merged PR that we haven't analyzed yet
echo "$MERGED_PRS" | python3 -c "
import json, sys, subprocess, os, re
from datetime import datetime

output_dir = '$OUTPUT_DIR'
learnings_path = '$LEARNINGS'
history_path = '$REVIEW_HISTORY'
repo = '$REPO'

merged = json.load(sys.stdin)
history = json.load(open(history_path))
analyzed_prs = {h['pr'] for h in history}

new_entries = []

for pr in merged:
    pr_num = pr['number']
    if pr_num in analyzed_prs:
        continue

    # Get PR comments
    try:
        comments_raw = subprocess.check_output(
            ['gh', 'api', f'repos/aschung212/Lift/issues/{pr_num}/comments'],
            cwd=repo, stderr=subprocess.DEVNULL
        ).decode()
        comments = json.loads(comments_raw)
    except:
        continue

    # Separate automated reviews from human comments
    claude_findings = []
    gemini_findings = []
    aaron_comments = []

    for c in comments:
        body = c.get('body', '')
        author = c.get('user', {}).get('login', '')

        if 'Layer 1: Claude' in body:
            claude_findings.append(body)
        elif 'Layer 2: Gemini' in body:
            gemini_findings.append(body)
        elif author == 'aschung212':
            aaron_comments.append(body)

    # Skip PRs without automated reviews
    if not claude_findings and not gemini_findings:
        continue

    # Determine outcome
    had_aaron_feedback = len(aaron_comments) > 0
    # If Aaron commented, he found something the reviewers may have missed
    # If he merged without comment, reviewers caught everything (or nothing mattered)

    entry = {
        'pr': pr_num,
        'date': pr.get('mergedAt', '')[:10],
        'title': pr.get('title', ''),
        'claude_finding_count': len(claude_findings),
        'gemini_finding_count': len(gemini_findings),
        'aaron_comment_count': len(aaron_comments),
        'aaron_comments': aaron_comments[:5],  # cap at 5
        'merged_clean': not had_aaron_feedback
    }
    new_entries.append(entry)
    print(f'  Analyzed PR #{pr_num}: {\"clean merge\" if not had_aaron_feedback else f\"{len(aaron_comments)} Aaron comments\"}')

if not new_entries:
    print('  No new PRs to analyze.')
    sys.exit(0)

# Append to history
history.extend(new_entries)
with open(history_path, 'w') as f:
    json.dump(history, f, indent=2)

# Analyze patterns across all history
total = len(history)
clean_merges = sum(1 for h in history if h.get('merged_clean', False))
aaron_caught = [h for h in history if not h.get('merged_clean', False)]

# Extract themes from Aaron's comments
aaron_themes = []
for h in aaron_caught:
    for comment in h.get('aaron_comments', []):
        aaron_themes.append(comment[:200])  # truncate

# Update learnings file
track_record = '| Date | PR | Claude Findings | Gemini Findings | Aaron Findings | Missed By |\n|---|---|---|---|---|---|\n'
for h in history[-20:]:  # last 20
    missed = 'Both' if not h.get('merged_clean') else '-'
    track_record += f\"| {h.get('date','')} | #{h['pr']} | {h.get('claude_finding_count',0)} | {h.get('gemini_finding_count',0)} | {h.get('aaron_comment_count',0)} | {missed} |\n\"

# Build custom rules from Aaron's patterns
custom_rules = ''
if aaron_themes:
    custom_rules = 'The following are real issues Aaron caught that automated reviewers missed. Pay special attention to these patterns:\n\n'
    for i, theme in enumerate(aaron_themes[-10:], 1):  # last 10
        custom_rules += f'{i}. {theme}\n\n'

# Calculate stats
stats = f'Clean merge rate: {clean_merges}/{total} ({clean_merges/total*100:.0f}%)' if total > 0 else 'No data yet'

learnings = f'''# Lift PR Review Learnings

> Auto-updated by lift-tune-reviews.sh after each PR merge.
> Injected into reviewer prompts so they improve over time.
> {stats}

## Reviewer Track Record
{track_record}

## Patterns: What Reviewers Consistently Miss

{custom_rules if custom_rules else '(No missed patterns detected yet — reviewers are catching everything Aaron checks for.)'}

## Patterns: What Reviewers Over-Flag (False Positives)

(Tracked when Aaron merges despite reviewer warnings — not yet implemented.)

## Custom Rules (Learned)

{custom_rules if custom_rules else '(No custom rules yet — will be derived from patterns above after more data.)'}
'''

with open(learnings_path, 'w') as f:
    f.write(learnings)

print(f'  Updated learnings: {len(new_entries)} new PRs analyzed, {total} total in history')
print(f'  {stats}')
" 2>&1
