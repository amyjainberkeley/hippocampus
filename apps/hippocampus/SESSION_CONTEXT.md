# Opt-in session context

Preferences > Sources has separate actions for MCP registration, Claude session
context, and Codex context instructions. Opening Preferences is read-only. Nothing
is installed until the user explicitly enables it. Configuration status is not a
delivery receipt, and does not claim that a client/model used memory.

## Claude Code

The installer merges one `hooks.SessionStart` group into user `settings.json`
under `~/.claude` (or the app's absolute `CLAUDE_CONFIG_DIR`). It matches `startup`,
`resume`, `clear`, and `compact`. The command is a shell-quoted absolute path to
the installed Hippocampus executable, with `--claude-session-context --db-path`
and a fixed absolute database path. Move/reinstall the app at the same location;
an edited or stale entry requires review instead of silent replacement.

This mode runs before SwiftUI, the supervisor, and Recall are constructed. It
reads at most 64 KiB of hook input, with a one-second input deadline. It ignores
transcript paths and passes the working directory as one `--focus` argument to
the bundled sibling `mci-agent context --max-tokens 1000 --max-evidence 12
--format markdown`. The directory is not executed or used as the child process
working directory. Focus is a relevance query, **not project isolation**: results
can contain memory from other projects.

Retrieval has a six-second deadline and an 8 KiB output bound. The whole canonical
packet, including truth state and event citations, is returned as SessionStart
`hookSpecificOutput.additionalContext`. Empty packets remain empty. Errors,
invalid input, missing Keychain access, and oversized packets produce a short
unavailable/limit message with no memory. Oversized packets are discarded rather
than sliced through citations. No raw error diagnostics are passed to the model.
The hook exits successfully so retrieval failures do not block the session.

The child environment contains only standard local process paths and public
Keychain references. No reusable keys, client tokens, or ambient DB overrides are
serialized or inherited. No context files are written and no network transmission
is added by this integration. **Claude/model providers may receive this memory
and retain it in session history.** Removing the hook cannot retract prior context.

Restart Claude after configuration changes. Managed policy, disabled hooks,
client versions, cloud sessions, and another terminal's config-directory override
can prevent a local user hook from running. Only local settings are inspected;
the app does not override managed policy or claim to verify delivery.

## Codex

The opt-in installer appends a marked instruction block to `$CODEX_HOME/AGENTS.md`
(default `~/.codex/AGENTS.md`), preserving surrounding text exactly. It requests
the existing Hippocampus MCP `mci_context` tool at task start, with a 1000-token/
12-evidence budget, and a refresh after resume/compaction only when needed.
MCP must be registered separately through the existing connector.

This is **client-directed retrieval, not a deterministic hook**. It may require
tool approval, may be overridden by project instructions, may hit the instruction
size limit, or may not run. The installer refuses to enable beneath a nonempty
`AGENTS.override.md`; it never changes that file, hook trust, permissions, or
`config.toml`. No synthetic Codex lifecycle configuration is generated. The local
CLI inspected was `codex-cli 0.153.4`; its help advertises MCP configuration and
hook trust controls, which alone do not establish a portable context hook schema.
Restart Codex to load updated instructions. The same model-provider consent and
history limitations apply. Other profiles/hosts/cloud sessions are not configured.

## Settings safety and verification

Both installers are repeatable and remove only exact app-owned entries. Edited
entries, malformed/oversized files, and linked or non-user-owned files are refused.
Writes use private temporary files, atomic rename, an app-installer lock, and a
second snapshot check. Unrelated JSON values/hooks and Codex text are retained;
JSON whitespace/key ordering may change. Client settings writers do not share the
app's advisory lock: avoid concurrent client edits while enabling/removing.

Run `bash apps/hippocampus/Tests/Standalone/test-session-context.sh` from any
directory. It compiles the production integration code through the Swift wrapper
and tests only disposable directories and fake agent executables. It does not
open the real database, read Keychain keys, install client settings, or contact a
model. A real-client end-to-end delivery test remains an explicit opt-in follow-up.

Official references checked September 5, 2026:
- [Claude hook configuration, SessionStart input and additionalContext](https://code.claude.com/docs/en/hooks)
- [Claude settings locations and overrides](https://code.claude.com/docs/en/settings)
- [Codex AGENTS.md discovery and precedence](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
