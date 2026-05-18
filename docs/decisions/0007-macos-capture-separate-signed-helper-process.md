# ADR-0007 — macOS capture mechanism: separate signed Swift helper process, IPC to the Rust core

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #3)
- Owner: Director-Sync-Core
- Reviewers: CTO; CSO (process model, entitlements, notarization touch the protected set)
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #3 (verbatim): "*Research: no clean Rust bindings to ScreenCaptureKit/VideoToolbox/Vision. Phase 1 needs the capture spine; the language boundary is decided in Phase 0 because the IPC/marshalling protocol shapes the trait impl.*"

Recommendation (verbatim): "*A. Crash isolation is worth a lot for an always-on daemon; clean seam; matches DESIGN.md §11. The surface-handle-over-IPC timing constraint must be designed into the protocol now (CTO arbitrates the seam).*"

CEO ratified 2026-05-18.

## Decision

1. **The macOS capture adapter is a separate signed Swift helper process**, launched and supervised by the Rust core (the menu-bar agent in `apps/agent/`). Lives in `adapters/macos/` as a Swift package; produces a notarized + signed Mach-O binary co-bundled with the agent.
2. **The Swift helper owns:** the `SCStream` lifecycle, the `SCStreamOutput` callback, VideoToolbox encode (when the encode path is in-helper), Vision OCR (when OCR is in-helper, deferred decision — Phase 1 may run OCR in the core via FFI to Vision results passed as text), and the AX / NSWorkspace / AppleScript probes that produce `WorkflowContext`.
3. **The Rust core owns:** everything in ADR-0002's "portable core" list. The core consumes the Swift helper's output through the IPC mechanism below as its `CaptureSource` implementation.
4. **IPC mechanism: AF_UNIX (unix-domain socket) carrying a length-prefixed binary frame protocol**, with **`SCM_RIGHTS` file-descriptor passing** for surface-handle equivalents. XPC is a fallback if a future requirement forces `launchd`-mediated service activation; default is AF_UNIX because we own both ends of the pipe and want the simplest robust framing. (Final wire-format decision lands with the Phase 1 IPC PR; this ADR locks the *mechanism class*.)
5. **Surface-handle-over-IPC timing constraint — binding design input to the protocol design (Phase 1):**
   - `IOSurface` references can be passed across processes via `IOSurfaceID` lookup + a port-rights / fd transfer; the receiver gets a new `IOSurfaceRef` bound to the same underlying surface. **The pool-release deadline from ADR-0006 (`interval × (queueDepth − 1)`) applies end-to-end across the process boundary** — the core must release its borrow before the deadline, not just the helper. The IPC protocol therefore commits to:
     - **Per-frame ack with a hard timeout.** The Rust core sends a small fixed-size ack after dropping its borrow. The Swift helper drops its own retain when the ack arrives or when the timeout expires (the timeout is < the pool deadline minus expected IPC RTT).
     - **No batching of surface-handed frames across the IPC.** One frame in flight at a time over the surface-channel; events without surfaces (context probes) can pipeline freely on a separate channel.
     - **Backpressure across IPC = drop**, identical to the in-process trait contract (ADR-0006). The Swift helper drops the frame and emits a counter rather than blocking.
   - The Phase 1 PR that lands the protocol must include a test that injects a stalled core consumer and confirms the helper drops within the deadline + emits the drop-counter — not just that the stream "still works."
6. **Process supervision.** The Rust core launches the helper as a child process via `posix_spawn` with explicit fd setup. Crash-relaunch with exponential backoff. Helper exit status is logged but non-fatal to the agent (a brief recording gap is acceptable; user-visible state goes to **Paused** while the helper is down).
7. **Entitlements and signing.** The helper carries the Screen Recording / Accessibility entitlements separately from any future UI process; the menu-bar agent in `apps/agent/` carries the UI permissions. Both are signed with the same Developer ID and notarized as a co-bundle. CSO reviews the entitlement set in the Phase 1 PR (AGENT_PROTOCOL §5: entitlements are protected-set).

## Consequences

- Positive: **crash isolation.** A Vision OCR bug, a VideoToolbox quirk, or a malformed `SCStreamConfiguration` crashes only the helper; the menu-bar agent stays up, the brain stays accessible, the user sees a brief pause. For an always-on daemon, this matters.
- Positive: **clean language boundary.** No Swift+Rust+ARC in one address space. objc2 / swift-bridge stay out of `core/`. Only the IPC framing code knows the helper exists.
- Positive: **entitlements are isolated.** The helper has Screen Recording; the recall UI process does not. If the recall UI is exploited, it cannot directly capture the screen.
- Negative / tradeoffs: **IPC adds latency and a serialization step.** The surface-handle timing contract (ADR-0006) must survive crossing the process boundary, which forces the per-frame ack + bounded-in-flight protocol above. This is the single highest-risk thing about Option A; the Phase 1 protocol PR is where it's earned.
- Negative / tradeoffs: **two signed binaries**, two entitlements files, two notarization steps. Build/release complexity is real; CTO + CSO own that lane.
- Forces: CSO must sign off on the entitlement set, the IPC framing (which deserialization library; we will not parse untrusted bytes with a non-fuzzed parser), and any change to the helper's privilege surface. AGENT_PROTOCOL §5 applies.

## Alternatives considered

- **In-process objc2 / swift-bridge FFI.** Rejected — zero IPC, but Swift+Rust+ARC in one address space is harder and riskier for an all-day daemon (a Vision bug brings down the agent). The trade is "save 50–200 µs/frame of IPC overhead" for "lose crash isolation"; not worth it.
- **Defer the language-boundary decision to Phase 1.** Rejected — the trait implementation cannot be designed without knowing whether the seam is in-process or cross-process, especially given the surface-handle release-timing constraint.

## References

- DESIGN.md §5 (capture pipeline), §10 (process model), §11 (cross-platform), §14 (repo layout)
- docs/AGENT_QUESTIONS.md fork #3 (2026-05-18, ratified `accept recommendation`)
- docs/AGENT_PROTOCOL.md §5 (CSO protected-set: entitlements, notarization, signing)
- ADR-0002 (stack split), ADR-0003 (seam discipline), ADR-0006 (trait shape + in-process timing contract that this ADR carries across IPC)
