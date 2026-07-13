// SPDX-License-Identifier: TBD-private
//
// MciV2P1GateTests — OS-FREE proof of the M4-lift env-var gate
// semantics. Exercises the pure decision function against synthetic
// env dictionaries; the process-level `.current` static is not read
// here (its cache is process-lifetime and would leak between tests).

import XCTest

@testable import MCICaptureHelperKit

final class MciV2P1GateTests: XCTestCase {
    func test_default_is_disabled_when_env_var_missing() {
        XCTAssertEqual(MciV2P1Gate.stateFor(env: [:]), .disabled)
    }

    func test_env_var_set_to_1_enables_gate() {
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": "1"]),
            .enabled
        )
    }

    func test_env_var_set_to_empty_string_is_disabled() {
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": ""]),
            .disabled
        )
    }

    func test_env_var_set_to_0_is_disabled() {
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": "0"]),
            .disabled
        )
    }

    func test_env_var_set_to_true_is_disabled_only_1_flips() {
        // Discipline: only the exact string "1" enables. "true" / "yes"
        // / "on" / "TRUE" do NOT — one canonical form keeps the audit
        // trail unambiguous.
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": "true"]),
            .disabled
        )
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": "yes"]),
            .disabled
        )
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: ["HIPPOCAMPUS_ENABLE_V2P1": "TRUE"]),
            .disabled
        )
    }

    func test_unrelated_env_vars_do_not_flip_gate() {
        XCTAssertEqual(
            MciV2P1Gate.stateFor(env: [
                "PATH": "/usr/bin",
                "HIPPOCAMPUS_SOMETHING_ELSE": "1",
                "HIPPOCAMPUS_ENABLE_V2P1_EXTRA": "1",
            ]),
            .disabled
        )
    }

    func test_env_var_name_is_the_documented_one() {
        XCTAssertEqual(MciV2P1Gate.envVarName, "HIPPOCAMPUS_ENABLE_V2P1")
    }

    func test_enable_value_is_the_documented_one() {
        XCTAssertEqual(MciV2P1Gate.enableValue, "1")
    }

    func test_stderr_breadcrumb_renders_disabled() {
        XCTAssertEqual(
            MciV2P1Gate.stderrBreadcrumb(.disabled),
            "mci-capture-helper: helper_health v2p1_gate=disabled\n"
        )
    }

    func test_stderr_breadcrumb_renders_enabled() {
        XCTAssertEqual(
            MciV2P1Gate.stderrBreadcrumb(.enabled),
            "mci-capture-helper: helper_health v2p1_gate=enabled\n"
        )
    }

    func test_gate_state_enum_conforms_to_equatable() {
        // Load-bearing: `HelperSpawnConfig.cli_args` + wiring tests
        // compare against `.enabled` / `.disabled` — a future refactor
        // that dropped Equatable would silently break those callers.
        XCTAssertEqual(MciV2P1GateState.enabled, .enabled)
        XCTAssertNotEqual(MciV2P1GateState.enabled, .disabled)
    }

    // MARK: - Integration: gate-enabled boot overrides both flags

    func test_gate_enabled_activates_m4_lift_flips_both_capture_flags() {
        // Simulate the `main.swift` boot path under `.enabled`:
        //   1. Construct effective `CaptureLaunchOptions` from a boot
        //      argv that did NOT pass `--capture` (the shipping default).
        //   2. Apply the gate: rebuild options with `captureEnabled=true`
        //      + activate the M4 lift on `CascadeTwiceOCREmitter`.
        //   3. Assert both flags reflect the M4-lift state.

        // Save + restore the process-lifetime kill-switch around the
        // test so the module default stays `true` after we exit — the
        // `MultiWindowFilterScopeFenceTests` guard depends on this.
        let originalKillState = CascadeTwiceOCREmitter.killOcrEmit
        defer { CascadeTwiceOCREmitter.killOcrEmit = originalKillState }

        // Baseline parse (no --capture): default OFF path.
        let parsed = CaptureLaunchOptions.parse(["mci-capture-helper"])
        XCTAssertFalse(parsed.captureEnabled)

        // Simulate gate == .enabled boot behavior.
        let gateState: MciV2P1GateState = .enabled
        let effective: CaptureLaunchOptions
        switch gateState {
        case .enabled:
            effective = CaptureLaunchOptions(captureEnabled: true)
            CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
        case .disabled:
            effective = parsed
        }

        XCTAssertTrue(effective.captureEnabled)
        XCTAssertFalse(CascadeTwiceOCREmitter.killOcrEmit,
                       "M4 lift MUST flip killOcrEmit off when gate is enabled")
    }

    func test_gate_disabled_preserves_default_off_behavior() {
        // Simulate gate == .disabled: even without `--capture` argv,
        // nothing gets overridden. This is the shipping-DMG user path.
        let originalKillState = CascadeTwiceOCREmitter.killOcrEmit
        defer { CascadeTwiceOCREmitter.killOcrEmit = originalKillState }

        let parsed = CaptureLaunchOptions.parse(["mci-capture-helper"])
        let gateState: MciV2P1GateState = .disabled
        let effective: CaptureLaunchOptions
        switch gateState {
        case .enabled:
            effective = CaptureLaunchOptions(captureEnabled: true)
            CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
        case .disabled:
            effective = parsed
        }

        XCTAssertFalse(effective.captureEnabled,
                       "Default-OFF preserved under .disabled gate")
        XCTAssertTrue(CascadeTwiceOCREmitter.killOcrEmit,
                      "killOcrEmit MUST stay engaged under .disabled gate")
    }

    func test_activate_m4_lift_rollback_re_engages_kill_switch() {
        // `activateM4Lift(enabled: false)` restores pre-M4-lift state —
        // pinned so a future PR that removes this contract fails CI.
        let originalKillState = CascadeTwiceOCREmitter.killOcrEmit
        defer { CascadeTwiceOCREmitter.killOcrEmit = originalKillState }

        CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
        XCTAssertFalse(CascadeTwiceOCREmitter.killOcrEmit)

        CascadeTwiceOCREmitter.activateM4Lift(enabled: false)
        XCTAssertTrue(CascadeTwiceOCREmitter.killOcrEmit)
    }
}
