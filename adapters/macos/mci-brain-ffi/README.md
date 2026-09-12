# adapters/macos/mci-brain-ffi/

Rust C-ABI shim that exposes the `mci-brain` crate to Swift callers
(RecallUI, Hippocampus). Opens the SQLCipher connection with
`SQLITE_OPEN_READ_ONLY` for every recall and timeline query. The only writes
are explicit Privacy Dashboard delete/wipe operations; those take the shared
writer lease and open a short-lived writable connection after confirmation.

`mci_brain_ffi_open` is the compatibility lexical path.
`mci_brain_ffi_open_with_model` additionally loads Arctic Embed S through
Core ML and routes search through the same `HybridRetriever` used by the MCP
agent. A model-load failure is explicit so the Swift app can report it and
retry the lexical path without making the brain unavailable.

## Contents

- `src/lib.rs` — the `mci_brain_ffi_*` C-ABI entry points linked by Recall.
- `include/` — the generated `mci_brain_ffi.h` header consumed by
  Swift's `CMciBrainFFI` module.
- `tests/` — integration tests exercising the FFI surface against a
  test-fixture brain.
- `Cargo.toml` — the `mci-brain-ffi` package manifest; it emits both a
  `staticlib` for Swift and an `rlib` for Rust integration tests.

## Related

- `../../../core/brain/` — the crate this shim wraps.
- `../../../apps/recall-ui/Sources/CMciBrainFFI/` — the Swift module
  map that imports this header.
- `../../../apps/hippocampus/Sources/HippocampusKit/` — also links
  the shim.

## When to edit here

Any change to the C-ABI surface exposed to Swift — new entry points,
new opaque handle types, or header layout changes. Bumping the
underlying `mci-brain` API without updating this shim will break the
Swift build. Read-only guarantee (SQLITE_OPEN_READ_ONLY) is a load-
bearing invariant. New mutation entry points are protected-set changes and
must not be added without security review.
