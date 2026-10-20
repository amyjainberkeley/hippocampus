// SPDX-License-Identifier: Apache-2.0
//
// Fn (Globe) as the key that opens Ask (SPEC-DELTA 7): a solo tap only,
// heard from modifier changes alone; its checks before it is taken; never
// taken from another app silently; Shift twice on a keyboard without Fn.
// Every fact is a fake: no test lists this Mac's apps, reads its keyboard
// setting or its keyboards, or installs a monitor.

import Combine
import XCTest
@testable import HippocampusKit

final class FnKeyMonitorTests: XCTestCase {
    private let fn: UInt16 = 63, globe: UInt16 = 179, leftShift: UInt16 = 56, rightCommand: UInt16 = 54
    private let fnBit: UInt = 0x80_0000, lShift: UInt = 0x02, rCmd: UInt = 0x10, capsLock: UInt = 0x1_0000

    // MARK: - A solo tap, from modifier changes alone

    func testATapOfFnByItselfOpensAsk() {
        var detector = SoloKeyDetector(key: .fn)
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 10, atMs: 1_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 10, atMs: 1_110))
        // Again: one tap, one toggle.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 10, atMs: 3_000))
        XCTAssertTrue(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 10, atMs: 3_080))
    }

    func testTheGlobeKeysOwnCodeTapsToo() {
        var detector = SoloKeyDetector(key: .fn)
        XCTAssertFalse(detector.modifiersChanged(keyCode: globe, flags: fnBit, activity: 2, atMs: 500))
        XCTAssertTrue(detector.modifiersChanged(keyCode: globe, flags: 0, activity: 2, atMs: 600))
    }

    func testFnWithTheArrowsOrTheFunctionKeysKeepsWorkingAndNeverOpensAsk() {
        var detector = SoloKeyDetector(key: .fn)
        // Fn+Left (Home): a key went down while Fn was held.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 10, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 11, atMs: 1_090))
        // Fn+F5, however fast.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 11, atMs: 2_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 12, atMs: 2_030))
        // Fn and a click.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 12, atMs: 3_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 13, atMs: 3_060))
    }

    func testHoldingFnIsNotATapSoHoldToTalkNeverOpensAsk() {
        var detector = SoloKeyDetector(key: .fn)
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 5, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 5,
                                                 atMs: 1_000 + SoloKeyDetector.longestTapMs + 1))
    }

    func testFnWithAnotherModifierIsAShortcut() {
        var detector = SoloKeyDetector(key: .fn)
        // Fn then Shift, released in either order.
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 3, atMs: 1_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: fnBit | lShift, activity: 3, atMs: 1_040))
        XCTAssertFalse(detector.modifiersChanged(keyCode: leftShift, flags: fnBit, activity: 3, atMs: 1_080))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: 0, activity: 3, atMs: 1_120))
        // Right ⌘ held, then Fn.
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: rCmd, activity: 3, atMs: 2_000))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: rCmd | fnBit, activity: 3, atMs: 2_030))
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: rCmd, activity: 3, atMs: 2_060))
        XCTAssertFalse(detector.modifiersChanged(keyCode: rightCommand, flags: 0, activity: 3, atMs: 2_100))
    }

    func testCapsLockNeverStopsATap() {
        var detector = SoloKeyDetector(key: .fn)
        XCTAssertFalse(detector.modifiersChanged(keyCode: fn, flags: capsLock | fnBit, activity: 1, atMs: 100))
        XCTAssertTrue(detector.modifiersChanged(keyCode: fn, flags: capsLock, activity: 1, atMs: 180))
    }

    func testOnlyFnOpensAskWhenFnIsTheKeyAndFnNeverOpensItForAnotherKey() {
        var fnDetector = SoloKeyDetector(key: .fn)
        // Shift twice is not Fn.
        for at: UInt64 in [1_000, 1_200] {
            XCTAssertFalse(fnDetector.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 1, atMs: at))
            XCTAssertFalse(fnDetector.modifiersChanged(keyCode: leftShift, flags: 0, activity: 1, atMs: at + 80))
        }
        var shiftDetector = SoloKeyDetector(key: .shiftTwice)
        for at: UInt64 in [5_000, 5_200] {
            XCTAssertFalse(shiftDetector.modifiersChanged(keyCode: fn, flags: fnBit, activity: 1, atMs: at))
            XCTAssertFalse(shiftDetector.modifiersChanged(keyCode: fn, flags: 0, activity: 1, atMs: at + 80))
        }
        // The keys that were offered before behave as they did: Fn's bit
        // counts only for Fn.
        XCTAssertEqual(SoloKeyDetector(key: .shiftTwice).watchedModifiers, 0x207F)
        XCTAssertEqual(SoloKeyDetector(key: .fn).watchedModifiers, 0x207F | 0x80_0000)
    }

    /// The no-keylogging promise: the detector is given a modifier key's
    /// code, the modifier bits, a count of presses and a time, and decides
    /// from those alone. A typed character can't reach it, and nothing it
    /// keeps can say what was typed: a long run of typing and clicking
    /// leaves it exactly as one count would.
    func testTheDetectorNeverSeesOrKeepsWhatIsTyped() {
        var typedALot = SoloKeyDetector(key: .fn)
        var typedOnce = SoloKeyDetector(key: .fn)
        // Shift held for capitals while typing: only the count moves.
        _ = typedALot.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 1, atMs: 100)
        _ = typedALot.modifiersChanged(keyCode: leftShift, flags: 0, activity: 9_000, atMs: 900)
        _ = typedOnce.modifiersChanged(keyCode: leftShift, flags: lShift, activity: 1, atMs: 100)
        _ = typedOnce.modifiersChanged(keyCode: leftShift, flags: 0, activity: 2, atMs: 900)
        XCTAssertEqual(typedALot, typedOnce, "how much was typed leaves no trace")
        XCTAssertEqual(typedALot, SoloKeyDetector(key: .fn), "nothing is kept once the modifiers are up")
        let mirror = Mirror(reflecting: SoloKeyDetector(key: .fn))
        let kept = Set(mirror.children.compactMap(\.label))
        XCTAssertEqual(kept, ["key", "downAtMs", "downActivity", "firstTap"],
                       "a tap's start, a count and a time; never a character or a key list")
    }

    func testTheMonitorHearsModifierChangesOnlyAndReadsNoCharacters() throws {
        let sources = try ["Sources/Hippocampus/SoloKeyMonitor.swift", "Sources/HippocampusKit/FnKeyMonitor.swift",
                           "Sources/HippocampusKit/SoloKeyTrigger.swift", "Sources/HippocampusKit/AskShortcut.swift"]
            .map(source)
        let monitor = sources[0]
        XCTAssertEqual(monitor.components(separatedBy: "matching: .flagsChanged").count - 1, 2,
                       "a global and a local monitor, both of modifier changes")
        for text in sources {
            for reading in [".keyDown)", "matching: .keyDown", "matching: .keyUp", ".characters", "charactersIgnoringModifiers",
                            "CGEvent.tapCreate", "CGEventTapCreate", "IOHIDManagerOpen", "IOHIDDeviceOpen",
                            "IOHIDRequestAccess", "UCKeyTranslate", "keyboardSetUnicodeString"] {
                XCTAssertFalse(text.contains(reading), reading)
            }
        }
        // The one handler passes the code, the bits, a count and a time.
        XCTAssertTrue(monitor.contains("keyCode: event.keyCode,\n            flags: event.modifierFlags.rawValue,"))
        XCTAssertTrue(monitor.contains("activity: Self.activityCount(),"))
        // Keyboards are read from the I/O Registry's properties, never opened.
        XCTAssertTrue(sources[1].contains("IOServiceGetMatchingServices"))
    }

    // MARK: - The checks before Fn is taken

    func testWhatElseUsesFnIsNamed() {
        let wispr = InstalledApp(bundleId: "com.electron.wispr-flow", fileName: "Wispr Flow.app")
        let check = FnKeyCheck(installed: [InstalledApp(bundleId: "com.apple.Safari", fileName: "Safari.app"), wispr],
                               appleFnUsageType: 2, keyboardHasFn: true)
        XCTAssertEqual(check.appsUsingFn, ["Wispr Flow"])
        XCTAssertEqual(check.globeAction, .showEmojiAndSymbols)
        XCTAssertEqual(check.warnings.map(\.text), [
            "Wispr Flow uses Fn. Pick another key, or turn Fn off in Wispr Flow.",
            "macOS uses the Globe key to show Emoji & Symbols.",
        ])
        XCTAssertEqual(check.warnings.map(\.step), [nil, "In Keyboard settings, choose Do Nothing for the Globe key."])
        XCTAssertEqual(check.conflictTokens, ["app:Wispr Flow", "globe"])
        XCTAssertEqual(FnKeyCheck(installed: [InstalledApp(bundleId: nil, fileName: "Willow Voice.app")],
                                  appleFnUsageType: 0, keyboardHasFn: true).appsUsingFn, ["Willow Voice"])
        XCTAssertEqual(FnKeyMonitor.knownApps.map(\.name), ["Wispr Flow", "Superwhisper", "VoiceInk", "Willow Voice"])
    }

    func testMacOSsGlobeSettingIsReadAsItIsStored() {
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 0), .doNothing)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 2), .showEmojiAndSymbols)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 3), .startDictation)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: nil), .macOSDefault)
        XCTAssertEqual(KeyboardSettingsLink.url.absoluteString,
                       "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    func testWhatListensWhenFnIsChosen() {
        let wispr = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow"], globeAction: .doNothing)
        XCTAssertEqual(FnKeyCheck.clear.listeningKey(accepted: []), .fn)
        XCTAssertEqual(wispr.listeningKey(accepted: []), .shiftTwice, "never taken silently")
        XCTAssertEqual(wispr.listeningKey(accepted: ["app:Wispr Flow"]), .fn, "after Use Fn")
        let noKey = FnKeyCheck(hasFnKey: false, appsUsingFn: [], globeAction: .doNothing)
        XCTAssertEqual(noKey.listeningKey(accepted: []), .shiftTwice, "a keyboard without Fn falls back")
    }

    // MARK: - The watch

    @MainActor
    private final class Rig {
        var trusted = true
        var check = FnKeyCheck.clear
        var installs: [SoloKey] = []
        var uninstalls = 0

        lazy var hooks = AskKeyWatch.Hooks(
            isTrusted: { [unowned self] in self.trusted },
            install: { [unowned self] key in
                self.installs.append(key)
                return true
            },
            uninstall: { [unowned self] in self.uninstalls += 1 },
            after: { _, _ in AnyCancellable {} },
            fnCheck: { [unowned self] in self.check }
        )
    }

    @MainActor
    func testFnListensWhenNothingElseUsesIt() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        XCTAssertEqual(rig.installs, [.fn])
        XCTAssertEqual(watch.listeningKey, .fn)
        XCTAssertEqual(watch.label, "fn")
        XCTAssertEqual(watch.phrase, "Tap Fn")
        XCTAssertEqual(watch.caption.text, "Tap Fn by itself. Fn with arrows and function keys keeps working.")
        XCTAssertEqual(watch.caption.secondLine, "⌃⇧Space also works.")
        XCTAssertTrue(watch.caption.fnWarnings.isEmpty)
        XCTAssertFalse(watch.caption.offersUseFn)
    }

    @MainActor
    func testWithAnAppUsingFnShiftTwiceListensUntilUseFn() throws {
        let suite = "fn-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = Rig()
        rig.check = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow"], globeAction: .doNothing)
        let watch = AskKeyWatch(hooks: rig.hooks, defaults: defaults)
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        XCTAssertEqual(watch.key, .fn, "the choice is kept")
        XCTAssertEqual(rig.installs, [.shiftTwice], "Fn is not taken from Wispr Flow silently")
        XCTAssertEqual(watch.label, "⇧⇧", "every place names what works")
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectivePhraseKey), "Press Shift twice")
        let caption = watch.caption
        XCTAssertEqual(caption.fnWarnings, [.apps(["Wispr Flow"])])
        XCTAssertTrue(caption.offersUseFn)
        XCTAssertEqual(caption.text, "Until you click Use Fn, Shift twice opens Ask.")

        // Use Fn: the person's own click.
        watch.acceptFn()
        XCTAssertEqual(rig.installs, [.shiftTwice, .fn])
        XCTAssertEqual(watch.label, "fn")
        XCTAssertEqual(defaults.string(forKey: FnKeyMonitor.acceptedKey), "app:Wispr Flow")
        XCTAssertFalse(watch.caption.offersUseFn)

        // Kept: a new watch, as at the next launch, takes Fn at once.
        let next = Rig()
        next.check = rig.check
        let relaunched = AskKeyWatch(hooks: next.hooks, defaults: defaults)
        relaunched.start(key: .fn)
        XCTAssertEqual(next.installs, [.fn])

        // A new conflict asks again: macOS's Globe setting changed.
        rig.check = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow"], globeAction: .startDictation)
        watch.recheck()
        XCTAssertEqual(watch.listeningKey, .shiftTwice)
        XCTAssertEqual(rig.installs.last, .shiftTwice)
        XCTAssertEqual(watch.caption.fnWarnings, [.apps(["Wispr Flow"]), .globe(.startDictation)])
        // Set to Do Nothing in Keyboard settings: Fn again, with no click.
        rig.check = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Wispr Flow"], globeAction: .doNothing)
        watch.recheck()
        XCTAssertEqual(watch.listeningKey, .fn)
    }

    @MainActor
    func testAKeyboardWithoutFnFallsBackToShiftTwiceWithANote() {
        let rig = Rig()
        rig.check = FnKeyCheck(hasFnKey: false, appsUsingFn: [], globeAction: .doNothing)
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        XCTAssertEqual(rig.installs, [.shiftTwice])
        XCTAssertEqual(watch.caption.text, "This keyboard has no Fn key, so Shift twice opens Ask.")
        XCTAssertFalse(watch.caption.offersUseFn, "nothing to take from anyone")
        // A keyboard with Fn connected: Fn listens.
        rig.check = .clear
        watch.recheck()
        XCTAssertEqual(rig.installs, [.shiftTwice, .fn])
        XCTAssertEqual(rig.uninstalls, 1)
    }

    @MainActor
    func testAFnPressSeenTeachesThatAKeyboardHasFn() {
        // The keyboard list said no Fn, but Fn went down: a keyboard here
        // has it after all, and Fn listens from then on.
        let rig = Rig()
        rig.check = FnKeyCheck(hasFnKey: false, appsUsingFn: [], globeAction: .doNothing)
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        XCTAssertEqual(watch.listeningKey, .shiftTwice)
        watch.noticedFnKey()
        XCTAssertTrue(watch.fnKeyNoticed)
        XCTAssertEqual(watch.listeningKey, .fn)
        XCTAssertEqual(rig.installs, [.shiftTwice, .fn])
        XCTAssertEqual(watch.caption.text, "Tap Fn by itself. Fn with arrows and function keys keeps working.")
        // Still never over another app without Use Fn.
        rig.check = FnKeyCheck(hasFnKey: false, appsUsingFn: ["Wispr Flow"], globeAction: .doNothing)
        watch.recheck()
        XCTAssertEqual(watch.listeningKey, .shiftTwice)
        XCTAssertTrue(watch.caption.offersUseFn)
    }

    @MainActor
    func testTheMonitorLearnsFnFromAModifierChangeOnly() throws {
        let monitor = try source("Sources/Hippocampus/SoloKeyMonitor.swift")
        XCTAssertTrue(monitor.contains("FnKeyMonitor.keyCodes.contains(event.keyCode),"))
        XCTAssertTrue(monitor.contains("event.modifierFlags.rawValue & FnKeyMonitor.functionMask != 0 {\n            watch.noticedFnKey()"))
    }

    @MainActor
    func testAnotherKeyNeverReadsFnsChecks() {
        let rig = Rig()
        var reads = 0
        rig.hooks.fnCheck = {
            reads += 1
            return .clear
        }
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        watch.recheck()
        XCTAssertEqual(reads, 0)
        XCTAssertNil(watch.fnCheck)
    }

    @MainActor
    func testWithoutAccessibilityFnSaysWhatItNeedsAndWhatElseUsesIt() {
        let rig = Rig()
        rig.trusted = false
        rig.check = FnKeyCheck(hasFnKey: true, appsUsingFn: ["Superwhisper"], globeAction: .doNothing)
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.setFallbackRegistered(true)
        watch.start(key: .fn)
        let caption = watch.caption
        XCTAssertTrue(caption.needsAccessibility)
        XCTAssertTrue(caption.text.contains("Hippocampus sees that Fn was tapped, never what you type."))
        XCTAssertEqual(caption.fnWarnings, [.apps(["Superwhisper"])])
        XCTAssertTrue(rig.installs.isEmpty)
    }

    @MainActor
    func testSetupsChoiceIsHeardAtOnceAndPreferencesTakesIt() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        watch.setupChose(.fn)
        XCTAssertEqual(watch.key, .fn)
        XCTAssertEqual(watch.chosenInSetup, .fn)
        XCTAssertEqual(rig.installs, [.shiftTwice, .fn])
        watch.adoptedSetupChoice()
        XCTAssertNil(watch.chosenInSetup)
    }

    // MARK: - Reading this Mac, in a folder the test makes

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    @MainActor
    func testTheAppsFolderIsReadAtMostOnceAMinute() {
        let reads = Reads()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let facts = FnKeyFacts(
            installedApps: {
                reads.add()
                return [InstalledApp(bundleId: "com.electron.wispr-flow", fileName: "Wispr Flow.app")]
            },
            appleFnUsageType: { 0 }, keyboardHasFn: { true }
        )
        let checker = FnKeyChecker(facts: facts, now: { now })
        XCTAssertEqual(checker.check().appsUsingFn, ["Wispr Flow"])
        now += 30
        _ = checker.check()
        XCTAssertEqual(reads.value, 1, "the two-second poll doesn't list the folders")
        now += 31
        _ = checker.check()
        XCTAssertEqual(reads.value, 2)
        checker.forget()
        _ = checker.check()
        XCTAssertEqual(reads.value, 3, "setup's choice reads them again")
    }

    func testInstalledAppsComeFromTheFolderListingAndInfoPlistOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fn-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = folder.appendingPathComponent("superwhisper.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.superduper.superwhisper"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        let apps = FnKeyMacFacts.installedApps(in: [folder])
        XCTAssertEqual(apps, [InstalledApp(bundleId: "com.superduper.superwhisper", fileName: "superwhisper.app")])
        XCTAssertEqual(FnKeyCheck(installed: apps, appleFnUsageType: 0, keyboardHasFn: true).appsUsingFn, ["Superwhisper"])
        XCTAssertEqual(FnKeyMacFacts.applicationFolders(home: URL(fileURLWithPath: "/Users/sam")).map(\.path),
                       ["/Applications", "/Users/sam/Applications"])
    }

    func testABuiltInOrAppleKeyboardHasFn() {
        XCTAssertTrue(FnKeyMacFacts.Keyboard(builtIn: true, vendorId: nil).hasFn)
        XCTAssertTrue(FnKeyMacFacts.Keyboard(builtIn: false, vendorId: 0x05AC).hasFn)
        XCTAssertTrue(FnKeyMacFacts.Keyboard(builtIn: false, vendorId: 0x004C).hasFn)
        XCTAssertFalse(FnKeyMacFacts.Keyboard(builtIn: false, vendorId: 0x046D).hasFn)
        let other = FnKeyMacFacts.Keyboard(builtIn: false, vendorId: 0x046D)
        XCTAssertFalse(FnKeyMacFacts.hasFn([other]), "only another maker's keyboard")
        XCTAssertTrue(FnKeyMacFacts.hasFn([other, FnKeyMacFacts.Keyboard(builtIn: true, vendorId: nil)]))
        XCTAssertTrue(FnKeyMacFacts.hasFn([]), "an empty list can't say: Fn isn't refused on a guess")
    }

    // MARK: - Where it is kept, and Fn offered (moved from SeamWiringTests)

    func testFnIsOfferedWithItsChecksAndItsMaskIsTheFunctionKey() {
        XCTAssertTrue(FnKeyMonitor.isOffered)
        XCTAssertEqual(FnKeyMonitor.functionMask, 0x80_0000, "NSEvent.ModifierFlags.function")
        XCTAssertEqual(FnKeyMonitor.keyCodes, [63, 179])
        XCTAssertTrue(SoloKey.allCases.map(\.rawValue).contains("fn"), "Fn joins the choices with its checks")
        XCTAssertEqual(SoloKey.allCases.first, .shiftTwice, "Shift twice stays the default and first")
    }

    @MainActor
    func testTheKeysSetupWritesAreTheAppsOwn() {
        XCTAssertEqual(FnKeyMonitor.preferenceKey, PreferencesStore.Keys.askKey)
        XCTAssertEqual(FnKeyMonitor.acceptedKey, "ai.hippocampus.prefs.askKeyFnAccepted")
        XCTAssertEqual(FnKeyMonitor.setupChoseNotification.rawValue, "ai.hippocampus.setup.askKeyChosen")
        XCTAssertEqual(FnKeyMonitor.acceptedValue(["globe", "app:Wispr Flow"]), "app:Wispr Flow,globe")
        XCTAssertEqual(FnKeyMonitor.accepted(from: "app:Wispr Flow,globe"), ["app:Wispr Flow", "globe"])
        XCTAssertEqual(FnKeyMonitor.accepted(from: nil), [])
    }

    // MARK: - The words

    func testTheWordsFollowTheLaunchCopyRules() {
        var strings = [AskKeyCopy.fnHowTo, AskKeyCopy.noFnKey, AskKeyCopy.untilUseFn, AskKeyCopy.useFn,
                       AskKeyCopy.openKeyboardSettings, AskKeyCopy.globeStep,
                       AskKeyCopy.appsUseFn(["Wispr Flow"]), AskKeyCopy.appsUseFn(["Wispr Flow", "Superwhisper"]),
                       AskKeyCopy.appsUseFn(["Wispr Flow", "Superwhisper", "VoiceInk"])]
        strings += [GlobeKeyAction.doNothing, .changeInputSource, .showEmojiAndSymbols, .startDictation, .macOSDefault]
            .map(AskKeyCopy.globeUsesFn)
        strings += SoloKey.allCases.map(\.label)
        XCTAssertEqual(AskKeyCopy.appsUseFn(["Wispr Flow"]),
                       "Wispr Flow uses Fn. Pick another key, or turn Fn off in Wispr Flow.", "SPEC-DELTA 7, word for word")
        let banned = ["seamless", "smart", "simply", "magic", "powerful", "monitor", "track", "keylog", "record",
                      "captured", "unlock", "just"]
        for string in strings {
            let words = Set(string.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            for word in banned { XCTAssertFalse(words.contains(word), "\(word) in \(string)") }
            for mark in ["!", "—", ";", "'", "\""] { XCTAssertFalse(string.contains(mark), "\(mark) in \(string)") }
            XCTAssertFalse(string.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "no emoji: \(string)")
            for sentence in string.components(separatedBy: ".") {
                XCTAssertLessThanOrEqual(sentence.split(whereSeparator: \.isWhitespace).count, 12, sentence)
            }
        }
    }

    private func source(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }
}
