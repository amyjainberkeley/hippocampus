## Handoff layer: your agents pick up where you left off

Branch `feat/handoff-layer` on top of `codex/hippocampus-v1`. Direction from the Sep 25 PRD, order changed after the Sep 26 audit: transcripts and git first, screen second.

**What it adds**

- `import-sessions` reads Claude Code and Codex transcripts incrementally (migration 0011 `import_cursors`); events carry `session=` and `src=path:line`; mutating tool calls become one-line `tool` events; system-injected user text is skipped.
- `refresh` imports and enriches new events within a budget. The capture writer runs it every 60 s; the CLI and hooks skip with a printed reason when the app holds the writer lease.
- `handoff --cwd DIR` compiles a cited, budgeted packet (where you stopped, next step, goal, decisions, avoid, open questions, files, git, sources). `--format claude-hook | codex-hook` prints the SessionStart envelope and always exits 0 within 8 s.
- `today` writes the day's standup across projects.
- `connect --all` installs the SessionStart hooks for Claude Code and Codex plus a LaunchAgent; `disconnect --all` removes only those. The Swift installer writes the identical group.
- `doctor` gains transcripts, delivery and refresh-agent lines. `scripts/install.sh` installs the signed CLI with no screen permission. `scripts/e2e-handoff.sh` proves the loop with real agents.

**Verification at source**: `cargo test -p mci-agent` (452 lib + all integration files), `cargo test -p mci-brain`, clippy `-D warnings` on both, fmt, `swift test --filter SessionContextInstaller` (13). See `docs/STATUS.md` "September 26 Handoff Layer" for what is and is not verified on the owner's Mac.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
