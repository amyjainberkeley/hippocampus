# Hippocampus 0.2.0

Your coding agents pick up where you left off. This release adds the handoff layer: every Claude Code and Codex session starts with a short, cited packet compiled from the transcripts your agents already wrote on this Mac.

## Install the CLI (no permissions asked)

```bash
curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
```

Downloads the signed `mci-agent`, verifies its SHA-256, imports `~/.claude/projects` and `~/.codex/sessions`, and installs the SessionStart hooks. Codex will ask you once to trust the hook.

## Install the app (screen capture, optional)

`Hippocampus-0.2.0.dmg`: signed and notarized menu-bar app. Adds on-device screen text (PaddleOCR at native resolution) as extra cited evidence, and keeps the brain fresh every 60 seconds while it runs.

## What is new

- `mci-agent handoff`: where you stopped, next step, goal, decisions, avoid, files touched, git state, sources. 600 tokens by default, deterministic, every line cited.
- Codex sessions are imported alongside Claude Code sessions, incrementally, with file:line sources and one-line evidence for file edits and commits.
- `mci-agent today`: the day's standup across projects.
- `mci-agent connect --all` / `disconnect --all`, `doctor` freshness and delivery lines, `refresh`.
- Offline PaddleOCR replaces Apple Vision for screenshots; the app accepts genuine Quit requests; installer and branding fixes.

## Known limits

- macOS only, Apple Silicon build. Intel users build from source.
- Screen capture needs the Screen Recording permission and re-asks after app updates.
- Packets are extractive; if a project has no transcript history yet, the packet says so.

Full details: `CHANGELOG.md`, `docs/STATUS.md`.
