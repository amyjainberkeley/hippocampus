import XCTest
@testable import OnboardingKit

/// Setup's key picker (SPEC-DELTA 7): Shift twice stays the default; Fn
/// (Globe) is offered with what else uses Fn said before it is taken, and
/// is never taken from another app silently. Every fact is a fake: no test
/// lists this Mac's apps, reads its keyboard setting or its keyboards.
@MainActor
final class AskKeyChoiceTests: XCTestCase {
    private func facts(apps: [InstalledApp] = [], globe: Int? = 0, keyboardHasFn: Bool = true) -> FnKeyFacts {
        FnKeyFacts(installedApps: { apps }, appleFnUsageType: { globe }, keyboardHasFn: { keyboardHasFn })
    }

    private let wispr = InstalledApp(bundleId: "com.electron.wispr-flow", fileName: "Wispr Flow.app")
    private let superwhisper = InstalledApp(bundleId: "com.superduper.superwhisper", fileName: "superwhisper.app")

    // MARK: - The choices

    func testSetupOffersShiftTwiceThenFnAndShiftTwiceIsTheDefault() {
        XCTAssertEqual(SetupAskKey.allCases, [.shiftTwice, .fn])
        XCTAssertEqual(SetupAskKey.allCases.map(\.label), ["Shift twice", "Fn (Globe)"])
        XCTAssertEqual(SetupAskKey.allCases.map(\.rawValue), ["shiftTwice", "fn"], "the app's own stored names")
        XCTAssertEqual(SetupAskKey(stored: nil), .shiftTwice, "nothing stored is Shift twice")
        XCTAssertEqual(SetupAskKey(stored: "fn"), .fn)
        XCTAssertNil(SetupAskKey(stored: "rightCommand"), "a key only Preferences offers")
        XCTAssertNil(SetupAskKey(stored: "off"))
        XCTAssertEqual(SetupAskKey(stored: "capsLock"), .shiftTwice, "a value the app reads as Shift twice")
        XCTAssertEqual(SetupAskKey.shiftTwice.line, "Press either Shift twice. It works on every keyboard.")
        XCTAssertEqual(SetupAskKey.fn.line, "Tap Fn by itself. Fn with arrows and function keys keeps working.")
        XCTAssertEqual(SetupAskKey.fn.hint, .fn)
    }

    // MARK: - macOS's Globe key setting

