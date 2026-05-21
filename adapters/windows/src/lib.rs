//! MCI Windows adapter — Phase 8 scaffold.
//!
//! Implements [`CaptureSource`] for Windows via:
//! - [`graphics_capture`] — `Windows.Graphics.Capture` frame acquisition
//! - [`uia_context`] — UI Automation for frontmost app / focused window
//! - [`media_foundation_encoder`] — Media Foundation H.264/HEVC hardware encode
//!
//! All methods are stubbed with `unimplemented!()`. The crate compiles as
//! an empty library on non-Windows targets (macOS, Linux) so the workspace
//! builds clean everywhere.
//!
//! # Privacy invariants (ported from ADR-0013 / macOS adapter)
//!
//! The following invariants MUST be preserved when wiring real implementations:
//!
//! | # | Invariant | macOS mechanism | Windows equivalent |
//! |---|-----------|----------------|--------------------|
//! | 1 | Cascade before encode | `SuppressionCascade.decide()` before `VideoToolboxHEVCEncoder` | Same Rust cascade; encode call gated identically |
//! | 2 | Fail-closed default | Unknown app → suppress (§7 catchall) | Same — `CascadeOutcome::Suppress` on unknown `app_bundle` |
//! | 3 | Sensitive-surface suppression | `AXSubroleProbe` for secure text fields | UIA `IsPassword` property on focused element |
//! | 4 | Incognito exclusion | Safari/Chrome private-window detection | Chrome `--incognito` flag / Edge InPrivate via UIA window name |
//! | 5 | DRM/protected content | `PixelGridBlackedRegionProbe` for blacked regions | `Windows.Graphics.Capture` excludes DRM surfaces by default |
//! | 6 | Denylist ordering | Denylist checked first, allowlist second | Same cascade ordering in portable Rust core |
//! | 7 | Surface lease RAII | `SurfaceLease::Drop` returns `IOSurface` to pool | `SurfaceLease::Drop` releases `Direct3D11CaptureFrame` |
//! | 8 | No excluded-window capture | `NSWindowSharingType.none` excluded by `SCContentFilter` | `GraphicsCaptureItem` excludes windows with `WDA_EXCLUDEFROMCAPTURE` |

#[cfg(target_os = "windows")]
pub mod graphics_capture;
#[cfg(target_os = "windows")]
pub mod media_foundation_encoder;
#[cfg(target_os = "windows")]
pub mod uia_context;

#[cfg(target_os = "windows")]
mod adapter;

#[cfg(target_os = "windows")]
pub use adapter::WindowsCaptureSource;

// On non-Windows targets, expose a stub struct so downstream code that
// conditionally references this crate can still name the type.
#[cfg(not(target_os = "windows"))]
pub struct WindowsCaptureSource {
    _private: (),
}
