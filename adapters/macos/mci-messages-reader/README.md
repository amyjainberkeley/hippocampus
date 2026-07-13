# adapters/macos/mci-messages-reader/

Rust deep-hook for the macOS Messages app: read-only tail of
`chat.db` (SQLite) that emits normalized Message events into the
brain ingest pipeline. ADR-0032 plugin contract, ADR-0030 threat
model.

## Contents

- `src/lib.rs` — crate root; the `MessagesReader` handle.
- `src/discover.rs` — locates `~/Library/Messages/chat.db` and its
  attachments directory; validates permissions.
- `src/messages.rs` — SQL queries + row → normalized event mapping.
- `src/watch.rs` — file-system watcher that triggers incremental
  reads.
- `src/error.rs` — surfaces reader errors upward (no silent fall-back).
- `src/bin/` — CLI utilities for local inspection.
- `tests/` — integration tests with fixture `chat.db` snapshots.
- `Cargo.toml` — the `mci-messages-reader` package manifest.

## Related

- `../mci-mail-reader/` — sibling deep-hook for Mail.app.
- `../../../core/brain/src/redaction/messages_plugin.rs` — the
  redaction layer this reader feeds.
- `../../../docs/decisions/0030-messages-mail-redaction-threat-model.md`,
  `0032-deep-hook-plugin-contract.md`.

## When to edit here

Any change to `chat.db` schema handling, attachment discovery, or
the watch/incremental-read strategy. Redaction rules live in
`../../../core/brain/src/redaction/`, not here. Full Disk Access
requirements and the TCC prompt copy are Hippocampus-app concerns —
edit them under `../../../apps/hippocampus/`. Threat-model changes
are CSO-gated.
