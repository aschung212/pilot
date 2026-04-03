# Adapters

Adapters are thin wrapper scripts that provide a stable interface between the pipeline and external tools. To swap a tool (e.g., Linear → GitHub Issues), rewrite the adapter — no pipeline scripts need to change.

## Available Adapters

| Adapter | Default Tool | File |
|---------|-------------|------|
| Issue Tracker | Linear CLI | `adapters/tracker.sh` |
| Notifications | Slack (webhooks + Bot API) | `adapters/notify.sh` |
| Code Generation | Claude CLI | `adapters/ai-code.sh` |
| Research | Gemini CLI | `adapters/ai-research.sh` |
| Code Review | 3-layer (Flash + Pro + Sonnet) | `adapters/ai-review.sh` |

## Interface Contracts

### tracker.sh

```bash
tracker.sh list <state1> [state2 ...]       # list issues by state
tracker.sh view <id>                         # view issue details (stdout)
tracker.sh create <title> <priority> [opts]  # create issue
  --state <state>                            #   initial state
  --description <text>                       #   description
  --label <name>                             #   label
tracker.sh update <id> [opts]                # update issue
  --state <state>
  --priority <1-4>
tracker.sh comment-list <id>                 # list comments
tracker.sh comment-add <id> <body>           # add comment
tracker.sh issue-url <id>                    # return web URL
tracker.sh board-url                         # return board URL
```

### notify.sh

```bash
notify.sh send <channel> <message>           # send via webhook
notify.sh send-async <channel> <message>     # non-blocking send
notify.sh thread-start <channel> <message>   # start thread, print ts
notify.sh thread-reply <channel> <ts> <msg>  # reply in thread
```

All commands accept `--as <identity>` to post as a named bot persona (changes display name and icon in Slack). Supported identities: `builder`, `reviewer`, `triage`, `discovery`, `health`, `tuner`.

Channels: `automation`, `review`, `changelog` (mapped to IDs in project.env).

### ai-code.sh

```bash
ai-code.sh run <prompt> [opts]
  --max-turns <n>                            # max conversation turns
  --json-output <file>                       # save full JSON response
  --model <model>                            # override model
```

### ai-research.sh

```bash
ai-research.sh prompt <text> [opts]
  --model <model>                            # override model
  --output <file>                            # save to file
```

### ai-review.sh

```bash
ai-review.sh layer1 <prompt> [opts]          # mechanical gate (Gemini Flash, failover: Pro)
  --json-output <file>
  --model <model>
ai-review.sh layer2 <prompt> [opts]          # architecture review (Gemini Pro, failover: Sonnet)
  --output <file>
  --model <model>
ai-review.sh layer3 <prompt> [opts]          # self-check (Claude Sonnet, failover: Pro)
  --json-output <file>
  --model <model>
```

Output includes a `REVIEW_CROSSCHECK` section that flags disagreements between layers.

## Writing a Custom Adapter

Example: swapping Linear for GitHub Issues.

1. Copy `adapters/tracker.sh` to `adapters/tracker-github.sh`
2. Rewrite each command to use `gh issue` instead of `linear issue`
3. Replace `adapters/tracker.sh` with your new file (or symlink)

Key rules:
- **Same interface, different implementation.** The pipeline scripts call `tracker.sh list unstarted` — your adapter must accept the same arguments.
- **Stdout contract.** `list` outputs one issue per line with the ID visible. `view` outputs issue details. `issue-url` outputs a URL.
- **Error handling.** Return non-zero exit code on failure. The pipeline handles errors gracefully.
- **State mapping.** Your tracker may use different state names. Map them: `unstarted` → `open`, `Done` → `closed`, etc.

## Example: GitHub Issues Adapter

```bash
# adapters/tracker.sh (GitHub Issues version)
case "$cmd" in
  list)
    state_map=("unstarted:open" "started:open" "backlog:open" "completed:closed")
    gh_state="open"
    for s in "$@"; do
      # map pilot states to GitHub states
      [[ "$s" =~ completed|canceled ]] && gh_state="closed"
    done
    gh issue list --state "$gh_state" --repo "$GITHUB_REPO" --json number,title,state
    ;;
  create)
    gh issue create --repo "$GITHUB_REPO" --title "$title" --body "$desc"
    ;;
  # ... etc
esac
```
