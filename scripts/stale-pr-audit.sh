#!/bin/bash
# Stale-PR Audit — flags open PRs whose work has already shipped.
#
# Every dedupe guard in the pipeline is keyed on issue IDENTITY: "does this
# issue already have an open PR?" That question cannot catch work that was
# rebuilt under a DIFFERENT issue number, which is what produced PR #1041
# (LIFT-1039, split from LIFT-783) — a duplicate of PR #1032 that sat open
# for a month and merged with zero schema delta.
#
# This audit asks the other question, against the codebase rather than the
# tracker: does merging this PR still change anything?
#
#   1. No-op check — merge the PR into master in memory (git merge-tree, no
#      worktree touched). If the resulting tree equals master's tree, the PR
#      contributes nothing and can be closed.
#   2. Schema-duplicate check — every `ADD COLUMN` a PR introduces that
#      master's migrations already add. Catches the #1041 shape directly:
#      a redundant migration inside an otherwise non-empty PR, which the
#      no-op check alone cannot see.
#   3. Schema-collision check — two open PRs adding the same column. This is
#      the pre-merge form of (2): it fires while both are still open, which
#      is when the duplicate is cheap to kill.
#
# Read-only against Lift: fetches refs, never checks anything out.
#
# Usage:
#   ./stale-pr-audit.sh              # report to stdout
#   ./stale-pr-audit.sh --dry-run    # same (no mutations exist); for symmetry
#   ./stale-pr-audit.sh --notify     # also post findings to Slack

set -uo pipefail

[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv" 2>/dev/null || true
REAL_SCRIPT="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
[ -z "${_PILOT_TEST_MODE:-}" ] && [ -f "$SCRIPT_DIR/../project.env" ] && source "$SCRIPT_DIR/../project.env"

NOTIFY="$SCRIPT_DIR/../adapters/notify.sh"
source "$SCRIPT_DIR/../lib/log.sh"
LOG_COMPONENT="stale-pr-audit"

DATE=$(date +%Y-%m-%d)
OUTPUT_DIR="${OUTPUT_DIR:-$PILOT_DIR/data}"
REPORT="$OUTPUT_DIR/lift-stale-pr-audit-$DATE.md"
REPO="${REPO_PATH:?REPO_PATH not set — run init.sh}"
BASE="origin/${DEFAULT_BRANCH:-master}"

DO_NOTIFY=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) ;;                 # read-only already; accepted for symmetry
    --notify)  DO_NOTIFY="1" ;;
    *) echo "Unknown argument: $arg (valid: --dry-run, --notify)" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh CLI not found" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "REPO_PATH is not a git repo: $REPO" >&2; exit 1; }

# git merge-tree --write-tree needs git >= 2.38.
_git_ok=$(git -C "$REPO" version | awk '{print $3}')
case "$_git_ok" in
  2.[0-9].*|2.[12][0-9].*|2.3[0-7].*|1.*|0.*)
    echo "git $_git_ok is too old for 'merge-tree --write-tree' (need >= 2.38)" >&2; exit 1 ;;
esac

echo "🔎 Stale-PR Audit — $DATE" | tee "$REPORT"
git -C "$REPO" fetch origin --quiet 2>/dev/null || log_warn "fetch failed; using cached refs"

MASTER_TREE=$(git -C "$REPO" rev-parse "${BASE}^{tree}" 2>/dev/null)
[ -z "$MASTER_TREE" ] && { echo "cannot resolve $BASE" >&2; exit 1; }

PR_JSON=$(gh pr list --repo "$GITHUB_ISSUES_REPO" --state open --limit 200 \
  --json number,title,headRefName,createdAt 2>/dev/null)
[ -z "$PR_JSON" ] && { echo "  Could not list PRs." | tee -a "$REPORT"; exit 1; }

