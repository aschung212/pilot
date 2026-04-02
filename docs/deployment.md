# Deployment Guide

Pilot runs on macOS using launchd for scheduling. It can run on your personal machine alongside your daily work, or on a dedicated machine (Mac Mini, etc.) that acts as a local CI server.

## Single Machine (default)

This is the setup `init.sh` creates. Everything runs on your laptop/desktop.

**Pros:** Simple, no extra hardware, scripts can access local files (Obsidian vault, repo).
**Cons:** Overnight builds consume CPU/memory while you sleep. If the machine sleeps, launchd fires missed jobs on wake (shorter build windows).

### Requirements
- macOS 13+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) (optional)
- [Linear CLI](https://github.com/linear/linear-cli) or `gh` (GitHub CLI)
- Node.js (for building/testing your project)
- Slack workspace with incoming webhooks (optional)

### Keep-awake

The builder needs the machine to stay awake overnight. Options:
- **System Settings → Energy → Prevent automatic sleeping** (simplest)
- `caffeinate -s &` before bed (prevents sleep until killed)
- `pmset` schedule: `sudo pmset repeat wake MTWRFSU 22:55:00` (wake 5 min before pipeline starts)

## Dedicated Machine

Move the pipeline to a separate Mac (Mini, old MacBook, etc.) that runs 24/7. Your personal machine is freed up entirely.

### What to install on the new machine

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USER/pilot.git ~/pilot

# 2. Install tools
brew install node gh
npm install -g @anthropic-ai/claude-code
npm install -g @anthropic-ai/linear-cli  # or your tracker CLI

# 3. Authenticate
gh auth login
linear auth
# Gemini: follow OAuth flow

# 4. Clone your project repo
git clone https://github.com/YOUR_USER/YOUR_PROJECT.git ~/development/your-project
cd ~/development/your-project && npm install

# 5. Configure
cp ~/pilot/project.env.example ~/pilot/project.env
# Edit project.env with paths for this machine

# 6. Set up webhooks
# Add SLACK_WEBHOOK_URL etc. to ~/.zshenv

# 7. Install launchd plists
cd ~/pilot && ./init.sh  # or manually copy plists to ~/Library/LaunchAgents/
```

### What changes in `project.env`

Only paths change. Everything else (Linear team, GitHub repo, models) stays the same.

```bash
# Personal machine
REPO_PATH="/Users/aaron/development/lift"
OUTPUT_DIR="/Users/aaron/Documents/Claude/outputs"
PRODUCT_DECISIONS_FILE="/Users/aaron/Documents/Obsidian Vault/.../Lift - Product Decisions.md"

# Dedicated machine
REPO_PATH="/Users/buildbot/development/lift"
OUTPUT_DIR="/Users/buildbot/pilot-outputs"
PRODUCT_DECISIONS_FILE="/Users/buildbot/pilot/project-docs/product-decisions.md"
```

### Handling the Obsidian vault dependency

The discovery and triage scripts read product decisions and feature lists from the Obsidian vault. On a dedicated machine, you have three options:

1. **Sync via iCloud/Dropbox** — if both machines use the same Apple ID, the vault syncs automatically. Point `PRODUCT_DECISIONS_FILE` to the synced path.

2. **Copy files into the pilot repo** — move `product-decisions.md` and `features.md` into `pilot/project-docs/`. Update `project.env` to point there. Edit the files in the repo instead of Obsidian. Simplest for a dedicated machine.

3. **Git submodule or symlink** — if you want to keep editing in Obsidian on your laptop, push the relevant files to a separate repo and pull them on the build machine.

Option 2 is recommended for dedicated machines — fewer moving parts.

### Headless operation

A dedicated Mac Mini can run headless (no monitor). Access it via:
- **SSH**: `ssh buildbot@mini.local` — run scripts, check logs, debug
- **Screen Sharing**: Built into macOS, enable in System Settings → General → Sharing
- **Slack**: All notifications already go to Slack — you monitor from your phone/laptop

### Auto-login and auto-start

For the machine to survive reboots:
1. **System Settings → Users → Login Options → Automatic login** (enable for the build user)
2. **launchd plists with `RunAtLoad`** — plists in `~/Library/LaunchAgents/` auto-load on login
3. **Energy Settings → Start up automatically after a power failure** (Mac Mini supports this)

### Network considerations

The pipeline needs internet access for:
- Linear API (issue CRUD)
- GitHub API (PR creation, CI checks)
- Slack webhooks (notifications)
- Claude API (code generation, reviews)
- Gemini API (research, triage)
- npm registry (if `npm install` runs during builds)

All outbound HTTPS. No inbound ports needed. Works on any home network.

## Multi-machine (future)

Not currently supported, but the architecture allows it:
- Discovery + triage on machine A
- Builder on machine B (more CPU for builds/tests)
- Linear is the shared state store — both machines read/write to it independently

This would require splitting `project.env` per machine and ensuring both have repo access. The adapter pattern makes this possible without script changes.
