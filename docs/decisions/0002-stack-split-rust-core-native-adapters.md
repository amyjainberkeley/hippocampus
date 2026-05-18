# ADR-0002 — Stack split: portable Rust core + native capture adapters

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2)
- Owner: CTO
- Reviewers: Director-Sync-Core; Director-Recording; Director-Brain; Director-Context
- Phase: 0

## Context

MCI is cross-platform by design (DESIGN.md G5) but the capture/context layer is irreducibly OS-specific: ScreenCaptureKit + VideoToolbox + Vision + NSWorkspace/AX/AppleScript on macOS; Windows.Graphics.Capture + Media Foundation + Windows.Media.Ocr + UIA on Windows. Rewriting the brain (chunk → embed → index → retrieve → encrypt → sync) twice would (a) double the surface area for crypto bugs in a protected-set component (AGENT_PROTOCOL §5) and (b) make every retrieval-quality improvement a 2× cost.

DESIGN.md §4 and §11 already commit to a portable Rust core plus thin native adapters. This ADR pins that split as a non-negotiable architectural invariant.

## Decision

MCI is split into two layers:

1. **Portable core, written in Rust, written once.** Owns: the capture pipeline (smart-capture filter chain, dedupe, OCR orchestration, encode orchestration), context join, the entire brain (chunk, embed, index, retrieve, hybrid fusion), the encrypted SQLite store, encryption, the zero-knowledge sync protocol, and the local recall API. Lives in `core/`.
2. **Thin native capture/context adapters, per OS.** Implement the `CaptureSource` trait (ADR-0003, ADR-0006). On macOS this is a small **Swift helper** invoking ScreenCaptureKit/VideoToolbox/Vision + NSWorkspace/AX/AppleScript, bridged to the Rust core via the mechanism in ADR-0007. On Windows this is Rust talking to `windows-rs` bindings for Windows.Graphics.Capture / Media Foundation / Windows.Media.Ocr / UIA. Adapters live in `adapters/macos/` and `adapters/windows/` respectively (DESIGN.md §14).

Everything above the `CaptureSource` trait — every line of pipeline, brain, crypto, sync, retrieval, recall-API code — is written once in Rust.

## Consequences

- Positive: one brain, one crypto codebase, one sync protocol. The "core written once" thesis is the design's load-bearing premise; this ADR makes it enforceable.
- Positive: when Windows ships (DESIGN.md Phase 8), it is a new adapter, not a parallel product. No brain rework, no protocol rework.
- Negative / tradeoffs: the FFI seam between Rust core and the native adapter is non-trivial — surface-handle lifetime + zero-copy frame delivery + IPC framing must be designed carefully (ADR-0006 trait shape, ADR-0007 IPC mechanism). A poorly-designed seam can stall the ScreenCaptureKit pool (DESIGN.md §5.1, R8).
- Forces: nothing above the `CaptureSource` trait may contain OS-specific code (ADR-0003 + AGENT_PROTOCOL §4 cross-platform-seam invariant). Reviewers must reject any `cfg(target_os = …)` block found in `core/**` outside of platform-trait wiring.

## Alternatives considered

- **Pure-native per platform (Swift on macOS, C#/.NET or C++ on Windows).** Rejected — the brain (embedding pipeline, hybrid retrieval, encrypted-delta sync) gets written twice and stays divergent forever. The retrieval-quality work (ADR-0010) and crypto work (ADR-0012) are too expensive to duplicate.
- **Electron / cross-platform managed runtime.** Rejected — the footprint SLO (≤~1–2% one core, ≤~250 MB RAM on an all-day session; AGENT_PROTOCOL §4) is unreachable from a managed/JS runtime when the capture+encode+OCR path is hot. DESIGN.md §10 calls this out directly.

## References

- DESIGN.md §4, §10, §11, §13, §14
- docs/AGENT_PROTOCOL.md §4 (cross-platform seam invariant), §5 (protected-set on `core/**`)
- ADR-0003 (trait seam), ADR-0006 (trait shape), ADR-0007 (macOS adapter mechanism)
