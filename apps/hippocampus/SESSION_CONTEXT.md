# Opt-in session context

Preferences > Sources separates MCP registration, Claude session context, and
Codex context instructions. Opening Preferences is read-only. Configuration is
not a delivery receipt and does not prove that a client/model used memory.

## MCP registration and transcript import

The desktop, menu, and onboarding invoke `mci-agent register-clients`. This
registers read-only memory tools with detected clients; it does not install
SessionStart hooks, load a LaunchAgent, or import transcripts. Existing hook
and importer settings remain unchanged. Older agents reject this distinct
subcommand instead of silently ignoring a new flag on `connect`.

Desktop daemon launches disable periodic raw transcript import using both the
new enable flag and the legacy kill switch. The app has no automatic transcript
import preference yet. A separately launched CLI daemon can opt in through
`MCI_TRANSCRIPT_REFRESH_ENABLED=1`; the existing disable switch takes precedence.
Explicit CLI `init`, `connect --all`, `refresh`, and `import-sessions` retain
their documented import/setup behavior. Previously installed full CLI hooks
and refresh LaunchAgents are not silently removed during an app update.

## Claude Code

The app merges one `hooks.SessionStart` group into user `settings.json` under
`~/.claude` (or the app's absolute `CLAUDE_CONFIG_DIR`). It matches startup,
resume, clear, and compaction. The command invokes the bundled sibling agent:

```text
'<bundle>/mci-agent' handoff --format claude-hook --db-path '<brain>' --no-refresh
```

The paths are shell quoted. `--no-refresh` compiles from already stored memory
without reading raw local session files. The compiler can inspect the selected
project's local git metadata and record a delivery receipt when its writer
lease is available. Context-sharing consent is separate from transcript-import
consent. The packet is cited and bounded, with a fallback envelope on failure.
Repository, worktree and session scope are described in the packet; directory
focus is not a strict isolation boundary. See the handoff contract and tests
for the compiler's current behavior.

The installer recognises the previous command without `--no-refresh` and the
older app-level `--claude-session-context` hook. Explicit Enable replaces a
known prior group in place; Remove accepts all known shapes. Merely opening
Preferences does not rewrite existing hooks. An edited or relocated entry
requires review instead of silent replacement. Managed policies and disabled
hooks remain authoritative. Restart Claude after configuration changes.

The legacy app-level hook remains supported for already configured clients. It
ignores transcript paths, runs bounded local retrieval, keeps citations intact,
and returns a content-free fallback on failure. It is not installed anew.

## Codex

The app appends an opt-in marked block to `$CODEX_HOME/AGENTS.md` (default
`~/.codex/AGENTS.md`), preserving surrounding text. It requests the existing
MCP `mci_context` tool at task start with a 1000-token/12-evidence budget and a
refresh after resume/compaction when needed. MCP registration is separate.

This is client-directed retrieval. Tool permission, instruction overrides,
availability and client policy still apply. The installer refuses to enable
beneath a nonempty `AGENTS.override.md`; it never changes that file or hook
trust. Restart Codex to load changed instructions. Other profiles, hosts and
cloud sessions are not configured.

## Privacy and verification

The database stays on this Mac. **Clients and their model providers may receive
retrieved memory and retain it in session history.** Removing configuration
cannot retract already shared context. No reusable keys are written into
client settings.

Installers remove only exact app-owned entries. Malformed, oversized, linked,
non-user-owned, ambiguous or edited settings are refused. Writes use private
temporary files, atomic replacement, an installer lock and a second snapshot
check. Unrelated hooks and instructions remain intact. Client settings writers
do not share the app's advisory lock; avoid concurrent client edits.

`Tests/Standalone/test-session-context.sh` checks quoted arguments, settings
preservation, canonical and legacy hooks, bounded legacy retrieval, citations,
failure handling and timeouts using disposable directories and fake agents.
Swift package tests cover desktop registration arguments, upgrade compatibility
and launch environments. Rust CLI tests cover actual registration in isolated
homes. These tests do not establish live client delivery or installation
qualification; see `docs/STATUS.md` for those separate boundaries.
