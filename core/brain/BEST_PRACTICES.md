# core/brain/BEST_PRACTICES.md

Subtree invariants for the encrypted brain crate. Everything the
top-level `BEST_PRACTICES.md` says still applies — this file adds
crypto- and store-specific rules that are non-obvious from the
source alone.

## Purpose

`mci-brain` owns the SQLCipher-encrypted store, the embedding
pipeline, and the retrieval fusion. Because the store holds the
user's entire recall corpus, a single silent bug here can produce
a total-privacy failure. Rules below are load-bearing.

## Rules

1. **Key custody stays in the OS keychain.** The SQLCipher key is
   derived per ADR-0008 and MUST NOT be logged, panicked-with, or
   passed through error messages. If a code path needs to signal a
   key-derivation failure, return a typed `StoreError` variant with
   no key bytes attached.

2. **HKDF salt discipline.** Any new derived key (per-column,
   per-index, per-migration) MUST use a fresh, documented salt.
   Never reuse a salt across purposes. Salts belong in
   `sqlcipher_brain_store.rs` as named constants, not inline hex.

3. **Read-only default via FFI.** `mci-brain-ffi/` opens the store
   with `SQLITE_OPEN_READ_ONLY`. Any mutation surface consumed by
   Swift must be explicitly added to the FFI allow-list and CSO-
   reviewed. Do NOT add a write path "just for tests" — use a
   test-only cfg-gated helper instead.

4. **`integrity_check` gates.** Per PR #73, the agent refuses to
   serve queries if the weekly `PRAGMA integrity_check` fails.
   Never bypass `integrity_scheduler.rs` by opening the store
   directly for a "quick fix" — corruption must fail loudly.

5. **Schema-version handling.** Migrations under `migrations/` are
   append-only and versioned. Never edit a shipped migration; add
   a new one. Downgrade paths are unsupported by design; the
   version check in `sqlcipher_brain_store.rs` MUST refuse a store
   newer than the binary.

6. **No plaintext leakage in logs.** Extraction, redaction, and
   retrieval logs may include row counts and IDs but NEVER content
   snippets. `redaction/` is the last line before disk; do not
   log around it.

## Common mistakes

- Adding a `Store::open_rw()` for a test and forgetting to gate it
  behind `#[cfg(test)]` — leaks a write handle into shipping code.
- Using `unwrap_or_default()` on a decryption error, producing an
  empty result set that looks like "no matches" to callers. See
  top-level rule 1.
- Bumping the `mci-brain` public API without updating
  `../adapters/macos/mci-brain-ffi/` — breaks the Swift build.
- Copying an HKDF salt from an existing derivation for a new
  purpose. Always fresh salt per purpose.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root contract).
- `./README.md` — crate map and edit rules.
- `../../docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md`,
  `0011-embedding-model-snowflake-arctic-embed-s.md`,
  `0016-phase-3-ocr-brain.md`,
  `0021-brain-key-portability.md`,
  `0030-messages-mail-redaction-threat-model.md`.
