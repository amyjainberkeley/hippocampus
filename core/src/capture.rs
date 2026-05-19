//! The cross-platform capture seam.
//!
//! This module defines [`CaptureSource`], the single Rust trait every per-OS
//! capture adapter implements. Nothing in this crate above this trait may
//! contain OS-specific code. The trait shape is locked by
//! `docs/decisions/0006-capturesource-trait-shape-async-push.md` (ratified
//! fork #2): async + push, opaque borrowed surface handle + dirty-rects,
//! bounded channel, drop-on-backpressure, runtime = tokio.
//!
//! Nothing here actually captures anything — this crate is a skeleton.
//! The macOS adapter lands in Phase 1 per `docs/DESIGN.md §15`.

use std::time::Instant;

use async_trait::async_trait;
use thiserror::Error;
use tokio::sync::mpsc;

/// Default bound for the `mpsc` channel handed to [`CaptureSource::start`].
///
/// Single-digit by design: this is the in-flight frame queue between the
/// adapter and the core, and the surface-handle release-timing contract
/// (see below) means deeper queues just delay the drop without value.
pub const DEFAULT_CHANNEL_BOUND: usize = 4;

// ---------------------------------------------------------------------------
// SurfaceHandle — opaque, borrowed, lifetime-bound
// ---------------------------------------------------------------------------

/// Opaque, borrowed reference to a platform frame surface.
///
/// **The single most important type in `mci-core`.** `SurfaceHandle` is the
/// vehicle by which a GPU-backed frame (macOS `IOSurface` /
/// Windows `Direct3D11CaptureFrame`) is carried from the adapter into the
/// core **without copying pixels across the FFI boundary**. The handle is
/// borrowed from the OS frame pool; the core copies-out or encodes from it
/// synchronously and then drops it. **Owned `Vec<u8>` of pixels never crosses
/// the FFI seam** (ADR-0006).
///
/// # SAFETY / TIMING CONTRACT
///
/// `ScreenCaptureKit` hands frames as `IOSurface` references held by a
/// fixed-size surface pool. The receiver MUST drop the `SurfaceHandle` (and
/// any borrow of its pixels) within `interval × (queueDepth − 1)`. If the
/// receiver retains a surface past this bound, the pool stalls silently and
/// the stream stops delivering frames — *with no error surfaced*. Concretely:
///
/// - default `queueDepth = 3` and a typical capture interval of e.g. 200 ms
///   ⇒ the receiver has ≤ ~400 ms to copy-out / encode / drop.
/// - in practice, treat any retention beyond a single capture interval as
///   a bug. Copy/encode synchronously inside the channel-receive path; do not
///   `.await` work that depends on the handle staying live.
///
/// `Windows.Graphics.Capture` has the analogous
/// `Direct3D11CaptureFramePool` constraint; the same rule applies.
///
/// The `'frame` lifetime expresses this: the handle cannot escape the
/// callback scope. ADR-0007 carries the same contract across the macOS
/// helper-process IPC boundary via a per-frame ack with a hard timeout.
#[derive(Debug)]
pub struct SurfaceHandle<'frame> {
    /// Opaque platform pointer / id. Concrete shape is adapter-private.
    /// `core/` MUST NOT interpret this field. New adapters add a variant
    /// in `Platform`; this `&'frame ()` placeholder keeps the public API
    /// OS-agnostic for the skeleton.
    _platform: Platform<'frame>,
    /// Logical width of the surface in pixels (before any scaling).
    pub width_px: u32,
    /// Logical height of the surface in pixels (before any scaling).
    pub height_px: u32,
}

impl<'frame> SurfaceHandle<'frame> {
    /// Construct a `SurfaceHandle`.
    ///
    /// Adapters call this from inside the OS frame callback. The `'frame`
    /// lifetime is normally tied to a stack-allocated borrow that does not
    /// outlive the callback — this is what mechanically enforces the
    /// release-timing contract above.
    #[must_use]
    pub const fn new(platform: Platform<'frame>, width_px: u32, height_px: u32) -> Self {
        Self {
            _platform: platform,
            width_px,
            height_px,
        }
    }
}

/// Adapter-internal platform discriminant.
///
/// Kept inside `core/` so the public `SurfaceHandle` API is OS-agnostic, but
/// the variants themselves carry OS-tagged opaque references. Adapters add
/// variants here; the variant payloads themselves remain opaque to the rest
/// of `core/` (per ADR-0003: no OS code above the trait seam).
#[derive(Debug)]
#[non_exhaustive]
pub enum Platform<'frame> {
    /// A test / mock surface backed by nothing. Used by `mci-core` unit tests
    /// and by adapter tests that don't want to spin up the OS pipeline.
    Mock(&'frame ()),
}

