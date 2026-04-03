# Pilot Documentation

## What lives here (code-referenced, stable paths)

These docs are read by scripts, Claude sessions, or CI. **Do not move or rename without updating all references.**

| File | Referenced by | Purpose |
|------|--------------|---------|
| `pilot-architecture.md` | `~/.claude/CLAUDE.md` | Pipeline design, model allocation, agents, data flow |
| `pilot-responsibilities.md` | `~/.claude/CLAUDE.md` | What's automated vs what Aaron does manually |
| `architecture.md` | `README.md` | Concise pipeline overview |
| `adapters.md` | `README.md` | Adapter interfaces and contracts |
| `tuning.md` | `README.md` | Budget and review auto-tuning |
| `deployment.md` | `README.md` | Setup and deployment guide |

## What lives in Obsidian (personal notes, not code-referenced)

Aaron's thinking, planning, and visual diagrams live in Obsidian under `Vibe Coding Projects/Pilot/`. No code depends on these files — they can be reorganized freely.

## What lives in Obsidian but IS code-referenced

Product context files for Lift are referenced by `PRODUCT_DECISIONS_FILE` and `PRODUCT_FEATURES_FILE` in `project.env`. These paths are consumed by `discover.sh` and `triage.sh`. If you move these files in Obsidian, update the paths in `project.env`.

## Rule of thumb

If code reads a doc by path → it goes here in `docs/`.
If it's personal notes or planning → it goes in Obsidian.
If it's product context that you edit in Obsidian → reference it via `project.env` variables.
