// SPDX-License-Identifier: TBD-private
//
// Tests for MenuBarStatus — the status-light state machine + NSImage
// factory shipped for cycle 8.45 Raycast/Cotypist peer study pattern
// #3 (P0) + cycle 8.44 audit polish gap #1.
//
// Two things to pin:
//
//   1. Derivation from `SupervisorState` (+ optional integrity error
//      override) maps to the correct `MenuBarStatus`. This is the
//      "pause toggle updates status from Recording → Paused and back"
//      unit check from the brief.
//
//   2. The `MenuBarStatusIcon` factory draws the four hi pictures
//      (solid dot, hollow dot, dim, h!) as templates with 22, 44 and
//      66 px bitmaps and keeps them distinct. Every state in which the
//      screen may be read and nothing failed shows the solid dot; only a
//      password field shows the hollow one (RULINGS B1).
import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import HippocampusKit

final class MenuBarStatusTests: XCTestCase {

    // MARK: - Derivation

    func testDerivation_runningAloneDoesNotProveSavedMemory() {
        XCTAssertNotEqual(MenuBarStatus.derive(from: .running), .recording)
    }

    func testDerivation_paused_isPaused() {
        XCTAssertEqual(MenuBarStatus.derive(from: .paused), .paused)
    }

    func testDerivation_idleStarterStopped_areIdle() {
        XCTAssertEqual(MenuBarStatus.derive(from: .idle), .idle)
        XCTAssertEqual(MenuBarStatus.derive(from: .starting), .starting)
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
        XCTAssertNotEqual(MenuBarStatus.derive(from: state), .recording)

        state = .paused
        XCTAssertEqual(MenuBarStatus.derive(from: state), .paused)

        state = .running
        XCTAssertNotEqual(MenuBarStatus.derive(from: state), .recording)
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

    func testAllStatesAreStatic() {
        let states: [MenuBarStatus] = [
            .idle, .starting, .recording, .paused, .error(reason: "x"),
            .needsPermission(.screenRecording), .blocked(reason: "x"),
            .stale(reason: "x"), .noMemory, .unchanged,
        ]
        for state in states { XCTAssertFalse(state.shouldPulse) }
    }

    // MARK: - The hollow dot

    /// Only a password field stops every read. Any other skip leaves the
    /// rest of the screen being read, and a fault is not a skip, so
    /// neither may show the hollow dot: the icon must never understate.
    func testOnlyAPasswordFieldCanShowTheHollowDot() throws {
        let now = Date(timeIntervalSince1970: 1_788_609_600)
        func picture(suppression: String? = nil, blocked: String? = nil) throws -> HiMark.State {
            let stamp = ISO8601DateFormatter().string(from: now)
            var json: [String: Any] = [
                "schema_version": 1, "updated_at": stamp, "last_stored_frame_at": stamp,
                "stored_frame_count": 12, "stored_screenshot_count": 12,
            ]
            json["suppression_reason"] = suppression
            json["blocked_reason"] = blocked
            let receipt = try CaptureStatusReceipt.decode(JSONSerialization.data(withJSONObject: json))
            return MenuBarStatus.derive(from: .running, receipt: receipt,
                                        captureStartedAt: now.addingTimeInterval(-60), now: now).markState
        }
        // The receipt is fresh: with no reason it shows the solid dot.
        XCTAssertEqual(try picture(), .remembering)
        let skips = [
            "app_denied", "denylist-source", "denylist-postcapture", "ax-secure-subrole",
            "os-blacked-region", "ocr-time-secret", "failsafe-unknown", "focus-race-dropped",
            "private_browsing", "browser_window_unknown", "app_identity_unknown",
        ]
        for code in skips {
            XCTAssertNotEqual(try picture(suppression: code), .skipping, code)
        }
        let faults = [
            "storage_error", "store_unavailable", "ingest_failed", "helper_disconnected",
            "capture_failed", "capture_disabled", "unrecognized",
        ]
        for code in faults {
            XCTAssertNotEqual(try picture(blocked: code), .skipping, code)
        }
    }

    // MARK: - Status truth (spec-shell S4, RULINGS B1 and S8)

    private let now = Date(timeIntervalSince1970: 1_788_609_600)

    private func receipt(
        count: Int = 12, savedAgo: TimeInterval? = 5, updatedAgo: TimeInterval = 0,
        suppression: String? = nil, blocked: String? = nil
    ) throws -> CaptureStatusReceipt {
        let formatter = ISO8601DateFormatter()
        var json: [String: Any] = [
            "schema_version": 1, "updated_at": formatter.string(from: now.addingTimeInterval(-updatedAgo)),
            "stored_frame_count": count, "stored_screenshot_count": count, "last_stored_frame_at": NSNull(),
        ]
        if let savedAgo { json["last_stored_frame_at"] = formatter.string(from: now.addingTimeInterval(-savedAgo)) }
        json["suppression_reason"] = suppression
        json["blocked_reason"] = blocked
        return try CaptureStatusReceipt.decode(JSONSerialization.data(withJSONObject: json))
    }

    /// A run that started a minute ago, with the skip seen `skipHeld` ago.
    private func running(_ receipt: CaptureStatusReceipt?, skipHeld: TimeInterval? = nil, startedAgo: TimeInterval = 60) -> MenuBarStatus {
        MenuBarStatus.derive(from: .running, receipt: receipt, captureStartedAt: now.addingTimeInterval(-startedAgo),
                             skipSeenSince: skipHeld.map { now.addingTimeInterval(-$0) }, now: now)
    }

    private static let privacyCodes = [
        "app_denied", "denylist-source", "denylist-postcapture", "secure_input", "secure-event-input",
        "ax-secure-subrole", "os-blacked-region", "ocr-time-secret", "failsafe-unknown",
        "private_browsing", "browser_window_unknown", "app_identity_unknown",
    ]

    /// Privacy codes are skips, never failures, so they never show h!; a
    /// password field shows the hollow dot and every other skip the solid
    /// one, because the rest of the screen is still read.
    func testAPasswordFieldOrAnExcludedAppNeverShowsHBang() throws {
        for code in Self.privacyCodes {
            let status = running(try receipt(suppression: code), skipHeld: 11)
            XCTAssertEqual(status, .skipping(reason: code), code)
            XCTAssertEqual(status.displayText, "Skipping this window", code)
            XCTAssertNotEqual(status.markState, .needsYou, code)
            let password = ["secure_input", "secure-event-input"].contains(code)
            XCTAssertEqual(status.markState, password ? .skipping : .remembering, code)
        }
        XCTAssertEqual(running(try receipt(suppression: "secure_input"), skipHeld: 11).markState, .skipping)
        XCTAssertEqual(running(try receipt(suppression: "denylist-source"), skipHeld: 11).markState, .remembering)
    }

    /// The receipt's skip is the last since the last save, from any window,
    /// so it shows only once it has held about 10 s (RULINGS S8). Until
    /// then it stays "Remembering", with the solid dot.
    func testASkipShowsOnlyOnceItHasHeld() throws {
        for code in Self.privacyCodes {
            for held in [nil, 0, 9.9] as [TimeInterval?] {
                let status = running(try receipt(suppression: code), skipHeld: held)
                XCTAssertEqual(status, .recording, "\(code) held \(String(describing: held))")
                XCTAssertEqual(status.markState, .remembering)
            }
            XCTAssertEqual(running(try receipt(suppression: code), skipHeld: 10), .skipping(reason: code))
        }
    }

    /// A fast window switch is not a skip worth showing; it stays
    /// "Remembering" (product critique 10).
    func testAFastWindowSwitchStaysRemembering() throws {
        for held in [nil, 11, 3600] as [TimeInterval?] {
            let status = running(try receipt(suppression: "focus-race-dropped"), skipHeld: held)
            XCTAssertEqual(status, .recording)
            XCTAssertEqual(status.displayText, "Remembering")
        }
    }

    /// Failures named by the agent show at once; they are not skips.
    func testFailuresShowAtOnceAsNotSaving() throws {
        for code in ["storage_error", "store_unavailable", "ingest_failed", "activity_ingest_failed",
                     "helper_disconnected", "capture_failed", "capture_disabled", "a-future-code"] {
            let status = running(try receipt(blocked: code))
            XCTAssertEqual(status, .blocked(reason: code), code)
            XCTAssertEqual(status.displayText, "Not saving", code)
            XCTAssertEqual(status.markState, .needsYou, code)
            XCTAssertEqual(status.action, .tryAgain, code)
        }
    }

    /// Every start clears the receipt, and the first heartbeat takes about
    /// 30 s: for 45 s a run with nothing to show is starting, with the
    /// solid dot, not failing (spec-shell S4.3, RULINGS S6).
    func testAYoungRunIsStartingForFortyFiveSeconds() throws {
        XCTAssertEqual(running(nil, startedAgo: 10), .starting)
        XCTAssertEqual(running(nil, startedAgo: 44.9), .starting)
        guard case .stale = running(nil, startedAgo: 45) else { return XCTFail("stale after the grace") }
        // A receipt from before this run.
        XCTAssertEqual(running(try receipt(savedAgo: 25, updatedAgo: 20), startedAgo: 10), .starting)
        guard case .stale = running(try receipt(savedAgo: 75, updatedAgo: 70), startedAgo: 60) else { return XCTFail("stale") }
        // A fresh receipt, no save this run, no heartbeat yet.
        XCTAssertEqual(running(try receipt(savedAgo: 86_400), startedAgo: 20), .starting)
        guard case .stale = running(try receipt(savedAgo: 86_400), startedAgo: 50) else { return XCTFail("stale") }
        XCTAssertEqual(MenuBarStatus.startingGrace, 45)
        XCTAssertEqual(running(nil, startedAgo: 10).markState, .remembering)
    }

    /// A permission turned off while starting leaves the state crashed; it
    /// says which permission so the fix is in reach (spec-shell S4.2). A
    /// failed stop, with capture off, stays an error.
    func testACrashWithAPermissionTurnedOffNeedsPermission() {
        XCTAssertEqual(MenuBarStatus.derive(from: .crashed(reason: "x"), captureEnabled: true,
                                            tccRevokedSurface: .screenRecording),
                       .needsPermission(.screenRecording))
        XCTAssertEqual(MenuBarStatus.derive(from: .crashed(reason: "x"), captureEnabled: false,
                                            tccRevokedSurface: .screenRecording),
                       .error(reason: "x"))
        XCTAssertEqual(MenuBarStatus.derive(from: .crashed(reason: "x")), .error(reason: "x"))
    }

    /// A failed stop, pause or turn-off says "Couldn’t stop" while the
    /// failure stands (product critique 3), ahead of every other reading.
    func testAFailedStopWinsWhileItStands() {
        XCTAssertEqual(MenuBarStatus.derive(from: .crashed(reason: "x"), captureEnabled: false, stopFailed: true),
                       .stopFailed(reason: "x"))
        XCTAssertEqual(MenuBarStatus.derive(from: .crashed(reason: "x"), tccRevokedSurface: .accessibility,
                                            stopFailed: true),
                       .stopFailed(reason: "x"))
        XCTAssertEqual(MenuBarStatus.derive(from: .paused, stopFailed: true), .paused,
                       "a committed pause has ended the failure")
    }

    /// The words on line 1 and line 2, and the button, per status (spec-shell
    /// S2 with product critique 3, 9 and 10).
    func testEveryStatusHasItsWords() {
        let expected: [(MenuBarStatus, String, String?, String?)] = [
            (.recording, "Remembering", nil, "Pause"),
            (.unchanged, "Remembering", nil, "Pause"),
            (.starting, "Starting…", nil, "Pause"),
            (.noMemory, "Nothing saved yet", nil, "Pause"),
            (.skipping(reason: "ocr-time-secret"), "Skipping this window",
             "It saw what looks like a password or key, so it saved nothing.", "Pause"),
            (.skipping(reason: "failsafe-unknown"), "Skipping this window",
             "It couldn’t tell if this window is private, so it skipped it.", "Pause"),
            (.skipping(reason: "os-blacked-region"), "Skipping this window", "macOS protects this window.", "Pause"),
            (.skipping(reason: "browser_window_unknown"), "Skipping this window",
             "It can’t tell if this browser window is private.", "Pause"),
            (.skipping(reason: "app_identity_unknown"), "Skipping this window", "It can’t tell which app this is.", "Pause"),
            (.skipping(reason: "ax-secure-subrole"), "Skipping this window", "A password field is active.", "Pause"),
            (.paused, "Paused", nil, "Resume"),
            (.idle, "Off", nil, "Turn On"),
            (.needsPermission(.screenRecording), "Needs permission", "Screen Recording is off for Hippocampus.",
             "Open System Settings…"),
            (.blocked(reason: "ingest_failed"), "Not saving", "It can’t save. Check free disk space.", "Try Again"),
            (.stale(reason: "x"), "Not saving", "It can’t confirm anything was saved.", "Try Again"),
            (.error(reason: "x"), "Not saving", "It stopped and couldn’t start again.", "Try Again"),
            (.stopFailed(reason: "x"), "Couldn’t stop", "Hippocampus may still be reading the screen.", "Quit Hippocampus"),
        ]
        for (status, title, detail, action) in expected {
            XCTAssertEqual(status.displayText, title, "\(status)")
            XCTAssertEqual(status.detailText, detail, "\(status)")
            XCTAssertEqual(status.action?.title, action, "\(status)")
        }
    }

    // MARK: - Icon pictures

    #if canImport(AppKit)
    private static let allStatuses: [MenuBarStatus] = [
        .idle, .starting, .recording, .paused, .error(reason: "x"),
        .needsPermission(.screenRecording), .blocked(reason: "x"),
        .stale(reason: "x"), .noMemory, .unchanged,
        .skipping(reason: "secure_input"), .skipping(reason: "secure-event-input"),
        .skipping(reason: "private_browsing"), .skipping(reason: "denylist-source"),
        .skipping(reason: "ax-secure-subrole"), .stopFailed(reason: "x"),
    ]

    /// The indicator may overstate, never understate (RULINGS B1): the dim
    /// and hollow pictures appear only when nothing is read; every state in
    /// which the screen may be read shows the solid dot, a stop that failed
    /// included; a fault that stopped remembering shows h!.
    @MainActor
    func testNoStateInWhichTheScreenMayBeReadShowsLessThanTheSolidDot() {
        let mayRead: [MenuBarStatus] = [
            .recording, .unchanged, .starting, .noMemory, .skipping(reason: "private_browsing"),
            .skipping(reason: "denylist-source"), .skipping(reason: "ax-secure-subrole"),
            .skipping(reason: "ocr-time-secret"), .skipping(reason: "failsafe-unknown"),
            .skipping(reason: "os-blacked-region"), .skipping(reason: "app_identity_unknown"),
            .skipping(reason: "browser_window_unknown"), .skipping(reason: "app_denied"),
            .skipping(reason: "denylist-postcapture"), .stopFailed(reason: "x"),
        ]
        let solid = MenuBarStatusIcon.image(for: HiMark.State.remembering)
        for status in mayRead {
            XCTAssertEqual(status.markState, .remembering, "\(status)")
            XCTAssertTrue(MenuBarStatusIcon.image(for: status) === solid, "\(status)")
        }
        let nothingRead: Set<HiMark.State> = [.off, .skipping]
        for status in Self.allStatuses where nothingRead.contains(status.markState) {
            switch status {
            case .paused, .idle: break
            case .skipping(let code) where ["secure_input", "secure-event-input"].contains(code): break
            default: XCTFail("\(status) shows \(status.markState) while the screen may be read")
            }
        }
        for status in [MenuBarStatus.needsPermission(.automation), .error(reason: "x"), .blocked(reason: "x"),
                       .stale(reason: "x")] {
            XCTAssertEqual(status.markState, .needsYou, "\(status)")
        }
    }

    /// The four pictures must render distinctly. Comparing TIFF bytes is
    /// a cheap snapshot that catches two pictures collapsing into one.
    @MainActor
    func testMenuBarStatusIcon_fourPicturesAreDistinct() throws {
        let states = HiMark.State.allCases
        let tiffs = try states.map { try XCTUnwrap(MenuBarStatusIcon.image(for: $0).tiffRepresentation) }
        for i in 0..<tiffs.count {
            for j in (i + 1)..<tiffs.count {
                XCTAssertNotEqual(tiffs[i], tiffs[j], "\(states[i]) and \(states[j]) must look different")
            }
        }
    }

    @MainActor
    func testMenuBarStatusIcon_reusesImagesAcrossUpdatesAndReasons() {
        for state in Self.allStatuses {
            XCTAssertTrue(MenuBarStatusIcon.image(for: state) === MenuBarStatusIcon.image(for: state))
        }
        XCTAssertTrue(MenuBarStatusIcon.image(for: .error(reason: "x")) === MenuBarStatusIcon.image(for: .error(reason: "y")))
        XCTAssertTrue(MenuBarStatusIcon.image(for: .blocked(reason: "x")) === MenuBarStatusIcon.image(for: .stale(reason: "y")))
    }

    @MainActor
    func testEveryStatusIsATemplateWithOneBitmapPerDisplayScale() {
        let images = Self.allStatuses.map { MenuBarStatusIcon.image(for: $0) }
            + HiMark.State.allCases.map { MenuBarStatusIcon.image(for: $0) }
        for image in images {
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 22, height: 22))
            let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(bitmaps.count, image.representations.count)
            XCTAssertEqual(bitmaps.map(\.pixelsWide).sorted(), [22, 44, 66])
            XCTAssertEqual(bitmaps.map(\.pixelsHigh).sorted(), [22, 44, 66])
            for bitmap in bitmaps {
                XCTAssertEqual(bitmap.size, NSSize(width: 22, height: 22))
            }
        }
    }

    /// Each of these may read the screen, so each shows the solid dot.
    @MainActor
    func testRecordingUnchangedStartingAndNoMemoryShowTheSolidDot() {
        let solid = MenuBarStatusIcon.image(for: HiMark.State.remembering)
        for status in [MenuBarStatus.recording, .unchanged, .starting, .noMemory] {
            XCTAssertEqual(status.markState, .remembering, "\(status)")
            XCTAssertTrue(MenuBarStatusIcon.image(for: status) === solid, "\(status)")
        }
        XCTAssertFalse(MenuBarStatusIcon.image(for: .starting) === MenuBarStatusIcon.image(for: .paused))
    }

    @MainActor
    func testPausedAndOffShareTheDimPictureAndFaultsShowHBang() {
        let dim = MenuBarStatusIcon.image(for: HiMark.State.off)
        XCTAssertTrue(MenuBarStatusIcon.image(for: .paused) === dim)
        XCTAssertTrue(MenuBarStatusIcon.image(for: .idle) === dim)
        let bang = MenuBarStatusIcon.image(for: HiMark.State.needsYou)
        for status in [MenuBarStatus.needsPermission(.accessibility), .error(reason: "x"), .blocked(reason: "x"), .stale(reason: "x")] {
            XCTAssertEqual(status.markState, .needsYou, "\(status)")
            XCTAssertTrue(MenuBarStatusIcon.image(for: status) === bang, "\(status)")
        }
        // Only a password field shows the hollow dot.
        let hollow = MenuBarStatusIcon.image(for: HiMark.State.skipping)
        for status in Self.allStatuses {
            let password: Bool
            if case .skipping(let code) = status { password = ["secure_input", "secure-event-input"].contains(code) }
            else { password = false }
            XCTAssertEqual(MenuBarStatusIcon.image(for: status) === hollow, password, "\(status)")
        }
    }

    /// Stems and the baseline land on whole pixels in every bitmap, so the
    /// letters stay sharp on a 1x display.
    @MainActor
    func testTheHStemAndBaselineLandOnWholePixels() throws {
        for (side, stemLeft, baseline) in [(22, 5, 18), (44, 10, 35), (66, 15, 53)] {
            let alpha = try alphaOf(.remembering, side: side)
            let row = baseline - 3
            XCTAssertGreaterThanOrEqual(alpha(stemLeft, row), 240, "\(side) px: stem's left column")
            XCTAssertEqual(alpha(stemLeft - 1, row), 0, "\(side) px: left of the stem")
            XCTAssertGreaterThanOrEqual(alpha(stemLeft + 1, baseline - 1), 240, "\(side) px: last row above the baseline")
            XCTAssertEqual(alpha(stemLeft + 1, baseline), 0, "\(side) px: below the baseline")
        }
    }

    @MainActor
    func testTheSolidPictureStaysInsideItsColumnsAt2x() throws {
        let alpha = try alphaOf(.remembering, side: 44)
        var columns = Set<Int>()
        for y in 0..<44 {
            for x in 0..<44 where alpha(x, y) >= 128 { columns.insert(x) }
        }
        XCTAssertEqual(columns.min(), 10)
        XCTAssertEqual(columns.max(), 33)
    }

    /// The hollow dot is open in the middle at 1x and 2x; the solid one is not.
    @MainActor
    func testTheHollowDotIsOpenWhereTheSolidDotIsFilled() throws {
        // Above the i (which starts at 8.9 px at 1x) and right of the h.
        for (side, right, above) in [(22, 13, 8), (44, 26, 16)] {
            for (state, filled) in [(HiMark.State.remembering, true), (.skipping, false)] {
                let alpha = try alphaOf(state, side: side)
                var xs: [Int] = [], ys: [Int] = []
                for y in 0..<above {
                    for x in right..<side where alpha(x, y) >= 128 { xs.append(x); ys.append(y) }
                }
                let minX = try XCTUnwrap(xs.min()), maxX = try XCTUnwrap(xs.max())
                let minY = try XCTUnwrap(ys.min()), maxY = try XCTUnwrap(ys.max())
                let middle = [(minX + maxX) / 2, (minX + maxX + 1) / 2].flatMap { x in
                    [(minY + maxY) / 2, (minY + maxY + 1) / 2].map { y in alpha(x, y) }
                }
                if filled {
                    XCTAssertTrue(middle.allSatisfy { $0 >= 240 }, "\(state) at \(side) px: \(middle)")
                } else {
                    XCTAssertTrue(middle.allSatisfy { $0 < 100 }, "\(state) at \(side) px: \(middle)")
                    XCTAssertGreaterThanOrEqual(maxX - minX, 3, "the ring is wider than the hole")
                }
            }
        }
    }

    @MainActor
    func testTheDimPictureHasNoDotAndLettersAtPartStrength() throws {
        let dim = try alphaOf(.off, side: 44)
        let solid = try alphaOf(.remembering, side: 44)
        for y in 0..<16 {
            for x in 26..<44 { XCTAssertEqual(dim(x, y), 0, "no dot at (\(x), \(y))") }
        }
        XCTAssertEqual(Double(dim(11, 30)), 0.55 * 255, accuracy: 3)
        XCTAssertEqual(solid(11, 30), 255)
    }

    @MainActor
    func testHBangPutsAStemWhereTheDotWasAndADotOnTheBaseline() throws {
        let bang = try alphaOf(.needsYou, side: 44)
        // The "!" stem runs from the ascender down through where the i's dot sat.
        for y in 10..<26 { XCTAssertGreaterThanOrEqual(bang(30, y), 250, "stem at row \(y)") }
        // A gap, then the dot resting on the baseline.
        XCTAssertLessThan((26..<35).map { bang(30, $0) }.min() ?? 255, 128)
        XCTAssertGreaterThanOrEqual(bang(30, 33), 250)
    }

    /// Alpha of the `side`-pixel bitmap of a picture; (0, 0) is the top left.
    @MainActor
    private func alphaOf(_ state: HiMark.State, side: Int) throws -> (Int, Int) -> UInt8 {
        let image = MenuBarStatusIcon.image(for: state)
        let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == side })
        let cgImage = try XCTUnwrap(rep.cgImage)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let data = try XCTUnwrap(context.data)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        return { x, y in bytes[(y * side + x) * 4 + 3] }
    }
    #endif
}