// ---------------------------------------------------------------------------
// SurfaceLease — opaque, OWNED, RAII-released
// ---------------------------------------------------------------------------

/// Opaque, **owned** carrier for an OS frame-pool retain that must
/// cross a channel — and, on macOS, a *process* boundary — without the
/// borrowed `'frame` lifetime of [`SurfaceHandle`].
///
/// # Why this exists (ADR-0006 + ADR-0007 + ADR-0014)
///
/// [`SurfaceHandle`]`<'frame>` mechanically enforces the pool-release
/// deadline *inside the OS callback scope* — but the seam is async +
/// push (ADR-0006): the adapter sends a [`StateTransition`] over a
/// bounded channel, and on macOS the producer is a **separate signed
/// helper process** (ADR-0007) that passed the surface fd to the core
/// out-of-band via `SCM_RIGHTS`. A borrowed `'frame` cannot survive
/// either hop. `SurfaceLease` is the owned-but-still-opaque type the
/// `core/` skeleton's `StateTransitionSender` always *intended* (see
/// the historical note this replaces): it carries the retain and
/// **returns the surface to its OS pool exactly once, on `Drop`**, so
/// the §5.1 / ADR-0007 timing contract is preserved by RAII rather
/// than by a lifetime.
///
/// OS-agnostic by construction (ADR-0003): the actual pool-return is a
/// boxed `FnOnce` the *adapter* supplies; `core/` never inspects or
/// constructs the OS payload. The per-frame ack discipline of ADR-0007
/// still bounds *when* the core drops this lease; `Drop` guarantees
/// the release *happens* on every path (deliver / suppress / drop /
/// error / panic-unwind), which is the ADR-0013 Amendment 1 §3(d)
/// "no `IOSurface` pool-stall on any path" invariant expressed in the
/// type system.
pub struct SurfaceLease {
    width_px: u32,
    height_px: u32,
    /// OS-agnostic pool-return hook, run once. `None` after an explicit
    /// [`release`](Self::release) or for a [`mock`](Self::mock) lease.
    /// `core/` MUST NOT interpret what this closure does (ADR-0003).
    releaser: Option<Box<dyn FnOnce() + Send>>,
}

impl SurfaceLease {
    /// Construct an owned lease. The adapter passes a `releaser` that
    /// returns the underlying OS surface to its pool (e.g. drops the
    /// macOS `IOSurface` retain / closes the `SCM_RIGHTS` fd). It is
    /// invoked exactly once — on explicit [`release`](Self::release)
    /// or otherwise on `Drop`.
    #[must_use]
    pub fn new(width_px: u32, height_px: u32, releaser: Box<dyn FnOnce() + Send>) -> Self {
        Self {
            width_px,
            height_px,
            releaser: Some(releaser),
        }
    }

    /// A lease backed by nothing — for `mci-core` unit tests and
    /// adapter tests that don't spin up the OS pipeline. Dropping it
    /// is a no-op (no pool to stall).
    #[must_use]
    pub fn mock(width_px: u32, height_px: u32) -> Self {
        Self {
            width_px,
            height_px,
            releaser: None,
        }
    }

    /// Logical width of the surface in pixels (before any scaling).
    #[must_use]
    pub const fn width_px(&self) -> u32 {
        self.width_px
    }

    /// Logical height of the surface in pixels (before any scaling).
    #[must_use]
    pub const fn height_px(&self) -> u32 {
        self.height_px
    }

    /// Return the surface to its OS pool *now*, synchronously, instead
    /// of waiting for `Drop`. Idempotent: a subsequent `Drop` is a
    /// no-op. Prefer this on the hot path so the pool is freed as
    /// early as possible (the ADR-0006 / ADR-0007 timing contract).
    pub fn release(mut self) {
        if let Some(r) = self.releaser.take() {
            r();
        }
        // `self` drops here; releaser is already None ⇒ Drop no-ops.
    }
}

impl Drop for SurfaceLease {
    fn drop(&mut self) {
        // Exactly-once: `release()` already took it ⇒ None ⇒ no-op.
        // This is the load-bearing guarantee — every exit path
        // (deliver / suppress / backpressure-drop / error / unwind)
        // returns the surface to the pool, so the pool cannot stall.
        if let Some(r) = self.releaser.take() {
            r();
        }
    }
}

