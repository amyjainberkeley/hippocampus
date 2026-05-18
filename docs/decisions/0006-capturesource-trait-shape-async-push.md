# ADR-0006 — `CaptureSource` trait shape: async + push, opaque borrowed surface handle, tokio, drop-on-backpressure

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #2)
- Owner: Director-Sync-Core
- Reviewers: CTO; Director-Recording
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #2 (verbatim): "*THE cross-platform seam; locking it wrong forces a core rewrite. ScreenCaptureKit hands GPU-backed `IOSurface` that must be released to the pool within `interval × (queueDepth − 1)` or the stream silently stalls (DESIGN.md §5.1, R8). The trait dictates the runtime and the whole pipeline.*"

Recommendation (verbatim): "*A. Matches the OS delivery model and the §4 footprint/backpressure invariants; the explicit 'drop the surface handle fast' contract goes in the trait docs. This decision also locks the async runtime = tokio.*"

CEO ratified 2026-05-18.

## Decision

The `CaptureSource` trait in `core/` has this shape:

1. **Async + push.** The adapter owns the OS callback (ScreenCaptureKit's `SCStreamOutput` on macOS; the WGC frame-pool `FrameArrived` on Windows). On each transition it pushes a `StateTransition` value over a **bounded `tokio::sync::mpsc` channel** the core supplied at `start()` time.
2. **Bounded channel.** Channel depth is small (single-digit) and configured at `start()`. When full, the adapter **drops the oldest queued frame** (or its own newest, per platform — the API guarantees "drop, never block"). Dedupe makes a dropped near-duplicate harmless (DESIGN.md §5.2, R8).
3. **Opaque borrowed surface handle + dirty-rects, never owned pixels across FFI.** A `StateTransition` carries a platform-tagged `SurfaceHandle` (opaque to `core/`, lifetime borrowed from the OS frame pool), a `Vec<DirtyRect>`, a `Timestamp`, and a `FrameStatus`. The core must **copy-out or encode** the bytes it needs, then **drop the `SurfaceHandle` immediately**. Owned `Vec<u8>` of pixels never crosses the FFI seam — only references / OS-managed surfaces do.
4. **Surface-handle release-timing contract — verbatim, in the trait's doc comment** (not just in narrative docs):

   ```text
   /// SAFETY / TIMING CONTRACT
   /// ScreenCaptureKit hands frames as `IOSurface` references held by a fixed-size
   /// surface pool. The receiver MUST drop the `SurfaceHandle` (and any borrow of
   /// its pixels) within `interval × (queueDepth − 1)`. If the receiver retains a
   /// surface past this bound, the pool stalls silently and the stream stops
   /// delivering frames — *with no error surfaced*. Concretely:
   ///   - default `queueDepth = 3` and a typical capture interval of e.g. 200 ms
   ///     => the receiver has ≤ ~400 ms to copy-out / encode / drop.
   ///   - in practice, treat any retention beyond a single capture interval as
   ///     a bug. Copy/encode synchronously inside the channel-receive path; do not
   ///     `await` work that depends on the handle staying live.
   /// Windows.Graphics.Capture has the analogous `Direct3D11CaptureFramePool`
   /// constraint; the same rule applies.
   ```

5. **Backpressure = drop, never block.** The core's consumer is responsible for staying within the timing bound. If it cannot, the bounded channel drops; dedupe at the next layer treats the loss as harmless. Blocking is never allowed in the adapter path.
6. **Async runtime = tokio.** This decision is locked by the trait shape: bounded `tokio::sync::mpsc`, async fn signatures throughout `core/`, `#[tokio::main]` in the agent binary. No `async-std`, no `smol`.
7. **Trait surface (sketch — final shape lands with the Phase 0 implementation PR):**

   ```rust
   #[async_trait]
   pub trait CaptureSource: Send + 'static {
       async fn start(
           &mut self,
           tx: tokio::sync::mpsc::Sender<StateTransition<'_>>,
       ) -> Result<(), CaptureError>;

       async fn stop(&mut self) -> Result<(), CaptureError>;

       fn permissions_status(&self) -> PermissionsStatus;

       fn context_probe(&self) -> WorkflowContext;
   }
   ```

   `StateTransition` carries `surface: SurfaceHandle<'_>`, `dirty_rects: &[DirtyRect]`, `ts: Instant`, `status: FrameStatus`. Final names + ergonomic refinements happen in the implementation PR per ADR-0005's edition-2021 constraint; the *shape contract* is locked here.

## Consequences

- Positive: the trait shape matches the OS delivery model on both platforms (ScreenCaptureKit, WGC). The footprint SLO (AGENT_PROTOCOL §4) is reachable because the hot path is GPU-backed surface refs not pixel copies, and backpressure drops near-duplicates rather than queueing memory.
- Positive: the timing contract is in the code, in the doc comment, where every future implementer (Windows adapter, mocks, tests) sees it before writing impl. The bug is named and impossible to "forget."
- Negative / tradeoffs: locking tokio is a real choice that constrains the entire async ecosystem of `core/`. Acceptable — tokio is the mainstream runtime for FFI-heavy async, and the alternatives don't meaningfully change the design.
- Forces: every implementor of `CaptureSource` writes a test (or a Miri-checked harness, where applicable) that asserts the surface is dropped synchronously inside the receive path. CTO arbitrates any proposed deviation.

## Alternatives considered

- **Sync + pull (`fn next_event() -> Result<StateTransition>` that blocks).** Rejected — fights the OS callback model on both platforms and invites pool stalls. ADR-0006 explicitly named this in fork #2 as the easy-but-wrong path.
- **Async pull (`Stream`).** Rejected — middle ground; still has to solve the surface-lifetime contract, with extra `Stream` adapter complexity for no gain.
- **Owned pixel `Vec<u8>` over FFI.** Rejected — defeats the whole zero-copy thesis; doubles memory + CPU on the hottest path.

## References

- DESIGN.md §4 (architecture), §5 (capture pipeline, especially §5.1 surface-release timing and R8 in §16)
- docs/AGENT_QUESTIONS.md fork #2 (2026-05-18, ratified `accept recommendation`)
- docs/AGENT_PROTOCOL.md §4 (footprint SLO + cross-platform seam invariant)
- ADR-0002 (stack split), ADR-0003 (seam discipline), ADR-0007 (macOS adapter mechanism — IPC must preserve this timing across the process boundary)
