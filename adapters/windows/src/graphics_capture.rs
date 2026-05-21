//! Windows.Graphics.Capture frame acquisition.
//!
//! Windows equivalent of macOS `SCStreamCaptureSession`. Uses
//! `GraphicsCaptureItem` + `Direct3D11CaptureFramePool` to receive
//! GPU-backed frames with dirty-rect metadata.
//!
//! # Pool-release contract
//!
//! `Direct3D11CaptureFramePool` has the same fixed-size pool semantics as
//! macOS `SCStream`: the receiver MUST release each `Direct3D11CaptureFrame`
//! promptly or the pool stalls and stops delivering. The `SurfaceLease`
//! RAII pattern (ADR-0006 / ADR-0014) handles this identically — the
//! lease's `Drop` impl releases the frame back to the pool.
//!
//! # DRM exclusion
//!
//! `Windows.Graphics.Capture` excludes DRM-protected surfaces by default
//! (equivalent to macOS FairPlay blacked-region behavior). No additional
//! probe needed for the §2 invariant — the API simply does not deliver
//! those pixels.

use mci_core::capture::{DirtyRect, SurfaceLease};

/// A captured frame from `Windows.Graphics.Capture`.
///
/// Wraps the `Direct3D11CaptureFrame` surface read + dirty-rect extraction.
pub struct WgcFrame {
    pub lease: SurfaceLease,
    pub dirty_rects: Vec<DirtyRect>,
}

/// Create a `GraphicsCaptureSession` for the entire desktop.
///
/// Phase 8 stub — will wire `GraphicsCaptureItem::CreateFromMonitor` +
/// `Direct3D11CaptureFramePool` + frame-arrived callback.
pub fn create_capture_session() -> ! {
    unimplemented!("Phase 8: GraphicsCaptureSession + Direct3D11CaptureFramePool creation")
}

/// Read pixels from a `Direct3D11CaptureFrame` and wrap in a `SurfaceLease`.
///
/// The lease's `Drop` releases the frame back to the pool (§7 RAII invariant).
pub fn frame_to_lease(_width: u32, _height: u32) -> WgcFrame {
    unimplemented!("Phase 8: Direct3D11CaptureFrame → SurfaceLease conversion")
}

/// Extract dirty rects from a `Direct3D11CaptureFrame`.
///
/// Maps `ContentSize` changes to `DirtyRect` structs for the dedupe pipeline.
pub fn extract_dirty_rects() -> Vec<DirtyRect> {
    unimplemented!("Phase 8: dirty-rect extraction from Direct3D11CaptureFrame")
}
