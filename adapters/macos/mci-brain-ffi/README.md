# adapters/macos/mci-brain-ffi/

Rust C-ABI shim that exposes the `mci-brain` crate to Swift callers
(RecallUI, Hippocampus). Opens the SQLCipher connection with
`SQLITE_OPEN_READ_ONLY` — the UI never writes to the brain.

## Contents

- `src/lib.rs` — the C-ABI surface: `mci_brain_open`, `mci_brain_query`,
  `mci_brain_close`, and the `#[no_mangle] extern "C"` entry points
  RecallUI links against.
- `include/` — the generated `mci_brain_ffi.h` header consumed by
  Swift's `CMciBrainFFI` module.
- `tests/` — integration tests exercising the FFI surface against a
  test-fixture brain.
- `Cargo.toml` — the `mci-brain-ffi` package manifest;
  `crate-type = ["staticlib"]`.

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
bearing invariant — do NOT relax it without CSO sign-off.
