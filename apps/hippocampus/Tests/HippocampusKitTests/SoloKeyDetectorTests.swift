import XCTest
@testable import HippocampusKit

final class SoloKeyDetectorTests: XCTestCase {
    private let rightCommand: UInt16 = 54, leftCommand: UInt16 = 55, rightOption: UInt16 = 61
    private let leftShift: UInt16 = 56, rightShift: UInt16 = 60
    private let rCmd: UInt = 0x10, lCmd: UInt = 0x08, rOpt: UInt = 0x40, lShift: UInt = 0x02, rShift: UInt = 0x04

    func testTappingTheKeyByItselfOpensAsk() {
        var detector = SoloKeyDetector(key: .rightCommand)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 10, atMs: 1_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 10, atMs: 1_120))
        // And again: one tap, one toggle.
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 10, atMs: 3_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 10, atMs: 3_090))
    }

    func testAShortcutThatUsesTheKeyIsNeverATapHoweverFast() {
        var detector = SoloKeyDetector(key: .rightCommand)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 10, atMs: 1_000))
        // ⌘C: one key was pressed while it was down.
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 11, atMs: 1_060))
        // ⌘-click.
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 11, atMs: 2_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 12, atMs: 2_050))
    }

    func testHoldingTheKeyIsNotATap() {
        var detector = SoloKeyDetector(key: .rightCommand)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 10, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 10, atMs: 1_000 + SoloKeyDetector.longestTapMs + 1))
    }

    func testAnotherModifierHeldMakesItAShortcut() {
        var detector = SoloKeyDetector(key: .rightCommand)
        // ⇧ then right ⌘, released in either order.
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 10, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: lShift | rCmd, activity: 10, atMs: 1_050))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: lShift, activity: 10, atMs: 1_100))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: 0, activity: 10, atMs: 1_150))
        // Right ⌘ first, then ⌥ joins before it is released.
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 10, atMs: 2_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightOption, flags: rCmd | rOpt, activity: 10, atMs: 2_040))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightOption, flags: rCmd, activity: 10, atMs: 2_080))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 10, atMs: 2_120))
    }

    func testTheOtherCommandKeyDoesNothing() {
        var detector = SoloKeyDetector(key: .rightCommand)
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftCommand, flags: lCmd, activity: 10, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftCommand, flags: 0, activity: 10, atMs: 1_080))
    }

    func testRightOptionCanBeTheKey() {
        var detector = SoloKeyDetector(key: .rightOption)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightOption, flags: rOpt, activity: 4, atMs: 500))
        XCTAssertTrue(detector.modifiersChanged(keyCode: rightOption, flags: 0, activity: 4, atMs: 600))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 4, atMs: 900))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 4, atMs: 980))
    }

    func testShiftTwiceNeedsTwoQuickCleanTaps() {
        var detector = SoloKeyDetector(key: .shiftTwice)
        func tap(_ code: UInt16, _ flag: UInt, at ms: UInt64, activity: UInt64 = 7) -> Bool {
            _ = detector.modifiersChanged(keyCode: code, flags: flag, activity: activity, atMs: ms)
            return detector.modifiersChanged(keyCode: code, flags: 0, activity: activity, atMs: ms + 80)
        }
        XCTAssertFalse(tap(leftShift, lShift, at: 1_000))
        XCTAssertTrue(tap(leftShift, lShift, at: 1_250), "second tap within the gap")
        // Too slow: two separate taps.
        XCTAssertFalse(tap(rightShift, rShift, at: 5_000))
        XCTAssertFalse(tap(rightShift, rShift, at: 5_000 + SoloKeyDetector.doubleTapGapMs + 200))
        // Typing between the taps (a capital letter, then another).
        XCTAssertFalse(tap(leftShift, lShift, at: 9_000, activity: 20))
        XCTAssertFalse(tap(leftShift, lShift, at: 9_200, activity: 21))
    }

    func testOffNeverFires() {
        var detector = SoloKeyDetector(key: .off)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 1, atMs: 100))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 1, atMs: 150))
    }

    func testRightShiftAloneOpensAskWithOneTap() {
        var detector = SoloKeyDetector(key: .rightShift)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightShift, flags: rShift, activity: 3, atMs: 1_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: rightShift, flags: 0, activity: 3, atMs: 1_090))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightShift, flags: rShift, activity: 3, atMs: 2_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: rightShift, flags: 0, activity: 3, atMs: 2_070))
    }

    func testLeftShiftDoesNothingWhenRightShiftIsTheKey() {
        var detector = SoloKeyDetector(key: .rightShift)
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 3, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: 0, activity: 3, atMs: 1_080))
        // Twice, quickly: still nothing.
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 3, atMs: 1_200))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: 0, activity: 3, atMs: 1_260))
    }

    func testACapitalTypedWithRightShiftIsNotATap() {
        var detector = SoloKeyDetector(key: .rightShift)
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightShift, flags: rShift, activity: 3, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightShift, flags: 0, activity: 4, atMs: 1_100))
    }

    func testEveryKeyHasItsNamesInTheOrderTheyAreOffered() {
        // Fn (Globe) is offered second, after the default (SPEC-DELTA 7); the
        // raw values the app has stored for the others never change.
        XCTAssertEqual(SoloKey.allCases, [.shiftTwice, .fn, .rightShift, .rightCommand, .rightOption, .off])
        XCTAssertEqual(SoloKey.allCases.map(\.rawValue),
                       ["shiftTwice", "fn", "rightShift", "rightCommand", "rightOption", "off"])
        XCTAssertEqual(SoloKey.allCases.map(\.shortcutLabel), ["⇧⇧", "fn", "right ⇧", "right ⌘", "right ⌥", nil])
        XCTAssertEqual(
            SoloKey.allCases.map(\.phrase),
            ["Press Shift twice", "Tap Fn", "Tap right Shift", "Tap right ⌘", "Tap right ⌥", nil]
        )
    }

    // MARK: Fn+F-keys keep working (SPEC-DELTA 7)

    /// With "Use F1, F2, etc. keys as standard function keys" on, Fn+F11
    /// sends its volume change as a system-defined event, not a key press.
    /// The count of what happens while the key is down holds that event, so
    /// a quick Fn+F11 is not a tap of Fn alone and never opens Ask.
    func testAFunctionKeysOwnActionWhileFnIsDownIsNotATap() {
        XCTAssertTrue(SoloKeyDetector.activityEventTypes.contains(14), "a system-defined event (NX_SYSDEFINED) counts")
        let fn: UInt16 = 63, fnBit: UInt = 0x80_0000
        var detector = SoloKeyDetector(key: .fn)
        // Fn down; F11 sends one system-defined event; Fn up, 90 ms later.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 40, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 41, atMs: 1_090))
        // Fn alone still opens Ask.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 41, atMs: 3_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 41, atMs: 3_080))
    }

    /// The no-keylogging promise holds for what is counted: only that an
    /// event of one of these types happened, never which key or what it
    /// typed. The list is of event types, and the monitor reads nothing but
    /// the system's running count of each.
    func testOnlyCountsOfEventTypesAreReadNeverKeysOrCharacters() throws {
        XCTAssertEqual(SoloKeyDetector.activityEventTypes, [10, 1, 3, 25, 22, 14],
                       "a key pressed, the three clicks, a scroll and a function key's own action")
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let monitor = try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/SoloKeyMonitor.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(monitor.contains("SoloKeyDetector.activityEventTypes.compactMap(CGEventType.init(rawValue:))"))
        XCTAssertTrue(monitor.contains("CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)"))
        for reading in ["matching: .systemDefined", ".systemDefined)", "data1", "data2", "subtype", "keyCode: Int",
                        "NSEvent.addGlobalMonitorForEvents(matching: .keyDown", "CGEvent.tapCreate"] {
            XCTAssertFalse(monitor.contains(reading), reading)
        }
    }

    @MainActor
    func testEveryChoiceHasALabelAndTheChoiceIsRemembered() throws {
        XCTAssertEqual(SoloKey.allCases.map(\.label), ["Shift twice", "Fn (Globe)", "Right Shift", "Right ⌘", "Right ⌥", "Off"])
        let suite = "solo-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let retention = FileManager.default.temporaryDirectory
            .appendingPathComponent("solo-key-\(UUID().uuidString)").appendingPathComponent("retention.json")
        let store = PreferencesStore(defaults: defaults, retentionURL: retention)
        XCTAssertEqual(store.askKey, .shiftTwice, "Shift twice unless the person chose otherwise")
        XCTAssertNil(defaults.object(forKey: PreferencesStore.Keys.askKey), "the default is never written")
        store.askKey = .rightCommand
        XCTAssertEqual(PreferencesStore(defaults: defaults, retentionURL: retention).askKey, .rightCommand,
                       "a stored choice is kept")
        store.askKey = .rightShift
        XCTAssertEqual(defaults.string(forKey: PreferencesStore.Keys.askKey), "rightShift")
        XCTAssertEqual(PreferencesStore(defaults: defaults, retentionURL: retention).askKey, .rightShift)
        defaults.set("capsLock", forKey: PreferencesStore.Keys.askKey)
        XCTAssertEqual(PreferencesStore(defaults: defaults, retentionURL: retention).askKey, .shiftTwice)
        store.askKey = .fn
        XCTAssertEqual(defaults.string(forKey: PreferencesStore.Keys.askKey), "fn")
        XCTAssertEqual(PreferencesStore(defaults: defaults, retentionURL: retention).askKey, .fn)
    }
}
