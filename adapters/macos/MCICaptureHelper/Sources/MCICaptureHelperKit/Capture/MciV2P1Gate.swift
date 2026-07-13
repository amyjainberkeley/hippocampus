// SPDX-License-Identifier: TBD-private
//
// MciV2P1Gate — env-var-gated runtime activation of the V2-P1
// third-lift capture pipeline.
//
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ ADR-0031 §Status M4 LIFT (env-var-gated interim, Phase 7 PR 14)  │
// │                                                                  │
// │ The M4 lift flips the V2-P1 capture pipeline LIVE at runtime:    │
// │   • `killOcrEmit`   : true  → false                              │
// │   • `captureEnabled`: false → true (default-argv behavior)       │
// │                                                                  │
// │ Per the ratified third-lift discipline, the full lift requires a │
// │ live-Mac §7-equivalent smoke test (redesign memo §3.2 H6′–H10′)  │
// │ that the fleet cannot run — it needs Amy's physical Mac +        │
// │ interactive input. This PR ships the CODE path complete but      │
// │ gates the runtime activation on a single environment variable:   │
// │                                                                  │
// │       HIPPOCAMPUS_ENABLE_V2P1=1                                  │
// │                                                                  │
// │ When set to exactly "1", the gate returns `.enabled` and the     │
// │ boot path overrides both flags. Anything else (unset, "", "0",   │
// │ "true", "yes", etc.) leaves the current default-OFF behavior in  │
// │ place — users on the shipped DMG see NO change. Amy sets the env │
// │ var + builds a local DMG when she is ready to run the smoke      │
// │ test; a follow-up PR removes the gate once the smoke passes.     │
// │                                                                  │
// │ The gate is ONE-WAY: read once at process boot into a cached     │
// │ `static let`, never re-read. This keeps the audit trail clean —  │
// │ every log line + wire frame in one helper run reflects a single  │
// │ gate state.                                                      │
// └──────────────────────────────────────────────────────────────────┘

import Foundation

/// The V2-P1 runtime gate state.
public enum MciV2P1GateState: String, Sendable, Equatable {
    /// Gate is OFF (default): preserve pre-M4-lift behavior —
    /// `killOcrEmit = true`, `captureEnabled = false` (unless the
    /// dev-only `--capture` argv is passed). This is what every user on
    /// the shipping DMG sees.
    case disabled

    /// Gate is ON: override both flags at boot so the V2-P1 capture
    /// pipeline runs live. Enabled ONLY by `HIPPOCAMPUS_ENABLE_V2P1=1`.
    case enabled
}

/// The env-var-gated M4-lift decision. Read once at boot; cached for
/// the process lifetime.
public enum MciV2P1Gate {
    /// The env var name that flips the gate. Named verbosely so a grep
    /// for the M4-lift activation point lands here.
    public static let envVarName = "HIPPOCAMPUS_ENABLE_V2P1"

    /// The single string that flips the gate on. Any other value ⇒
    /// `.disabled`. Chosen as `"1"` (not "true" / "yes") so the check
    /// is unambiguous and shell-portable.
    public static let enableValue = "1"

    /// The gate state, cached at first access. Reads the env var
    /// exactly once per process; subsequent accesses return the cached
    /// value.
    ///
    /// Uses `ProcessInfo.processInfo.environment[...]` so the check is
    /// testable via `stateFor(env:)` below without relying on process
    /// env mutation (which is unsafe in the presence of concurrent
    /// getenv callers).
    public static let current: MciV2P1GateState = stateFor(
        env: ProcessInfo.processInfo.environment
    )

    /// Pure decision function. Extracted so tests can exercise it
    /// against a synthetic env dictionary without process-level
    /// setenv/unsetenv (which is not thread-safe on Darwin).
    public static func stateFor(env: [String: String]) -> MciV2P1GateState {
        guard let value = env[envVarName] else { return .disabled }
        return value == enableValue ? .enabled : .disabled
    }

    /// Human-readable one-line breadcrumb for stderr at boot. Content-
    /// free (only the enum state — no env values echoed) so grepping
    /// `helper.stderr.log` for `v2p1_gate=` returns exactly one line
    /// per helper run.
    public static func stderrBreadcrumb(_ state: MciV2P1GateState) -> String {
        "mci-capture-helper: helper_health v2p1_gate=\(state.rawValue)\n"
    }
}
