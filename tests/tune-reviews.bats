#!/usr/bin/env bats
# Tests for scripts/tune-reviews.sh — review learning logic

load test_helper

@test "tune-reviews: history JSON initialized correctly" {
  HISTORY="$TEST_TMPDIR/history.json"
  echo '[]' > "$HISTORY"
  result=$(python3 -c "import json; print(len(json.load(open('$HISTORY'))))")
  [ "$result" = "0" ]
}

@test "tune-reviews: clean merge detection" {
  result=$(python3 -c "
had_aaron_feedback = False
merged_clean = not had_aaron_feedback
print('clean' if merged_clean else 'feedback')
")
  [ "$result" = "clean" ]

  result=$(python3 -c "
had_aaron_feedback = True
merged_clean = not had_aaron_feedback
print('clean' if merged_clean else 'feedback')
")
  [ "$result" = "feedback" ]
}

@test "tune-reviews: clean merge rate calculation" {
  result=$(python3 -c "
history = [
    {'merged_clean': True},
    {'merged_clean': True},
    {'merged_clean': False},
    {'merged_clean': True},
]
total = len(history)
clean = sum(1 for h in history if h.get('merged_clean', False))
rate = clean / total * 100
print(f'{rate:.0f}')
")
  [ "$result" = "75" ]
}

@test "tune-reviews: comment categorization" {
  result=$(python3 -c "
comments = [
    {'body': '## 🔍 Review — Layer 1: Claude', 'user': {'login': 'github-actions'}},
    {'body': '## 🔍 Review — Layer 2: Gemini', 'user': {'login': 'github-actions'}},
    {'body': 'The contrast ratio on the dark theme is wrong', 'user': {'login': 'aschung212'}},
]

claude_findings = [c for c in comments if 'Layer 1: Claude' in c['body']]
gemini_findings = [c for c in comments if 'Layer 2: Gemini' in c['body']]
aaron_comments = [c for c in comments if c['user']['login'] == 'aschung212']

print(f'{len(claude_findings)},{len(gemini_findings)},{len(aaron_comments)}')
")
  [ "$result" = "1,1,1" ]
}

@test "tune-reviews: learnings file format" {
  LEARNINGS="$TEST_TMPDIR/learnings.md"
  cat > "$LEARNINGS" << 'EOF'
# Lift PR Review Learnings

> Auto-updated by lift-tune-reviews.sh after each PR merge.
> Clean merge rate: 3/4 (75%)

## Reviewer Track Record
| Date | PR | Claude Findings | Gemini Findings | Aaron Findings | Missed By |
|---|---|---|---|---|---|
| 2026-04-01 | #42 | 1 | 2 | 0 | - |
EOF

  grep -q "Clean merge rate" "$LEARNINGS"
  grep -q "Track Record" "$LEARNINGS"
}
