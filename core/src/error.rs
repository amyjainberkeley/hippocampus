//! Core error type.
//!
//! Adapter / pipeline / store / sync modules each have their own narrow error
//! types; this enum is the single boundary type the agent shell ultimately
//! collapses everything into. New variants land **with** the module that
//! produces them, not preemptively.

use thiserror::Error;

/// The top-level error type for `mci-core`.
#[derive(Debug, Error)]
pub enum CoreError {
    /// A [`crate::capture::CaptureSource`] returned an error.
    #[error("capture: {0}")]
    Capture(#[from] crate::capture::CaptureError),
}
