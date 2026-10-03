# Desktop transcript consent boundary

Baseline: `439d058`. This bounded checkpoint protects the upcoming desktop
upgrade; it does not install the app or change the owner's existing settings.

The desktop must not begin importing all local Claude/Codex transcripts merely
because a newer daemon starts. Registering MCP tools must not silently install
SessionStart hooks or a background transcript importer. Sharing already stored
memory and importing raw sessions are separate choices.

1. Require an explicit daemon opt-in; keep the existing disable switch dominant.
   The desktop launch plan explicitly disables transcript refresh, including
   when its parent environment contains an enable flag. A desktop importer
   preference with live revocation remains future work; do not imply one exists.
2. Add `register-clients`, which registers tools and preserves existing
   hook/LaunchAgent files byte-for-byte. Use it from the desktop connector.
   Apply the same command in onboarding (including its recovery command).
   Desktop-created Claude session hooks compile existing memory with
   `--no-refresh`; context-sharing consent never implies transcript import.
   Explicit existing CLI `init`, `refresh`, `import-sessions`, and full `connect`
   retain their documented import/setup behavior.
3. Prove default-off, inherited-environment isolation, connector arguments, and
   actual registration-only CLI behavior using isolated synthetic homes. Run
   affected Swift and Rust suites, independent review, and publish a draft
   checkpoint with precise installation/release boundaries.

Ruling: do not mutate or uninstall any previously configured user hooks or
LaunchAgents. This update prevents new implicit setup; existing explicit CLI
connections retain their behavior and require separate review before upgrade.

Ruling: use a distinct subcommand, not a new `connect` flag. Older agents ignore
unknown flags and would otherwise install hooks despite the caller's intent;
they reject unknown subcommands before touching client setup.