impl std::fmt::Debug for SurfaceLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never expose the releaser. Opaque on purpose (ADR-0003).
        f.debug_struct("SurfaceLease")
            .field("width_px", &self.width_px)
            .field("height_px", &self.height_px)
            .field("released", &self.releaser.is_none())
            .finish()
    }
}

// ---------------------------------------------------------------------------
// DirtyRect / FrameStatus / WorkflowContext / PermissionsStatus / StateTransition
// ---------------------------------------------------------------------------

/// A rectangle of pixels that changed since the prior delivered frame.
///
/// Adapters compute dirty rects from the OS (`SCStreamFrameInfo.dirtyRects`
/// on macOS; equivalent metadata on Windows). The pipeline uses these to
/// scope OCR + dedupe to changed regions (DESIGN.md §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirtyRect {
    /// Top-left x in pixels.
    pub x: u32,
    /// Top-left y in pixels.
    pub y: u32,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
}

/// The status the OS frame callback reported for this delivery.
///
/// Mirrors macOS `SCFrameStatus` shape but is OS-agnostic. Adapters map their
/// platform status to one of these.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameStatus {
    /// New content was delivered (the common case).
    Complete,
    /// The OS reported the screen as idle. **Not authoritative on its own** —
    /// per the CRS scan, `SCFrameStatus.idle` is not trustworthy as the only
    /// change signal; combine with last-input-idle + dirty-rect + dHash.
    Idle,
    /// The OS suspended the stream (low-power, thermal, user pause, etc).
    Suspended,
    /// The OS dropped this frame (queue overflow). Adapter records the count.
    Stopped,
}

/// One state-transition event from the capture spine.
///
/// The frame is carried as an **owned** [`SurfaceLease`], not a
/// borrowed [`SurfaceHandle`]`<'frame>`: this struct is sent over the
/// async-push channel (ADR-0006) and, on macOS, materializes from a
/// separate helper process (ADR-0007), neither of which a `'frame`
/// borrow can survive. The lease returns the surface to its OS pool on
/// `Drop`, so the §5.1 / ADR-0007 release-timing contract is preserved
/// by RAII (ADR-0014). The receiver should still drop the
/// `StateTransition` (or call [`SurfaceLease::release`]) promptly —
/// "owned" relaxes the *compiler-enforced* deadline, not the
/// performance contract.
#[derive(Debug)]
pub struct StateTransition {
    /// Owned lease on the frame pixels. See [`SurfaceLease`] for the
    /// release-timing contract.
    pub surface: SurfaceLease,
    /// Pixels that changed since the prior delivered frame. Adapter-side
    /// allocation is fine; this `Vec` is short-lived and small.
    pub dirty_rects: Vec<DirtyRect>,
    /// Monotonic timestamp the adapter recorded when the OS delivered the
    /// frame. Used by recency boosting in retrieval (ADR-0010).
    pub ts: Instant,
    /// The OS-reported status for this delivery.
    pub status: FrameStatus,
}

/// Snapshot of the user's structured workflow context (frontmost app,
/// focused window, active browser URL, page text).
///
/// Populated by the adapter's context probe (`NSWorkspace` + Accessibility +
/// `AppleScript` on macOS; UIA on Windows). See DESIGN.md §6.
#[derive(Debug, Clone, Default)]
pub struct WorkflowContext {
    /// Frontmost app bundle identifier (e.g. `"com.apple.Safari"`).
    pub app_bundle: Option<String>,
    /// Focused window title.
    pub window_title: Option<String>,
    /// Active browser tab URL, if any. Detected via `AppleScript` / native
    /// browser-extension messaging.
    pub url: Option<String>,
    /// Extracted page text — extension-provided when available, OCR fallback
    /// otherwise. None means "not probed yet."
    pub page_text: Option<String>,
}

/// Status of the OS-level permissions the adapter needs to operate.
///
/// Adapters report this synchronously without blocking on OS prompts so the
/// menu-bar UI can drive the onboarding flow (DESIGN.md §3, R1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PermissionsStatus {
    /// Screen Recording / capture permission.
    pub screen_recording: PermissionState,
    /// Accessibility permission (focused-window / AX queries).
    pub accessibility: PermissionState,
    /// Automation permission (`AppleScript` browser-URL probes; macOS only).
    /// Always [`PermissionState::NotApplicable`] on non-macOS.
    pub automation: PermissionState,
}

