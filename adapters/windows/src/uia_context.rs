//! UI Automation (UIA) context provider for Windows.
//!
//! Windows equivalent of macOS `NSWorkspaceContextProvider` + `AXSubroleProbe`.
//! Uses the Windows UI Automation API to query:
//! - Frontmost application (process name / exe path)
//! - Focused window title
//! - Focused element properties (for sensitive-surface detection)
//! - Browser URL bar content (fallback when no browser extension installed)
//!
//! # Privacy invariants
//!
//! **§3 sensitive-surface suppression:** UIA exposes `IsPassword` on edit
//! controls — the direct equivalent of macOS `AXSubrole == AXSecureTextField`.
//! The cascade MUST suppress when `IsPassword == true` on the focused element.
//!
//! **§4 incognito exclusion:** Chrome/Edge InPrivate windows include
//! "(Incognito)" / "(InPrivate)" in the window title. UIA
//! `IUIAutomationElement::CurrentName` provides this without needing
//! browser-specific APIs. Additionally, Chrome's `--incognito` command-line
//! flag is detectable via process inspection.

use mci_core::capture::WorkflowContext;

/// Query the frontmost application's process name and executable path.
///
/// Uses `GetForegroundWindow` + `GetWindowThreadProcessId` + process handle.
pub fn frontmost_app() -> Option<String> {
    unimplemented!("Phase 8: GetForegroundWindow → process name")
}

/// Query the focused window's title text.
///
/// Uses `IUIAutomationElement::CurrentName` on the focused window element.
pub fn focused_window_title() -> Option<String> {
    unimplemented!("Phase 8: UIA focused window title")
}

/// Check whether the focused UI element is a password field.
///
/// Returns `true` if `IUIAutomationElement::CurrentIsPassword` is set.
/// This is the Windows equivalent of macOS `AXSubrole == AXSecureTextField`
/// and triggers cascade §3 sensitive-surface suppression.
pub fn focused_element_is_password() -> bool {
    unimplemented!("Phase 8: UIA IsPassword check on focused element")
}

/// Detect whether the focused window is an incognito/private browser window.
///
/// Heuristic: window title contains "(Incognito)", "(InPrivate)", or
/// "(Private Browsing)". Falls back to process command-line inspection
/// for `--incognito` flag.
pub fn is_incognito_window() -> bool {
    unimplemented!("Phase 8: incognito/InPrivate window detection via UIA + process args")
}

/// Build a full `WorkflowContext` snapshot from UIA queries.
///
/// Combines `frontmost_app()`, `focused_window_title()`, and optionally
/// browser URL extraction into a single context probe result.
pub fn probe_workflow_context() -> WorkflowContext {
    unimplemented!("Phase 8: full UIA WorkflowContext probe")
}
