//! `CaptureSource` implementation for Windows.

use async_trait::async_trait;
use mci_core::capture::{
    CaptureError, CaptureSource, PermissionState, PermissionsStatus, StateTransitionSender,
    WorkflowContext,
};

pub struct WindowsCaptureSource {
    _running: bool,
}

impl WindowsCaptureSource {
    #[must_use]
    pub fn new() -> Self {
        Self { _running: false }
    }
}

impl Default for WindowsCaptureSource {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CaptureSource for WindowsCaptureSource {
    async fn start(&mut self, _tx: StateTransitionSender) -> Result<(), CaptureError> {
        unimplemented!("Phase 8: Windows.Graphics.Capture session start")
    }

    async fn stop(&mut self) -> Result<(), CaptureError> {
        unimplemented!("Phase 8: Windows.Graphics.Capture session stop")
    }

    fn permissions_status(&self) -> PermissionsStatus {
        // Windows Graphics Capture shows a system picker (consent per-item).
        // Accessibility (UIA) requires no permission on Windows.
        // Automation is not applicable (macOS-only concept).
        PermissionsStatus {
            screen_recording: PermissionState::Denied,
            accessibility: PermissionState::Granted,
            automation: PermissionState::NotApplicable,
        }
    }

    fn context_probe(&self) -> WorkflowContext {
        unimplemented!("Phase 8: UIA context probe (frontmost app + focused window + URL)")
    }
}