/// Tri-state for a single OS permission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionState {
    /// Granted by the user.
    Granted,
    /// User has not yet been prompted, or actively denied.
    Denied,
    /// Not applicable on this platform (e.g. Automation on Windows).
    NotApplicable,
}

// ---------------------------------------------------------------------------
// CaptureError
// ---------------------------------------------------------------------------

/// Errors a [`CaptureSource`] may return.
///
/// Adapter-specific OS errors are collapsed into these variants. Detailed
/// platform info goes into `tracing` events, not the error type.
#[derive(Debug, Error)]
pub enum CaptureError {
    /// One of the OS-level permissions the adapter needs is missing.
    #[error("permission missing: {0:?}")]
    PermissionMissing(PermissionsStatus),
    /// The adapter could not start the underlying OS capture session.
    #[error("failed to start capture: {0}")]
    StartFailed(String),
    /// The adapter is in a state where `stop()` is not legal.
    #[error("stop called while not running")]
    NotRunning,
    /// Backpressure: the bounded channel is full. Adapters should drop the
    /// frame and emit a counter rather than returning this — but the variant
    /// exists for explicit signalling in tests.
    #[error("backpressure drop")]
    Backpressure,
}

// ---------------------------------------------------------------------------
// The trait itself
// ---------------------------------------------------------------------------

/// Convenience alias for the channel the adapter pushes [`StateTransition`]s
/// over.
///
/// [`StateTransition`] now carries an **owned** [`SurfaceLease`] (ADR-0014):
/// there is no lifetime parameter to bound, because a borrowed `'frame`
/// surface cannot cross the async-push channel (ADR-0006) nor the macOS
/// helper-process `SCM_RIGHTS` boundary (ADR-0007). The lease's `Drop`
/// returns the surface to its OS pool; the ADR-0007 per-frame ack still
/// bounds *when* the core releases it.
pub type StateTransitionSender = mpsc::Sender<StateTransition>;

