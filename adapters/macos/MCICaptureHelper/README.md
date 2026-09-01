# adapters/macos/MCICaptureHelper/

The Swift capture helper is a separately signed process (ADR-0007) that
owns the ScreenCaptureKit lifecycle, applies the ADR-0013 sensitive-
surface suppression cascade before any frame or metadata crosses IPC,
and retains only condensed encrypted JPEG evidence after OCR privacy approval.

## Contents

- `Package.swift` — Swift-PM manifest. Two products:
  - `MCICaptureHelper` (executable) — the `@main` entry point.
  - `MCICaptureHelperKit` (library) — protocols, cascade logic, and
    view models, split so unit tests can link them without the
    binary.
- `Sources/` — the two targets above.
- `Tests/` — XCTest suites covering the cascade decision matrix and
  the wire encoder.

## Related

- `../../../core/src/ipc/` — the wire format this helper writes to.
- `../mci-brain-ffi/` — sibling FFI shim used by the Swift apps.
- `../../../docs/decisions/0007-macos-capture-separate-signed-helper-process.md`,
  `0013-native-grade-sensitive-surface-suppression.md`,
  `0031-focused-window-capture-scope.md`.
- `../../../tools/` — read-only observation harness that decodes the
  helper's wire output.

## When to edit here

Any change to SCStream wiring, the sensitive-surface cascade, post-OCR
evidence retention, or IPC serialization on the Swift side.
Cascade / capture-scope changes are CSO-gated. If the change is
platform-independent (dedupe, wire schema shape), it belongs in
`../../../core/` — do NOT duplicate it here.
