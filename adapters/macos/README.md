# adapters/macos/

macOS-specific implementations of the seams the portable `core/`
defines: capture helper, brain FFI, deep-hook readers, and embedding
backends. Per ADR-0002 (stack split) + ADR-0007 (helper as separate
signed process), everything OS-specific lives under `adapters/<os>/`
and never above the `CaptureSource` trait.

## Contents

- `MCICaptureHelper/` — the Swift helper process. Owns SCStream,
  runs the ADR-0013 sensitive-surface suppression cascade BEFORE any
  frame or metadata crosses IPC, and ships HEVC keyframes via
  VideoToolbox.
- `mci-brain-ffi/` — Rust C-ABI shim exposing the brain to Swift
  callers (RecallUI). Read-only against SQLCipher.
- `mci-messages-reader/` — Rust deep-hook for `chat.db`
  (Messages.app). ADR-0032 plugin contract.
- `mci-mail-reader/` — Rust deep-hook for `.emlx` maildir (Mail.app).
- `mci-embed-coreml/` — Core ML backend for the embedder
  (Arctic-Embed-S per ADR-0011).
- `mci-coreml-bridge/` — Rust ↔ Core ML bridge crate (ADR-0033).

## Related

- `../../core/` — the portable core these adapters implement traits
  from.
- `../../adapters/windows/` — future sibling (not yet started).
- `../../docs/decisions/0002-stack-split-rust-core-native-adapters.md`,
  `0007-macos-capture-separate-signed-helper-process.md`,
  `0013-native-grade-sensitive-surface-suppression.md`.

## When to edit here

Any macOS-specific system call, entitlement, sandbox boundary,
Core ML wrapper, or TCC surface. If the change is *not* OS-specific,
push it up into `../../core/` instead. Capture/crypto/sensitive-
surface changes are CSO-gated (AGENT_PROTOCOL §4).