/// The cross-platform capture seam.
///
/// Every per-OS adapter implements this trait. Nothing above this trait in
/// `mci-core` may contain OS-specific code (ADR-0003).
///
/// The trait is async + push (ADR-0006): the adapter owns the OS callback
/// and pushes [`StateTransition`]s into a bounded channel the core supplies
/// at [`start`](Self::start) time. Backpressure is "drop newest oldest, never
/// block" — dedupe at the next pipeline stage makes a dropped near-duplicate
/// harmless.
#[async_trait]
pub trait CaptureSource: Send + 'static {
    /// Start the underlying OS capture session.
    ///
    /// `tx` is a bounded `mpsc::Sender` the core owns; the adapter pushes
    /// [`StateTransition`]s into it. Channel depth is small (see
    /// [`DEFAULT_CHANNEL_BOUND`]) by design — see the [`SurfaceHandle`]
    /// release-timing contract.
    async fn start(&mut self, tx: StateTransitionSender) -> Result<(), CaptureError>;

    /// Stop the underlying OS capture session. Idempotent only insofar as
    /// the OS API is — most APIs require a matched start/stop pair.
    async fn stop(&mut self) -> Result<(), CaptureError>;

    /// Report the current OS permission state. Non-blocking; never prompts.
    fn permissions_status(&self) -> PermissionsStatus;

    /// Probe the user's structured workflow context (frontmost app, focused
    /// window, active browser URL + page text). Cheap; the adapter caches.
    fn context_probe(&self) -> WorkflowContext;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Mock adapter used to exercise the trait's shape in tests. Confirms
    /// that the trait is dyn-compatible (`dyn CaptureSource` works) and that
    /// a minimal implementor compiles.
    struct MockSource {
        running: bool,
    }

    #[async_trait]
    impl CaptureSource for MockSource {
        async fn start(&mut self, _tx: StateTransitionSender) -> Result<(), CaptureError> {
            self.running = true;
            Ok(())
        }

        async fn stop(&mut self) -> Result<(), CaptureError> {
            if !self.running {
                return Err(CaptureError::NotRunning);
            }
            self.running = false;
            Ok(())
        }

        fn permissions_status(&self) -> PermissionsStatus {
            PermissionsStatus {
                screen_recording: PermissionState::Granted,
                accessibility: PermissionState::Granted,
                automation: PermissionState::NotApplicable,
            }
        }

        fn context_probe(&self) -> WorkflowContext {
            WorkflowContext::default()
        }
    }

    #[tokio::test]
    async fn mock_source_start_stop_round_trip() {
        let mut src = MockSource { running: false };
        let (tx, _rx) = mpsc::channel::<StateTransition>(DEFAULT_CHANNEL_BOUND);
        src.start(tx).await.expect("start");
        assert!(src.running);
        src.stop().await.expect("stop");
        assert!(!src.running);
    }

    #[tokio::test]
    async fn mock_source_stop_when_not_running_is_error() {
        let mut src = MockSource { running: false };
        let err = src.stop().await.unwrap_err();
        assert!(matches!(err, CaptureError::NotRunning));
    }

    #[test]
    fn trait_is_dyn_compatible() {
        // Pure compile-time check: `dyn CaptureSource` must be a valid type.
        // If the trait gains a generic method, this line fails to compile —
        // a clear signal that the seam shape changed (ADR-0006 amendment
        // required before merging).
        fn _accepts_dyn(_b: Box<dyn CaptureSource>) {}
    }

    #[test]
    fn surface_lease_releases_exactly_once_on_drop() {
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        {
            let lease = SurfaceLease::new(1920, 1080, Box::new(move || {
                c.fetch_add(1, Ordering::SeqCst);
            }));
            assert_eq!(lease.width_px(), 1920);
            assert_eq!(lease.height_px(), 1080);
            assert_eq!(calls.load(Ordering::SeqCst), 0, "not released until drop");
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "Drop returns the surface to the pool exactly once"
        );
    }

    #[test]
    fn surface_lease_explicit_release_then_drop_is_once() {
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let lease = SurfaceLease::new(640, 480, Box::new(move || {
            c.fetch_add(1, Ordering::SeqCst);
        }));
        lease.release(); // consumes; releaser runs here
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "explicit release + implicit drop must total exactly one pool-return"
        );
    }

    #[test]
    fn surface_lease_mock_drop_is_noop() {
        // A mock lease has no pool to stall; dropping it must not panic
        // and obviously runs no releaser.
        let lease = SurfaceLease::mock(100, 200);
        assert_eq!(lease.width_px(), 100);
        assert_eq!(lease.height_px(), 200);
        drop(lease);
    }

    #[test]
    fn surface_lease_is_send() {
        // The lease MUST be Send — it crosses the async-push channel
        // (ADR-0006) and is moved between tokio tasks. If someone makes
        // the releaser non-Send this stops compiling.
        fn assert_send<T: Send>() {}
        assert_send::<SurfaceLease>();
        assert_send::<StateTransition>();
    }

    #[tokio::test]
    async fn state_transition_carries_owned_lease_over_channel() {
        // The whole point of the refactor: a StateTransition with an
        // owned SurfaceLease survives the bounded channel with no
        // lifetime parameter, and the lease releases when the receiver
        // drops it.
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let released = Arc::new(AtomicUsize::new(0));
        let r = Arc::clone(&released);
        let (tx, mut rx) = mpsc::channel::<StateTransition>(DEFAULT_CHANNEL_BOUND);
        tx.send(StateTransition {
            surface: SurfaceLease::new(800, 600, Box::new(move || {
                r.fetch_add(1, Ordering::SeqCst);
            })),
            dirty_rects: vec![DirtyRect {
                x: 0,
                y: 0,
                width: 800,
                height: 600,
            }],
            ts: Instant::now(),
            status: FrameStatus::Complete,
        })
        .await
        .expect("send");
        let evt = rx.recv().await.expect("recv");
        assert_eq!(evt.surface.width_px(), 800);
        assert_eq!(released.load(Ordering::SeqCst), 0, "still held by receiver");
        drop(evt);
        assert_eq!(
            released.load(Ordering::SeqCst),
            1,
            "receiver drop returns the surface to the pool"
        );
    }

    #[test]
    fn surface_handle_is_lifetime_bound() {
        // Compile-time check: the lifetime parameter on SurfaceHandle is
        // load-bearing for the release-timing contract. If someone removes
        // the `'frame` parameter, this test stops referencing it and the
        // intent rots — but the test name documents why the parameter must
        // stay.
        let nothing = ();
        let h = SurfaceHandle::new(Platform::Mock(&nothing), 1920, 1080);
        assert_eq!(h.width_px, 1920);
        assert_eq!(h.height_px, 1080);
    }
}
