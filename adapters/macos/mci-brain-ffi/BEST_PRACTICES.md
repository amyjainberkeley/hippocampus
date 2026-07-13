# adapters/macos/mci-brain-ffi/BEST_PRACTICES.md

Subtree invariants for the Rust C-ABI shim that exposes `mci-brain`
to Swift callers. Read the top-level `BEST_PRACTICES.md` first;
this file adds FFI-boundary rules.

## Purpose

`mci-brain-ffi` is the only place where the encrypted brain crosses
the language boundary into Swift. It defines the read-only wall
between the UI processes (RecallUI, Hippocampus) and the store.
Bugs here can silently produce write handles the UI shouldn't have,
or wire-format drift that corrupts every subsequent query.

## Rules

1. **Read-only is load-bearing.** The SQLCipher connection MUST
   be opened with `SQLITE_OPEN_READ_ONLY`. Do NOT add a "read-write
   variant" flag, a `Store::open_rw()` FFI entry point, or a debug
   toggle that relaxes this. Any mutation surface belongs in the
   agent binary, not here.

2. **Mutation allow-list requires CSO.** If a legitimate write
   path is needed (e.g., a bookmark, a feedback signal), it MUST
   be added to a named allow-list with an ADR entry and CSO sign-
   off. Never smuggle a write behind a "query" verb.

3. **Capped-input discipline.** Every `*const c_char` and slice
   pointer crossing the FFI MUST be length-capped and validated
   before consumption. An unvalidated caller-supplied length is a
   memory-safety hole; assume the Swift side has bugs.

4. **Wire-format stability.** Struct layouts, enum discriminants,
   and error codes exposed through `include/mci_brain_ffi.h` form
   a binary contract with the Swift consumers. Breaking changes
   require a version bump in the header AND coordinated updates
   in `apps/recall-ui/` + `apps/hippocampus/`.

5. **No panics across the FFI.** Rust panics unwinding into Swift
   are UB. Wrap every entry point in `catch_unwind`; on catch,
   return a well-formed error code, never a null handle without
   an error signal.

6. **Opaque handles stay opaque.** `mci_brain_open` returns an
   opaque pointer; Swift MUST NOT dereference it. Never expose
   internal struct layout in the header.

## Common mistakes

- Adding a debug entry point that opens the store read-write "just
  for a repro" and forgetting to remove it. Violates rule 1.
- Bumping the underlying `mci-brain` public API without
  regenerating the header or updating the Swift consumers — Swift
  build breaks in a way that's hard to bisect.
- Passing a Swift-owned `String` pointer into a Rust function that
  outlives the call — dangling pointer. Copy at the boundary.
- Letting a Rust `panic!` escape a `#[no_mangle] extern "C"` fn.

## Reference chain

- `../../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — shim map and edit rules.
- `../../../core/brain/BEST_PRACTICES.md` — the crate this wraps.
- `../../../docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md`,
  `0021-brain-key-portability.md`,
  `0033-mci-coreml-bridge-rename.md`.
