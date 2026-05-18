# ADR-0003 — Cross-platform seam: the `CaptureSource` trait; macOS-first; no OS code above the trait

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2)
- Owner: CTO
- Reviewers: Director-Sync-Core; Director-Recording; Director-Context
- Phase: 0

## Context

ADR-0002 split MCI into a portable Rust core and per-OS native adapters. This ADR pins the seam shape (a Rust trait), the launch order (macOS first), and the discipline above the seam (no OS code).

DESIGN.md §11 specifies the seam concretely: "*`CaptureSource` trait (Rust): `start/stop`, `next_event() -> StateTransition { frame_surface, dirty_rects, timestamp }`, `context_probe() -> WorkflowContext { app, window, url, page_text }`, `permissions_status()`. Everything above this line (pipeline, dedupe, encode orchestration, OCR orchestration, brain, crypto, sync) is written once in Rust.*"

AGENT_PROTOCOL §4 lists this as an invariant: "*Cross-platform seam: nothing above the `CaptureSource` Rust trait may contain OS-specific code.*"

## Decision

1. **The cross-platform seam is the `CaptureSource` Rust trait**, owned by Director-Sync-Core, defined in `core/`. Its concrete shape (async + push, opaque borrowed surface handle + dirty-rects, bounded channel, tokio, drop-on-backpressure) is locked in ADR-0006.
2. **macOS-first.** Phase 0 lands `core/` skeleton + the trait. Phase 1 lands the macOS adapter (`adapters/macos/`) implementing the trait against ScreenCaptureKit / VideoToolbox / Vision / NSWorkspace / AX / AppleScript, via the mechanism in ADR-0007. The Windows adapter (`adapters/windows/`) is DESIGN.md Phase 8 and reuses the core unchanged.
3. **No OS-specific code above the trait.** No `#[cfg(target_os = …)]` blocks, no `objc2::*` imports, no `windows::*` imports, and no Swift type bindings in `core/**` except the trait wiring itself. Reviewers reject violations during PR review. This is the cross-platform seam invariant from AGENT_PROTOCOL §4.

## Consequences

- Positive: the brain, crypto, sync, retrieval, and recall API are written once and tested once. Adding Windows in Phase 8 is "implement one trait + wire platform encode/OCR" — DESIGN.md §11 makes this an explicit design forcing function.
- Positive: the trait is the single point where cross-platform discipline is enforceable in code review. PR diffs touching `core/` are mechanically grep-able for forbidden imports.
- Negative / tradeoffs: the trait must accommodate two genuinely different OS frame-delivery models (ScreenCaptureKit's push-with-surface-pool vs Windows.Graphics.Capture's frame-pool acquire/release). ADR-0006 absorbs this with an "opaque borrowed surface handle" abstraction; if it leaks (e.g., raw `IOSurface*` or `ID3D11Texture2D*` exposed above the trait) the seam is broken. The release-timing contract goes in the trait's doc comment, not just in narrative docs.
- Forces: `core/` may not depend on `objc2`, `swift-bridge`, `windows`, or any platform-specific crate. Platform crates live exclusively under `adapters/<os>/`.

## Alternatives considered

- **No trait — direct platform builds, separate crates per OS.** Rejected — same failure mode as the alternative in ADR-0002 (brain written twice).
- **Trait shape decided per-platform at Phase 1 time.** Rejected — Director-Sync-Core ratified fork #2 in cycle 1; trait shape is in ADR-0006 now because the pipeline above it cannot be designed without it, and ScreenCaptureKit's `interval × (queueDepth − 1)` surface-release timing is a binding seam constraint (DESIGN.md §5.1, R8).

## References

- DESIGN.md §4, §11, §13
- docs/AGENT_PROTOCOL.md §4 (cross-platform seam invariant)
- ADR-0002 (stack split), ADR-0006 (trait shape), ADR-0007 (macOS adapter mechanism)
