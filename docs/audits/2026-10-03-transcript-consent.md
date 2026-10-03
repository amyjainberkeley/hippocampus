# Desktop transcript consent checkpoint

Baseline: `439d058`. Source changes only; no installed app, owner settings,
private brain, permissions, website or public release changed.

## Behavior

Starting a newer capture daemon previously enabled periodic Claude/Codex
transcript import unless a disable variable was set. Connecting AI tools from
the menu or onboarding also called the full CLI setup command, which installed
session hooks and a refresh LaunchAgent. Neither action disclosed that scope.

- Periodic daemon import now requires `MCI_TRANSCRIPT_REFRESH_ENABLED=1` (or
  `true`); missing or unrecognised values stay off. The legacy disable switch
  remains dominant. Desktop launches explicitly set both the new enable flag
  to `0` and the existing disable flag to `1`, including across old-agent
  compatibility and inherited environment overrides.
- Desktop, menu and onboarding use the new `register-clients` command. It only
  registers MCP tools. Hooks, LaunchAgents and transcripts are not touched.
  A distinct subcommand fails closed on older agents; an unknown `connect`
  flag would have been silently ignored. The onboarding recovery command uses
  the same scope, and empty output no longer claims a verified connection.
- Newly enabled desktop Claude hooks use `handoff ... --no-refresh`. Existing
  memory sharing does not authorize raw session import. Known previous hooks
  can be inspected, explicitly converted in place, or removed. Edited or
  ambiguous groups still fail closed; unrelated hooks remain intact.
- Explicit CLI `init`, full `connect --all`, `refresh`, and `import-sessions`
  retain their documented behavior. Existing owner hooks/importers are not
  automatically rewritten or removed. There is no desktop automatic-import
  preference yet; adding it needs explicit consent and reliable revocation.

## Verification

All builds and tests used minimal constructed environments. Fixtures used
synthetic data and disposable locations.

- Regressions first reproduced default-on daemon import, connector setup scope,
  an inherited enable flag, absent old-daemon kill-switch enforcement, an
  importing desktop hook, and rejection of the previous canonical hook.
- The final full parent suite passes **365** tests; the onboarding suite passes
  **245**. The standalone session-context behavior suite passes, including
  shell quoting, the complete `--no-refresh` argument, settings preservation,
  legacy context retrieval, cancellation deadlines, and citation integrity.
- `cargo test -p mci-agent` passes **844** tests across library, binaries and
  integrations. Two existing specialized tests remain ignored: the on-device
  NER-model latency smoke and the separately driven retention picker contract.
  No new ignore or timeout relaxation was added.
- The actual CLI preserves pre-existing hook/importer files byte-for-byte,
  registers both synthetic clients, and never opens the scratch brain. A
  separate exact desktop-command probe, without `--no-refresh-agent`, confirms
  that first registration creates no hook or LaunchAgent files and a second
  run leaves all registered files unchanged.
- `cargo clippy -p mci-agent --all-targets -- -D warnings` passes. Rust format
  and patch whitespace checks pass.
- Independent review identified old-daemon compatibility, old-hook recognition,
  and a stale standalone expectation. Each was corrected and reverified; the
  follow-up review found no remaining actionable issues in this scope.
- The outgoing staged patch scan reports zero secret matches. This scoped scan
  does not replace the repository's earlier documented baseline findings.

Private diagnostic logs are outside the source tree. No live transcript, OCR
reading, screenshot, credential or memory database is included.

## Boundaries

The installed app remains the earlier notarized build. The Mac is still awaiting
owner unlock for OCR visual verification, and Screen Recording permission
requires owner approval. The prior OCR checkpoint's three Apple Vision fallback
test failures are unchanged; this checkpoint does not qualify the capture helper
or public downloads. Existing importer configuration, shortcut conflicts,
controlled app upgrade/rollback, live capture and handoff, signing and release
qualification remain open. Hippocampus and Superapp remain separate products.
