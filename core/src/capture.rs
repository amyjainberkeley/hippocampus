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
/// `'frame` ties the surface borrow to the callback scope. The receiver MUST
/// finish using `surface` before this struct is dropped.
#[derive(Debug)]
pub struct StateTransition<'frame> {
    /// Borrowed handle to the frame pixels. See [`SurfaceHandle`] for the
    /// release-timing contract.
    pub surface: SurfaceHandle<'frame>,
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
/// Note the `'static` bound on the `StateTransition`'s lifetime parameter:
/// adapters do **not** literally send a borrowed `'frame` surface across the
/// channel. The skeleton omits the actual frame payload; the Phase-1 adapter
/// PR refines this signature to use an owned-but-still-opaque
/// `SurfaceLease` type that carries the OS pool retain across the channel
/// while the per-frame ack discipline of ADR-0007 enforces the deadline.
pub type StateTransitionSender = mpsc::Sender<StateTransition<'static>>;

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
        let (tx, _rx) = mpsc::channel::<StateTransition<'static>>(DEFAULT_CHANNEL_BOUND);
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
