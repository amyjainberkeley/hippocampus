# core/

The portable Rust core of MCI: capture pipeline, dedupe, crypto, IPC,
and the sub-crates that make up the brain and MCP outbound surface.
Everything above the `CaptureSource` trait lives here so nothing bakes
in OS-specific assumptions (ADR-0002).

## Contents

- `src/` — the `mci-core` crate root: `capture.rs`, `error.rs`,
  `crypto/` (key wrap, DB key derivation), `store/` (SQLCipher
  schema, migrations, tombstones), `ipc/` (helper ↔ agent wire
  format, fd-passing).
- `brain/` — the `mci-brain` crate: OS-free traits + production impls
  for OCR / embed / chunk / retrieve / index (Phase 3+).
- `brief/` — the brief-authoring pipeline (Qwen3-1.7B-CoreML per
  ADR-0028).
- `brief-eval/` — brief-quality evaluation harness (ADR-0018 §7).
- `mcp-client/` — pure-Rust JSON-RPC 2.0 client + stdio transport for
  V2-MCP aggregation.
- `Cargo.toml` — the `mci-core` package manifest.

## Related

- `../adapters/macos/` — macOS impls of the `CaptureSource` trait; no
  OS code may leak upward across the seam.
- `../apps/agent/` — Rust binary that links the core.
- `../BEST_PRACTICES.md` — errors surface, never fall back.
- `../docs/decisions/0002-stack-split-rust-core-native-adapters.md`.

## When to edit here

Any change to the portable pipeline, dedupe, store schema, crypto, or
IPC wire format lands here. If a change requires OS-specific system
calls, STOP — it belongs in an adapter under `../adapters/<os>/`.
Changes to crypto/sync/store are CSO-gated per AGENT_PROTOCOL §4.
