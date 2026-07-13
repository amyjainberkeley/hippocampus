# adapters/macos/mci-mail-reader/

Rust deep-hook for the macOS Mail app: read-only tail of the
`.emlx` maildir under `~/Library/Mail/` that emits normalized Mail
events into the brain ingest pipeline. ADR-0032 plugin contract,
ADR-0030 threat model.

## Contents

- `src/lib.rs` — crate root; the `MailReader` handle.
- `src/discover.rs` — locates the Mail maildir and enumerates
  `.mbox` accounts.
- `src/emlx.rs` — `.emlx` file parser (Apple's variant of `.eml` with
  a leading byte-count and trailing plist).
- `src/parse.rs` — MIME parsing → normalized event.
- `src/envelope.rs` — header extraction (From/To/Subject/Date/
  Message-ID).
- `src/watch.rs` — file-system watcher that triggers incremental
  reads.
- `src/error.rs` — surfaces reader errors upward (no silent fall-back).
- `src/bin/` — CLI utilities for local inspection.
- `tests/` — integration tests with fixture `.emlx` corpora.
- `Cargo.toml` — the `mci-mail-reader` package manifest.

## Related

- `../mci-messages-reader/` — sibling deep-hook for Messages.app.
- `../../../core/brain/src/redaction/mail_header.rs`,
  `parsed_mail_header.rs` — redaction the reader feeds into.
- `../../../docs/decisions/0020-media-consumption-cascade-outcome.md`,
  `0030-messages-mail-redaction-threat-model.md`,
  `0032-deep-hook-plugin-contract.md`.

## When to edit here

Any change to `.emlx` parsing, mbox enumeration, or the incremental
watcher. Redaction / sensitive-domain rules live in
`../../../core/brain/src/redaction/`. Full Disk Access UX lives in
`../../../apps/onboarding/`. Threat-model changes are CSO-gated.
