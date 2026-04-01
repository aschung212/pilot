# Pilot

An autonomous multi-agent pipeline that discovers, triages, implements, and reviews improvements to your software — running overnight while you sleep.

> **Status**: Active development. Currently powering [Lift](https://github.com/aschung212/Lift), a workout tracker PWA.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    OVERNIGHT PIPELINE                        │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐               │
│  │ Discovery │───▶│  Triage  │───▶│ Builder  │               │
│  │ (research │    │ (review  │    │ (code    │               │
│  │ + issues) │    │ + plan)  │    │ + ship)  │               │
│  └──────────┘    └──────────┘    └──────────┘               │
│       │               │               │                      │
│       ▼               ▼               ▼                      │
│  Issues created  Impl. plans     Commits, PRs,              │
│  in tracker      added           tracker updated             │
│                                       │                      │
│                              ┌────────┴────────┐            │
│                              │ PR Review        │            │
│                              │ + Auto-Tuners    │            │
│                              │ + Cleanup        │            │
│                              └─────────────────┘            │
└─────────────────────────────────────────────────────────────┘
```

Each stage runs independently on its own schedule. Your issue tracker (Linear, GitHub Issues, etc.) serves as the shared state store between stages.

## Quickstart

```bash
git clone https://github.com/aschung212/pilot.git
cd pilot
./init.sh
```

The interactive initializer walks you through:
1. Project basics (name, repo, tech stack)
2. Issue tracker setup (Linear, GitHub Issues, or custom)
3. AI model selection (Claude, Gemini, ChatGPT)
4. Notification setup (Slack webhooks)
5. Scheduling preferences
6. Discovery focus areas for your project

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full design, including:
- Service decomposition and independent scheduling
- Eventual consistency via issue tracker state machine
- Backpressure signaling
- Self-tuning budgets and review quality

## Adapters

Components are swappable via thin adapter scripts. See [docs/adapters.md](docs/adapters.md).

| Adapter | Default | Alternatives |
|---------|---------|--------------|
| Issue tracker | Linear | GitHub Issues, Jira |
| Notifications | Slack webhooks | Discord, email |
| Code generation | Claude | — |
| Research | Gemini | ChatGPT, Perplexity |
| Code review | Sonnet + Gemini | — |

## Self-Tuning

The pipeline optimizes itself over time. See [docs/tuning.md](docs/tuning.md).

- **Budget tuner**: Adjusts iteration caps and token limits based on productivity patterns
- **Review tuner**: Learns from your PR feedback to improve future reviews
- **Health report**: Weekly dashboard with anomaly detection

## Requirements

- macOS (uses launchd for scheduling)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) (optional, for research + review)
- An issue tracker CLI ([Linear CLI](https://github.com/linear/linear-cli), or `gh` for GitHub Issues)
- Slack workspace with incoming webhooks (optional, for notifications)

## License

MIT
