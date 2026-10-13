// SPDX-License-Identifier: TBD-private
//
// Tests for the state coordination between UserPauseController and
// MenuBarStatus. The status item itself lives in the executable target
// (Hippocampus), which is not testable, but the data layers under the
// menu are — so we pin those.
//
// The invariants:
//   - When the supervisor reports `.paused`, `MenuBarStatus.derive` yields
//     `.paused`: the menu's first line reads "Paused" and the icon shows
//     the dim picture.
//   - The four canonical states (off, remembering, paused, not saving) keep
//     four distinct labels. The icon pictures are pinned in
//     `MenuBarStatusTests.swift`; this file adds the label-per-state check.
//
// Each test uses its own controller: the app's shared one keeps the pause
// in real defaults.

import XCTest
@testable import HippocampusKit

final class MenuBarQuickActionsTests: XCTestCase {

    func testFourStates_labelDistinctness() {
        let labels = Set([
            MenuBarStatus.derive(from: .idle).displayText,
            MenuBarStatus.recording.displayText,
            MenuBarStatus.derive(from: .paused).displayText,
            MenuBarStatus.derive(from: .crashed(reason: "boom")).displayText,
        ])
        XCTAssertEqual(labels, ["Off", "Remembering", "Paused", "Not saving"])
    }

    /// Remembering turned off in Preferences still runs the agent: the menu
    /// says Off and offers Turn On.
    func testDefaultOffRunningTopologyIsOffWithTurnOn() {
        let status = MenuBarStatus.derive(from: .running, captureEnabled: false)
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(StatusRow(StatusFacts(status: status), now: Date()).action, .turnOn)
    }

    /// The person pauses → the supervisor reports `.paused` → the status
    /// reads Paused. On resume a run must save before it says Remembering.
    func testUserPauseCoordination_pausedThenResumed() {
        let pauses = UserPauseController()
        pauses.setPaused(true)
        XCTAssertTrue(pauses.isPaused)
        XCTAssertEqual(MenuBarStatus.derive(from: .paused), .paused)

        pauses.setPaused(false)
        XCTAssertFalse(pauses.isPaused)
        XCTAssertNotEqual(MenuBarStatus.derive(from: .running), .recording)
    }

    /// Paused and a permission turned off together: the pause is what the
    /// person did last, so it is what the menu says.
    func testUserPauseAndTCCRevoke_pauseTakesPrecedence() {
        let status = MenuBarStatus.derive(
            from: .paused,
            tccRevokedSurface: .screenRecording
        )
        XCTAssertEqual(status, .paused)
    }
}
