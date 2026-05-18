# ADR-0005 — Cargo workspace: edition 2021, MSRV pinned at Phase 0 start

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #1)
- Owner: Director-Sync-Core
- Reviewers: CTO
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #1 (verbatim Recommendation): "*Single Cargo **workspace** at repo root; members added per phase (`core/` only in P0); **edition 2021**; MSRV pinned to the stable toolchain at P0 start.*" CEO ratified 2026-05-18 (`accept recommendation`).

Background: no code can land until the Cargo topology is fixed. DESIGN.md §14 proposes `core/ adapters/ apps/ server/`. Edition + MSRV pin constrains every dependency (crypto, sqlite, objc2/swift-bridge crates).

## Decision

1. **Single Cargo workspace at the repo root.** A top-level `Cargo.toml` declares `[workspace]` with `resolver = "2"`. Members are added per DESIGN.md phase, **not eagerly**:
   - Phase 0: `core/` only.
   - Phase 1+: `adapters/macos/` (Swift helper is its own Swift package; the Rust bridge crate is the Cargo member).
   - Phase 4+: `apps/agent/`, `apps/recall-ui/`.
   - Phase 5: `server/`.
   - Phase 8: `adapters/windows/`.
2. **Edition 2021.** Maximum ecosystem compatibility for the SQLCipher / objc2 / swift-bridge / sqlite-vec / Vision-FFI crate set. Edition is not where the value is; the trait seam is.
3. **MSRV pinned to the stable toolchain at the moment the first `Cargo.toml` lands.** The value goes in two places: (a) a `rust-version = "<X.Y.Z>"` field in the workspace `Cargo.toml`, and (b) a `rust-toolchain.toml` at the repo root with `channel = "<X.Y.Z>"` so every developer / CI runner uses the same toolchain. Exact version is a one-line follow-up at the first commit; the workspace-init PR pins it. MSRV moves only on a deliberate, documented bump.
4. **One lockfile.** `Cargo.lock` is checked in (this is a binary, not a library). All workspace members share dependency versions.

## Consequences

- Positive: one lockfile, one resolver. Every component upgrades together; no version drift between `core/` and the adapters. AGENT_PROTOCOL §5 protected-set review on `core/**` crypto deps is meaningful because dep versions are workspace-uniform.
- Positive: lazy workspace members keep Phase 0 small — only `core/` exists. Adding `adapters/macos/` in Phase 1 is a one-line workspace edit.
- Negative / tradeoffs: workspace-wide builds touch every crate when a shared dep updates. Acceptable cost for the dep-coherence guarantee.
- Forces: every PR touching `core/Cargo.toml` or the workspace `Cargo.toml` updates `Cargo.lock` and is reviewed for unintended transitive bumps. CRS Security-Signal analyst auto-reviews any new crate added to `core/**` crypto/sync/store dependencies.

## Alternatives considered

- **Edition 2024.** Rejected — newer language features, but some ecosystem and crate lag exists on the FFI and crypto side (objc2 family, swift-bridge, SQLCipher-bundled features). The Phase 0 win is shipping the seam, not the latest edition.
- **Multi-repo per component.** Rejected — destroys the "core written once" thesis (ADR-0002), forces dep-version drift, makes the CSO protected-set review boundary mushy.

## References

- DESIGN.md §14 (repo layout)
- docs/AGENT_QUESTIONS.md fork #1 (2026-05-18, ratified `accept recommendation`)
- docs/AGENT_PROTOCOL.md §5 (CSO protected-set on `core/**`)
- ADR-0002 (stack split), ADR-0006 (trait shape)
