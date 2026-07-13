# server/

The MCI workspace sync server (v1.5+): a Tier-2 encrypted brief
store + device enrollment endpoint. Zero-knowledge — the server
must never be able to read user content (AGENT_PROTOCOL §4;
ADR-0019). Any change to crypto/sync/key-management here is
CSO-gated.

## Contents

- `src/main.rs` — the shipping binary.
- `src/lib.rs` — library entry.
- `src/handlers.rs` — Axum HTTP handlers (upload, download,
  enrollment endpoints).
- `src/enrollment.rs` — device enrollment + attestation flow.
- `src/model.rs` — request/response types.
- `src/store/` — SQLite-backed encrypted-blob store.
- `src/crypto/` — server-side wrap/verify (the server holds only
  wrapped keys, never plaintext content keys).
- `src/crash_report.rs` — the opt-in crash-uploader receiver.
- `tests/` — integration tests over the HTTP surface.
- `Cargo.toml` — the `mci-server` package manifest.

## Related

- `../core/src/crypto/` — the client-side key wrap this server
  interoperates with.
- `../docs/decisions/0019-company-workspace-server-tier-2-store.md`,
  `0023-multi-device-sync-model.md`,
  `0025-analytics-telemetry-policy.md`.

## When to edit here

HTTP surface, enrollment flow, encrypted-blob storage, and the
crash-report receiver. Zero-knowledge is a load-bearing invariant:
if a change would let the server observe plaintext content, STOP
and escalate to CSO. Anything client-side (key derivation, wrap,
retrieval) belongs in `../core/`, not here.