FINDINGS=$(REPO="$REPO" BASE="$BASE" MASTER_TREE="$MASTER_TREE" PR_JSON="$PR_JSON" python3 <<'PY'
import os, re, json, subprocess, collections
REPO, BASE, MT = os.environ["REPO"], os.environ["BASE"], os.environ["MASTER_TREE"]
def g(*a):
    return subprocess.run(["git","-C",REPO]+list(a), capture_output=True, text=True).stdout

COL = re.compile(r'alter\s+table\s+(?:if\s+exists\s+)?(?:public\.)?([a-z_0-9]+)\s+add\s+column\s+'
                 r'(?:if\s+not\s+exists\s+)?([a-z_0-9]+)', re.I)
MIGDIR = "supabase/migrations"

def cols(rev, files):
    s = set()
    for f in files:
        for t, c in COL.findall(g("show", f"{rev}:{f}")):
            s.add((t.lower(), c.lower()))
    return s

mfiles = [f for f in g("ls-tree","-r","--name-only",BASE,f"{MIGDIR}/").split("\n") if f.endswith(".sql")]
master_cols = cols(BASE, mfiles)

prs = json.loads(os.environ["PR_JSON"])
noop, dup, owner, unresolved = [], [], collections.defaultdict(list), []

for p in sorted(prs, key=lambda x: x["createdAt"]):
    num, head = p["number"], f"origin/{p['headRefName']}"
    if not g("rev-parse","--verify",head).strip():
        unresolved.append((num, p["title"], "branch ref not found"))
        continue
    merged = g("merge-tree","--write-tree",BASE,head).strip().split("\n")[0]
    if not merged:
        unresolved.append((num, p["title"], "merge conflict — cannot evaluate"))
    elif merged == MT:
        noop.append((num, p["title"]))
    mb = g("merge-base", BASE, head).strip()
    if mb:
        added = [f for f in g("diff","--name-only","--diff-filter=A",mb,head,"--",f"{MIGDIR}/*.sql").split("\n") if f.strip()]
        for t, c in sorted(cols(head, added)):
            if (t, c) in master_cols:
                dup.append((num, p["title"], f"{t}.{c}"))
            owner[(t, c)].append(num)

out = []
out.append(f"\n## Scanned {len(prs)} open PRs against {BASE}\n")
out.append("### 1. No-op PRs (merging changes nothing)")
out += [f"  ⚠️  PR #{n} — {t}" for n, t in noop] or ["  none"]
out.append("\n### 2. Migrations duplicating a column already in master")
out += [f"  ⚠️  PR #{n} adds {col} (already in master) — {t}" for n, t, col in dup] or ["  none"]
out.append("\n### 3. Two open PRs adding the same column")
coll = [(k, v) for k, v in sorted(owner.items()) if len(v) > 1]
out += [f"  ⚠️  {k[0]}.{k[1]} added by PRs {v}" for k, v in coll] or ["  none"]
if unresolved:
    out.append("\n### Not evaluated")
    out += [f"  •  PR #{n} — {why} — {t}" for n, t, why in unresolved]
out.append(f"\nTOTALCOUNT={len(noop)+len(dup)+len(coll)}")
print("\n".join(out))
PY
)

echo "$FINDINGS" | tee -a "$REPORT"
TOTAL=$(echo "$FINDINGS" | grep -oE 'TOTALCOUNT=[0-9]+' | cut -d= -f2 | tr -d ' \n')
TOTAL="${TOTAL:-0}"
sed -i '' '/^TOTALCOUNT=/d' "$REPORT" 2>/dev/null || true

echo "" | tee -a "$REPORT"
if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
  echo "🚨 $TOTAL finding(s) — see $REPORT" | tee -a "$REPORT"
else
  echo "✅ No already-shipped work found in the open-PR set." | tee -a "$REPORT"
fi

if [ -n "$DO_NOTIFY" ]; then
  if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
    bash "$NOTIFY" send automation "🔎 *Stale-PR audit — $DATE*: $TOTAL finding(s). Open PRs whose work already shipped:
\`\`\`
$(echo "$FINDINGS" | grep '⚠️' | head -20)
\`\`\`" >/dev/null 2>&1 || true
  else
    bash "$NOTIFY" send automation "🔎 *Stale-PR audit — $DATE*: clean — no already-shipped work in the open-PR set." >/dev/null 2>&1 || true
  fi
fi

exit 0
