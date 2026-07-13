# apps/agent/

`mci-agent` — the Rust agent binary. Supervises the capture helper,
owns the per-device id, runs the IPC select! loop, and hosts the
inbound MCP server surface. Per ADR-0007 (separate helper process),
this is the parent process; the helper is a signed child.

## Contents

- `src/lib.rs` — library entry.
- `src/bin/mci_agent.rs` — the shipping binary.
- `src/bin/mci_brain.rs` — brain CLI (query, inspect, migrate).
- `src/bin/mci_seed_brain.rs`, `mci_seed_brief.rs` — demo-only
  seeders (documented in-file; refuse to overwrite a non-empty
  brain).
- `src/supervisor.rs`, `pump_supervisor.rs`,
  `mcp_client_supervisor.rs` — child-process supervision trees.
- `src/*_worker.rs`, `*_ingest.rs`, `idle_batch.rs` — the async
  workers (episode, consolidator, retention, brief, alias_resolver,
  tier2 NER/Qwen, health, page_content, mail/messages ingest).
- `src/mcp/` — inbound MCP *server* surface (MCI exposes tools).
- `src/mcp_aggregator.rs` — fan-out to external MCP servers via
  `../../core/mcp-client/`.
- `src/panic_hook.rs`, `panic_uploader.rs`, `crash_recovery.rs` —
  crash-safety surfaces.
- `src/device_id.rs` — per-device id (never leaves the device).
- `tests/` — integration + supervisor tests.
- `Cargo.toml` — the `mci-agent` package manifest.

## Related

- `../../core/` — the crate this binary links.
- `../../adapters/macos/MCICaptureHelper/` — the child process this
  binary supervises.
- `../hippocampus/` — the SwiftUI parent that launches `mci-agent`.
- `../../docs/decisions/0007-macos-capture-separate-signed-helper-process.md`.

## When to edit here

Any change to supervision, worker orchestration, the IPC select!
loop, panic/crash handling, or the inbound MCP server. If the change
is about the capture wire format, brain schema, or crypto, it lives
in `../../core/`, not here. Wiring a new deep-hook adds a `*_ingest`
worker here + the reader crate under `../../adapters/`.
