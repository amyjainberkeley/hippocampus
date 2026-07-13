//! V2-P1 M4-lift runtime gate — Rust-side.
//!
//! **PROTECTED-SET per AGENT_PROTOCOL §5.**
//!
//! ADR-0031 §Status M4 LIFT (env-var-gated interim, Phase 7 PR 14).
//! Companion to `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/MciV2P1Gate.swift`
//! — same env-var contract, same one-way discipline, applied on the
//! agent side of the fork so the supervisor can decide whether to pass
//! the `--capture` argv flag when it spawns the Swift helper.
//!
//! # Contract
//!
//! `HIPPOCAMPUS_ENABLE_V2P1=1` at agent process boot ⇒ [`State::Enabled`].
//! Anything else (unset, `""`, `"0"`, `"true"`, `"yes"`, ...) ⇒
//! [`State::Disabled`]. The gate is READ ONCE per process via
//! [`State::current`] and CACHED in a `OnceLock`. All log lines and
//! spawn decisions in one agent run reflect a single gate state.
//!
//! # Why a matched pair (Swift + Rust)
//!
//! The Swift helper reads its OWN env inheritance (via
//! `ProcessInfo.processInfo.environment`) and flips both
//! `captureEnabled` (argv-parse override) and
//! `CascadeTwiceOCREmitter.killOcrEmit` at helper boot. The Rust agent
//! reads the SAME env var to decide whether to add `--capture` to the
//! argv it passes the helper child — belt-and-suspenders: even if the
//! child's env inheritance is lost (systemd-style env-clear on an
//! adopted parent path), the argv still activates the pipeline.
//!
//! # Default behavior
//!
//! Env var unset or set to anything other than `"1"` ⇒ gate returns
//! [`State::Disabled`]; [`HelperSpawnConfig::cli_args`](crate::supervisor::HelperSpawnConfig::cli_args)
//! does NOT add `--capture`; Swift helper's kill-switch stays engaged.
//! Users on the shipped DMG see NO change until Amy exports
//! `HIPPOCAMPUS_ENABLE_V2P1=1` for her local smoke test.
//!
//! # Follow-up PR
//!
//! Once Amy's live-Mac §7-equivalent smoke test comes back GREEN
//! (redesign memo §3.2 H6′–H10′), a separate PR removes this gate
//! and makes V2-P1 the shipping default. This module + its Swift
//! counterpart are the interim.

use std::sync::OnceLock;

/// Environment variable that gates the M4 lift.
///
/// Named verbosely so a grep for the M4-lift activation point in the
/// agent process lands here.
pub const ENV_VAR_NAME: &str = "HIPPOCAMPUS_ENABLE_V2P1";

/// The single string value that flips the gate ON. Chosen as `"1"`
/// (not `"true"` / `"yes"`) so the check is unambiguous and shell-
/// portable.
pub const ENABLE_VALUE: &str = "1";

/// The V2-P1 runtime gate state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// Gate is OFF (default). Preserve pre-M4-lift behavior.
    Disabled,
    /// Gate is ON. Agent adds `--capture` to helper argv; Swift helper
    /// overrides `captureEnabled` + `killOcrEmit` at its own boot.
    Enabled,
}

impl State {
    /// Read-once, cached gate state for this agent process.
    ///
    /// Uses `std::env::var` at first access and stores the outcome in
    /// a `OnceLock`. Subsequent calls return the cached value without
    /// re-reading the env — the audit trail is one gate state per
    /// process, always.
    ///
    /// # Why not `env::var_os` directly at every call
    /// Two reasons: (a) a follow-up call from a test that mutates the
    /// env would silently flip production behavior mid-run — the
    /// `OnceLock` closes that; (b) the cost of the read is trivial but
    /// the discipline of "read once" is load-bearing for the audit
    /// table row on determinism.
    #[must_use]
    pub fn current() -> Self {
        static CACHED: OnceLock<State> = OnceLock::new();
        *CACHED.get_or_init(|| Self::for_env_value(std::env::var(ENV_VAR_NAME).ok().as_deref()))
    }

    /// Pure decision function — takes an `Option<&str>` so tests can
    /// exercise every branch without process-level env mutation
    /// (which is not thread-safe on POSIX and would race the
    /// `OnceLock` used by `current`).
    #[must_use]
    pub fn for_env_value(value: Option<&str>) -> Self {
        match value {
            Some(v) if v == ENABLE_VALUE => Self::Enabled,
            _ => Self::Disabled,
        }
    }

    /// Human-readable one-line breadcrumb for the agent's stderr at
    /// boot. Content-free (only the enum state); matches the format of
    /// the Swift helper's `MciV2P1Gate.stderrBreadcrumb(_:)` so
    /// grepping across BOTH log streams returns one line per gate
    /// component.
    #[must_use]
    pub fn stderr_breadcrumb(self) -> String {
        let tag = match self {
            State::Enabled => "enabled",
            State::Disabled => "disabled",
        };
        format!("mci-agent: helper_health v2p1_gate={tag}\n")
    }

    /// Whether the supervisor should append `--capture` to the helper
    /// argv this launch. `true` iff [`State::Enabled`].
    #[must_use]
    pub const fn passes_capture_argv(self) -> bool {
        matches!(self, State::Enabled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_disabled_when_env_missing() {
        assert_eq!(State::for_env_value(None), State::Disabled);
    }

    #[test]
    fn env_var_set_to_1_enables_gate() {
        assert_eq!(State::for_env_value(Some("1")), State::Enabled);
    }

    #[test]
    fn env_var_set_to_empty_string_is_disabled() {
        assert_eq!(State::for_env_value(Some("")), State::Disabled);
    }

    #[test]
    fn env_var_set_to_0_is_disabled() {
        assert_eq!(State::for_env_value(Some("0")), State::Disabled);
    }

    #[test]
    fn env_var_set_to_truthy_alternates_is_disabled_only_1_flips() {
        // Discipline: only the exact string "1" enables. This mirrors
        // the Swift-side `MciV2P1Gate` contract.
        assert_eq!(State::for_env_value(Some("true")), State::Disabled);
        assert_eq!(State::for_env_value(Some("yes")), State::Disabled);
        assert_eq!(State::for_env_value(Some("on")), State::Disabled);
        assert_eq!(State::for_env_value(Some("TRUE")), State::Disabled);
        assert_eq!(State::for_env_value(Some("Y")), State::Disabled);
    }

    #[test]
    fn env_var_name_matches_swift_side() {
        // Load-bearing pairing: the Swift `MciV2P1Gate.envVarName` MUST
        // read the same env var name as this module. Any drift here
        // silently produces a split-brain gate where the agent adds
        // `--capture` but the Swift helper's `killOcrEmit` stays engaged
        // (or vice versa). Encode the invariant.
        assert_eq!(ENV_VAR_NAME, "HIPPOCAMPUS_ENABLE_V2P1");
    }

    #[test]
    fn enable_value_matches_swift_side() {
        assert_eq!(ENABLE_VALUE, "1");
    }

    #[test]
    fn passes_capture_argv_only_when_enabled() {
        assert!(State::Enabled.passes_capture_argv());
        assert!(!State::Disabled.passes_capture_argv());
    }

    #[test]
    fn stderr_breadcrumb_renders_disabled() {
        assert_eq!(
            State::Disabled.stderr_breadcrumb(),
            "mci-agent: helper_health v2p1_gate=disabled\n"
        );
    }

    #[test]
    fn stderr_breadcrumb_renders_enabled() {
        assert_eq!(
            State::Enabled.stderr_breadcrumb(),
            "mci-agent: helper_health v2p1_gate=enabled\n"
        );
    }
}
