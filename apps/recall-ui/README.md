# apps/recall-ui/

The recall SwiftUI app — a read-only consumer of the Phase-3 brain.
Never writes to the store; links `../../adapters/macos/mci-brain-ffi/`
which opens the SQLCipher connection with `SQLITE_OPEN_READ_ONLY`.
Phase 3 P3.9 (ADR-0016 §6).

## Contents

- `Package.swift` — Swift-PM manifest. Three products:
  - `RecallUI` (executable) — the `@main` app.
  - `RecallUIKit` (library) — view models + protocols, split for
    testability.
  - `CMciBrainFFI` (system library) — the C-module map importing
    the Rust FFI header.
- `Sources/` — the three targets above.
- `Tests/` — XCTest suites (view-model state, FFI wrappers).

## Related

- `../../adapters/macos/mci-brain-ffi/` — the Rust C-ABI shim this
  app links.
- `../../core/brain/` — the brain crate behind the FFI.
- `../hippocampus/` — the parent shell (in unified builds RecallUI
  ships as a view inside Hippocampus).
- `../../docs/design/recall-ui-feature-audit.md`,
  `../../docs/decisions/0016-phase-3-ocr-brain.md`.

## When to edit here

Recall UI screens, view models, and query composition. Read-only
guarantee (SQLITE_OPEN_READ_ONLY through the FFI) is load-bearing —
do NOT relax it. If the change is about brain schema, retrieval, or
ranking, it belongs in `../../core/brain/`, not here.
