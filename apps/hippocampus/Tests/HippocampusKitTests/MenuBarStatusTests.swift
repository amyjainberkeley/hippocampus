// SPDX-License-Identifier: TBD-private
//
// Tests for MenuBarStatus — the status-light state machine + NSImage
// factory shipped for cycle 8.45 Raycast/Cotypist peer study pattern
// #3 (P0) + cycle 8.44 audit polish gap #1.
//
// Two things to pin:
//
//   1. Derivation from `SupervisorState` (+ optional integrity error
//      override) maps to the correct `MenuBarStatus` for each of the
//      four visual states. This is the "pause toggle updates status
//      from Recording → Paused and back" unit check from the brief.
//
//   2. The `MenuBarStatusIcon` factory produces four visually
//      distinct NSImages for the four states. We compare the TIFF
//      byte representation — a cheap snapshot equivalent that catches
//      any regression where two states collapse to the same rendered
//      output (e.g. someone accidentally removes the pause overlay).
import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import HippocampusKit

final class MenuBarStatusTests: XCTestCase {

    // MARK: - Derivation

    func testDerivation_running_isRecording() {
        XCTAssertEqual(MenuBarStatus.derive(from: .running), .recording)
    }

    func testDerivation_paused_isPaused() {
        XCTAssertEqual(MenuBarStatus.derive(from: .paused), .paused)
    }

    func testDerivation_idleStarterStopped_areIdle() {
        XCTAssertEqual(MenuBarStatus.derive(from: .idle), .idle)
        XCTAssertEqual(MenuBarStatus.derive(from: .starting), .idle)
        XCTAssertEqual(MenuBarStatus.derive(from: .stopped), .idle)
    }

    func testDerivation_crashed_isError() {
        let status = MenuBarStatus.derive(from: .crashed(reason: "boom"))
        guard case .error(let reason) = status else {
            return XCTFail("expected .error, got \(status)")
        }
        XCTAssertEqual(reason, "boom")
    }

    /// Integrity error takes precedence over even a `.running`
    /// supervisor state — the health path can flip integrity failed
    /// without tearing down the child processes, and users must see
    /// the error signal first.
    func testDerivation_integrityErrorOverridesRunning() {
        let status = MenuBarStatus.derive(
            from: .running,
            integrityError: "hash mismatch"
        )
        guard case .error(let reason) = status else {
            return XCTFail("expected .error, got \(status)")
        }
        XCTAssertEqual(reason, "hash mismatch")
    }

    // MARK: - Pause toggle round-trip

    /// The pause-toggle unit check from the agent brief:
    /// `.running` → user pauses → supervisor reports `.paused` →
    /// derivation reflects `.paused`. Resume → `.running` →
    /// derivation reflects `.recording`.
    func testPauseToggle_recordingPausedRoundTrip() {
        var state: SupervisorState = .running
        XCTAssertEqual(MenuBarStatus.derive(from: state), .recording)

        state = .paused
        XCTAssertEqual(MenuBarStatus.derive(from: state), .paused)

        state = .running
        XCTAssertEqual(MenuBarStatus.derive(from: state), .recording)
    }

    // MARK: - Presentation properties

    func testDisplayText_isDistinctPerState() {
        let texts: Set<String> = [
            MenuBarStatus.idle.displayText,
            MenuBarStatus.recording.displayText,
            MenuBarStatus.paused.displayText,
            MenuBarStatus.error(reason: "x").displayText,
        ]
        XCTAssertEqual(texts.count, 4, "each state must have a unique display label")
    }

    func testShouldPulse_onlyRecording() {
        XCTAssertTrue(MenuBarStatus.recording.shouldPulse)
        XCTAssertFalse(MenuBarStatus.idle.shouldPulse)
        XCTAssertFalse(MenuBarStatus.paused.shouldPulse)
        XCTAssertFalse(MenuBarStatus.error(reason: "x").shouldPulse)
    }

    // MARK: - Pulse timing

    /// The pulse alternates between full (1.0) and dim (0.7) on
    /// `pulsePeriod` boundaries. This locks the pure function so any
    /// future tweak (e.g. shorter pulse for accessibility mode) shows
    /// up as a test change rather than a silent visual drift.
    func testPulseOpacity_alternatesOnPeriodBoundary() {
        let period = MenuBarStatusLabel.pulsePeriod
        let base = Date(timeIntervalSinceReferenceDate: 0)

        // t = 0.5·period → inside the first half → full opacity.
        let first = MenuBarStatusLabel.pulseOpacity(
            at: base.addingTimeInterval(period * 0.5)
        )
        XCTAssertEqual(first, 1.0, accuracy: 0.0001)

        // t = 1.5·period → inside the second half → dim opacity.
        let second = MenuBarStatusLabel.pulseOpacity(
            at: base.addingTimeInterval(period * 1.5)
        )
        XCTAssertEqual(second, MenuBarStatusLabel.pulseMin, accuracy: 0.0001)
    }

    // MARK: - Icon snapshot distinctness

    #if canImport(AppKit)
    /// The four states must render to four visually distinct icons.
    /// We serialize each NSImage's TIFF bytes and check pairwise
    /// inequality — a cheap snapshot-equivalent that catches
    /// accidental collapses (e.g. the pause or error overlay being
    /// silently dropped).
    ///
    /// This runs headless in `swift test` — `NSImage.lockFocus` uses
    /// a bitmap graphics context that does not need a window server
    /// on macOS 14+.
    func testMenuBarStatusIcon_fourStatesAreDistinct() throws {
        let states: [MenuBarStatus] = [
            .idle,
            .recording,
            .paused,
            .error(reason: "test"),
        ]
        let tiffs = states.map { MenuBarStatusIcon.image(for: $0).tiffRepresentation }

        for tiff in tiffs {
            XCTAssertNotNil(tiff, "each rendered icon must produce a TIFF")
        }
        for i in 0..<tiffs.count {
            for j in (i + 1)..<tiffs.count {
                XCTAssertNotEqual(
                    tiffs[i], tiffs[j],
                    "icons for \(states[i]) and \(states[j]) must be visually distinct"
                )
            }
        }
    }
    #endif
}