    func testTheGlobeSettingIsReadAsMacOSStoresIt() {
        // com.apple.HIToolbox AppleFnUsageType, "Press Globe key to".
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 0), .doNothing)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 1), .changeInputSource)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 2), .showEmojiAndSymbols)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 3), .startDictation)
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: nil), .macOSDefault, "never set: macOS uses it")
        XCTAssertEqual(GlobeKeyAction(appleFnUsageType: 9), .macOSDefault)
    }

    // MARK: - What else uses Fn

    func testAKnownFnAppIsFoundByItsBundleIdAndNamed() {
        let check = facts(apps: [InstalledApp(bundleId: "com.apple.Safari", fileName: "Safari.app"), wispr]).check()
        XCTAssertEqual(check.appsUsingFn, ["Wispr Flow"])
        XCTAssertEqual(check.notes, [.apps(["Wispr Flow"])])
        XCTAssertEqual(check.notes.first?.text, "Wispr Flow uses Fn. Pick another key, or turn Fn off in Wispr Flow.")
        XCTAssertTrue(check.notes.first?.isWarning == true)
        // Case doesn't matter, and an app renamed on disk still counts.
        let renamed = InstalledApp(bundleId: "COM.ELECTRON.WISPR-FLOW", fileName: "Flow.app")
        XCTAssertEqual(facts(apps: [renamed]).check().appsUsingFn, ["Wispr Flow"])
    }

    func testAnAppWithoutAPublishedIdIsFoundByItsBundleName() {
        let willow = InstalledApp(bundleId: "com.example.unknown", fileName: "Willow Voice.app")
        XCTAssertEqual(facts(apps: [willow]).check().appsUsingFn, ["Willow Voice"])
        let other = InstalledApp(bundleId: "com.example.notes", fileName: "Willowby.app")
        XCTAssertEqual(facts(apps: [other]).check().appsUsingFn, [])
    }

    func testSeveralAppsAreNamedTogether() {
        let voiceInk = InstalledApp(bundleId: "com.prakashjoshipax.VoiceInk", fileName: "VoiceInk.app")
        XCTAssertEqual(facts(apps: [superwhisper, wispr]).check().notes.first?.text,
                       "Wispr Flow and Superwhisper use Fn. Pick another key, or turn Fn off in both.",
                       "in the known list's order")
        XCTAssertEqual(facts(apps: [voiceInk, superwhisper, wispr]).check().notes.first?.text,
                       "Wispr Flow, Superwhisper and VoiceInk use Fn. Pick another key, or turn Fn off in each.")
    }

    func testTheKnownAppsAreTheAppsOwnList() throws {
        // The app checks again when it starts and in Preferences; both
        // sides must name the same apps the same way.
        let monitor = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "apps/hippocampus/Sources/HippocampusKit/FnKeyMonitor.swift"), encoding: .utf8)
        for app in FnApp.known {
            XCTAssertTrue(monitor.contains("\"\(app.name)\""), app.name)
            for id in app.bundleIds { XCTAssertTrue(monitor.contains("\"\(id)\""), id) }
            for name in app.bundleNames { XCTAssertTrue(monitor.contains("\"\(name)\""), name) }
        }
        XCTAssertEqual(FnApp.known.map(\.name), ["Wispr Flow", "Superwhisper", "VoiceInk", "Willow Voice"])
    }

    func testMacOSsOwnGlobeSettingGetsTheExactStep() {
        let emoji = facts(globe: 2).check()
        XCTAssertEqual(emoji.notes, [.globe(.showEmojiAndSymbols)])
        XCTAssertEqual(emoji.notes.first?.text, "macOS uses the Globe key to show Emoji & Symbols.")
        XCTAssertEqual(emoji.notes.first?.step, "In Keyboard settings, choose Do Nothing for the Globe key.")
        XCTAssertEqual(OnboardingCopy.AskKey.globeUsesFn(.changeInputSource),
                       "macOS uses the Globe key to change the input source.")
        XCTAssertEqual(OnboardingCopy.AskKey.globeUsesFn(.startDictation), "macOS uses the Globe key to start Dictation.")
        XCTAssertEqual(facts(globe: nil).check().notes, [.globe(.macOSDefault)])
        XCTAssertEqual(OnboardingCopy.AskKey.globeUsesFn(.macOSDefault), "macOS uses the Globe key for its own shortcut.")
        XCTAssertTrue(facts(globe: 0).check().notes.isEmpty, "Do Nothing leaves Fn free")
        XCTAssertEqual(KeyboardSettingsLink.url.absoluteString,
                       "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    func testAKeyboardWithoutFnFallsBackToShiftTwiceWithANote() {
        let check = facts(keyboardHasFn: false).check()
        XCTAssertFalse(check.hasFnKey)
        XCTAssertEqual(check.notes, [.noFnKey])
        XCTAssertEqual(check.notes.first?.text, "This keyboard has no Fn key, so Shift twice opens Ask.")
        XCTAssertFalse(check.notes.first?.isWarning ?? true, "a note, not a warning")
        XCTAssertFalse(check.needsConfirmation(accepted: []), "nothing is taken from anyone")
    }

    func testTheNotesComeInOrderAppsThenMacOSThenTheKeyboard() {
        XCTAssertEqual(facts(apps: [wispr], globe: 1, keyboardHasFn: false).check().notes,
                       [.apps(["Wispr Flow"]), .globe(.changeInputSource), .noFnKey])
    }

    func testOnlyANewConflictAsksAgain() {
        let both = facts(apps: [wispr], globe: 2).check()
        XCTAssertEqual(both.conflictTokens, ["app:Wispr Flow", "globe"])
        XCTAssertTrue(both.needsConfirmation(accepted: []))
        XCTAssertFalse(both.needsConfirmation(accepted: ["app:Wispr Flow", "globe"]))
        XCTAssertTrue(both.needsConfirmation(accepted: ["globe"]), "Wispr Flow was not accepted")
        // Fewer conflicts than accepted never ask again.
        XCTAssertFalse(facts(apps: [wispr]).check().needsConfirmation(accepted: ["app:Wispr Flow", "globe"]))
        XCTAssertFalse(FnKeyCheck.clear.needsConfirmation(accepted: []))
    }

    // MARK: - The picker

    func testFnIsNeverTakenSilentlyFromAnApp() {
        let picker = AskKeyPickerModel(stored: nil, facts: facts(apps: [wispr]), accepted: [])
        XCTAssertEqual(picker.selection, .shiftTwice)
        XCTAssertTrue(picker.notes.isEmpty, "nothing about Fn until Fn is picked")
        XCTAssertEqual(picker.confirmLabel, "Done")
        picker.selection = .fn
        XCTAssertEqual(picker.notes, [.apps(["Wispr Flow"])], "said before it is taken")
        XCTAssertTrue(picker.needsConfirmation)
        XCTAssertEqual(picker.confirmLabel, "Use Fn", "taking it is the person's own click")
        var written: [(SetupAskKey, Set<String>)] = []
        picker.confirm { written.append(($0, $1)) }
        XCTAssertEqual(written.map(\.0), [.fn])
        XCTAssertEqual(written.first?.1, ["app:Wispr Flow"], "what was accepted is kept")
    }

    func testFnWithNothingElseUsingItIsDone() {
        let picker = AskKeyPickerModel(stored: nil, facts: facts(), accepted: [])
        picker.selection = .fn
        XCTAssertTrue(picker.notes.isEmpty)
        XCTAssertFalse(picker.needsConfirmation)
        XCTAssertEqual(picker.confirmLabel, "Done")
        var written: [(SetupAskKey, Set<String>)] = []
        picker.confirm { written.append(($0, $1)) }
        XCTAssertEqual(written.map(\.0), [.fn])
        XCTAssertEqual(written.first?.1, [], "nothing to accept")
    }

    func testCancelOrNoChangeWritesNothing() {
        var writes = 0
        let same = AskKeyPickerModel(stored: "fn", facts: facts(), accepted: [])
        XCTAssertEqual(same.selection, .fn, "the stored key is picked")
        same.confirm { _, _ in writes += 1 }
        XCTAssertEqual(writes, 0, "Done on the stored key changes nothing")
        // Accepted before: no second confirmation, no second write.
        let accepted = AskKeyPickerModel(stored: "fn", facts: facts(apps: [wispr]), accepted: ["app:Wispr Flow"])
        XCTAssertFalse(accepted.needsConfirmation)
        accepted.confirm { _, _ in writes += 1 }
        XCTAssertEqual(writes, 0)
    }

    func testAKeyOnlyPreferencesOffersIsKeptUnlessTheyPickOne() {
        let picker = AskKeyPickerModel(stored: "rightCommand", facts: facts(), accepted: [])
        XCTAssertNil(picker.selection, "neither card is picked for right ⌘")
        var written: [SetupAskKey] = []
        picker.confirm { key, _ in written.append(key) }
        XCTAssertEqual(written, [], "Done keeps right ⌘")
        picker.selection = .shiftTwice
        picker.confirm { key, _ in written.append(key) }
        XCTAssertEqual(written, [.shiftTwice])
    }

    func testComingBackFromKeyboardSettingsReadsTheSettingAgain() {
        let globe = MainBox<Int?>(2)
        let picker = AskKeyPickerModel(
            stored: nil,
            facts: FnKeyFacts(installedApps: { [] }, appleFnUsageType: { MainActor.assumeIsolated { globe.value } },
                              keyboardHasFn: { true }),
            accepted: []
        )
        picker.selection = .fn
        XCTAssertTrue(picker.needsConfirmation)
        globe.value = 0
        picker.recheck()
        XCTAssertFalse(picker.needsConfirmation, "set to Do Nothing: Fn is free")
        XCTAssertEqual(picker.confirmLabel, "Done")
    }

    // MARK: - Writing the choice

    func testTheChoiceGoesWhereTheAppKeepsItAndTheAppIsTold() {
        var defaults: [String: String?] = [:]
        var posts = 0
        SetupAskKeyWriter.choose(.fn, accepting: ["globe", "app:Wispr Flow"], set: { defaults[$0] = $1 }, post: { posts += 1 })
        XCTAssertEqual(defaults["ai.hippocampus.prefs.askKey"], "fn")
        XCTAssertEqual(defaults["ai.hippocampus.prefs.askKeyFnAccepted"], "app:Wispr Flow,globe", "sorted, one string")
        XCTAssertEqual(posts, 1)
        defaults = [:]
        SetupAskKeyWriter.choose(.shiftTwice, accepting: [], set: { defaults[$0] = $1 }, post: { posts += 1 })
        XCTAssertEqual(defaults, ["ai.hippocampus.prefs.askKey": "shiftTwice"])
        XCTAssertEqual(SetupAskKeyWriter.accepted(from: "app:Wispr Flow,globe"), ["app:Wispr Flow", "globe"])
        XCTAssertEqual(SetupAskKeyWriter.accepted(from: nil), [])
        XCTAssertEqual(SetupAskKeyWriter.accepted(from: ",,"), [])
        XCTAssertEqual(SetupAskKeyWriter.notification.rawValue, "ai.hippocampus.setup.askKeyChosen")
    }

    func testTheAcceptedKeyAndNoticeAreTheAppsOwn() throws {
        let monitor = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "apps/hippocampus/Sources/HippocampusKit/FnKeyMonitor.swift"), encoding: .utf8)
        XCTAssertTrue(monitor.contains("\"\(SetupAskKeyWriter.acceptedKey)\""))
        XCTAssertTrue(monitor.contains("\"\(SetupAskKeyWriter.notification.rawValue)\""))
    }

    // MARK: - Reading this Mac, in a folder the test makes

    func testInstalledAppsAreReadFromTheFolderListingAndInfoPlistOnly() throws {
        let folder = try temporaryDirectory()
        for (name, id) in [("Wispr Flow.app", "com.electron.wispr-flow"), ("Notes.app", "com.apple.Notes")] {
            let contents = folder.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                           format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("NoPlist.app"),
                                                withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("readme.txt"))
        let apps = MacFacts.installedApps(in: [folder, folder.appendingPathComponent("missing")])
        XCTAssertEqual(Set(apps.map(\.fileName)), ["Wispr Flow.app", "Notes.app", "NoPlist.app"])
        XCTAssertEqual(apps.first { $0.fileName == "NoPlist.app" }?.bundleId, nil)
        XCTAssertEqual(FnKeyCheck(installed: apps, appleFnUsageType: 0, keyboardHasFn: true).appsUsingFn, ["Wispr Flow"])
        let home = URL(fileURLWithPath: "/Users/sam")
        XCTAssertEqual(MacFacts.applicationFolders(home: home).map(\.path), ["/Applications", "/Users/sam/Applications"])
    }

    func testABuiltInOrAppleKeyboardHasFn() {
        XCTAssertTrue(MacFacts.Keyboard(builtIn: true, vendorId: nil).hasFn)
        XCTAssertTrue(MacFacts.Keyboard(builtIn: false, vendorId: 0x05AC).hasFn, "Apple, USB")
        XCTAssertTrue(MacFacts.Keyboard(builtIn: false, vendorId: 0x004C).hasFn, "Apple, Bluetooth")
        XCTAssertFalse(MacFacts.Keyboard(builtIn: false, vendorId: 0x046D).hasFn, "another maker's")
        XCTAssertFalse(MacFacts.Keyboard(builtIn: false, vendorId: nil).hasFn)
    }
}
