// SPDX-License-Identifier: Apache-2.0
//
// Setup's choice of the key that opens Ask (SPEC-DELTA 7). Shift twice stays
// the default: it works on every keyboard and doesn't fight the dictation
// apps that hold Fn. Fn (Globe) is offered beside it, with its checks shown
// before it is chosen:
//
// - A known Fn app is installed (Wispr Flow, Superwhisper, ...), found by
//   its bundle id in /Applications and ~/Applications: setup names it.
// - macOS's own "Press Globe key to" setting (com.apple.HIToolbox
//   AppleFnUsageType) is not Do Nothing: setup gives the exact step and
//   offers to open Keyboard settings.
// - No keyboard with Fn is connected: Fn falls back to Shift twice, with a
//   one-line note.
//
// Fn is never taken silently: with an app or macOS using it, setup takes
// it only when the person clicks Use Fn, and keeps that answer for the app
// (`FnKeyCheck.conflictTokens`), which asks again only for a new conflict.
//
// The choice is written to the app's own defaults, where its Preferences
// keep it (`ai.hippocampus.prefs.askKey`), and the app is told to look
// again. Onboarding does not link HippocampusKit, so the app's Fn checks
// (`FnKeyMonitor.swift`) are copied here; tests on both sides hold the same
// list of apps and the same tokens.

import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.hid
#endif

/// The keys setup's picker offers. Preferences offers the rest.
public enum SetupAskKey: String, CaseIterable, Sendable, Equatable {
    case shiftTwice
    case fn

    /// The stored value's key, or nil when it is one only Preferences
    /// offers. Nothing stored, or a value the app doesn't know, is Shift
    /// twice, as the app reads it.
    public init?(stored: String?) {
        switch stored {
        case "fn": self = .fn
        case "rightShift", "rightCommand", "rightOption", "off": return nil
        default: self = .shiftTwice
        }
    }

    /// The picker's name for it.
    public var label: String {
        switch self {
        case .shiftTwice: "Shift twice"
        case .fn: "Fn (Globe)"
        }
    }

    /// The line under its name.
    public var line: String {
        switch self {
        case .shiftTwice: OnboardingCopy.AskKey.shiftTwiceLine
        case .fn: OnboardingCopy.AskKey.fnLine
        }
    }

    /// How onboarding names it everywhere else.
    public var hint: AskKeyHint {
        switch self {
        case .shiftTwice: .shiftTwice
        case .fn: .fn
        }
    }
}

/// What macOS does when the Globe key is pressed ("Press Globe key to"),
/// from com.apple.HIToolbox AppleFnUsageType.
public enum GlobeKeyAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// Not set, or a value this build doesn't know: macOS uses the key for
    /// something.
    case macOSDefault

    public init(appleFnUsageType: Int?) {
        switch appleFnUsageType {
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmojiAndSymbols
        case 3: self = .startDictation
        default: self = .macOSDefault
        }
    }
}

/// An app known to hold Fn for its own shortcut.
public struct FnApp: Equatable, Sendable {
    public let name: String
    public let bundleIds: [String]
    /// The bundle's file name, for apps whose bundle id isn't published.
    public let bundleNames: [String]

    public init(name: String, bundleIds: [String], bundleNames: [String] = []) {
        self.name = name
        self.bundleIds = bundleIds
        self.bundleNames = bundleNames
    }

    /// Dictation apps that use Fn by default or offer it as their key. Kept
    /// equal to the app's list (`FnKeyMonitor.knownApps`) by a test.
    public static let known: [FnApp] = [
        FnApp(name: "Wispr Flow", bundleIds: ["com.electron.wispr-flow"]),
        FnApp(name: "Superwhisper", bundleIds: ["com.superduper.superwhisper"]),
        FnApp(name: "VoiceInk", bundleIds: ["com.prakashjoshipax.VoiceInk"]),
        FnApp(name: "Willow Voice", bundleIds: [], bundleNames: ["Willow Voice.app", "Willow.app"]),
    ]
}

/// An app found in /Applications or ~/Applications: only its bundle id
/// and file name, read from the folder listing and its Info.plist.
public struct InstalledApp: Equatable, Sendable {
    public let bundleId: String?
    public let fileName: String

    public init(bundleId: String?, fileName: String) {
        self.bundleId = bundleId
        self.fileName = fileName
    }
}

/// The checks before Fn (Globe) is chosen, from facts read on this Mac.
public struct FnKeyCheck: Equatable, Sendable {
    /// A keyboard with Fn is connected.
    public let hasFnKey: Bool
    /// Known Fn apps installed, by name, in the known list's order.
    public let appsUsingFn: [String]
    public let globeAction: GlobeKeyAction

    public init(hasFnKey: Bool, appsUsingFn: [String], globeAction: GlobeKeyAction) {
        self.hasFnKey = hasFnKey
        self.appsUsingFn = appsUsingFn
        self.globeAction = globeAction
    }

    /// Nothing else uses Fn and a keyboard has it.
    public static let clear = FnKeyCheck(hasFnKey: true, appsUsingFn: [], globeAction: .doNothing)

    /// From what was read: the apps installed, macOS's Globe setting and
    /// whether a keyboard with Fn is connected.
    public init(installed: [InstalledApp], appleFnUsageType: Int?, keyboardHasFn: Bool) {
        let ids = Set(installed.compactMap { $0.bundleId?.lowercased() })
        let names = Set(installed.map { $0.fileName.lowercased() })
        let apps = FnApp.known.filter { app in
            app.bundleIds.contains { ids.contains($0.lowercased()) }
                || app.bundleNames.contains { names.contains($0.lowercased()) }
        }
        self.init(hasFnKey: keyboardHasFn, appsUsingFn: apps.map(\.name),
                  globeAction: GlobeKeyAction(appleFnUsageType: appleFnUsageType))
    }

    /// What else uses Fn, as tokens: "app:<name>" for each app, "globe" for
    /// macOS's own setting. Clicking Use Fn keeps these, and a later check
    /// asks again only when a token is new.
    public var conflictTokens: Set<String> {
        var tokens = Set(appsUsingFn.map { "app:\($0)" })
        if globeAction != .doNothing { tokens.insert("globe") }
        return tokens
    }

    /// Fn waits for the person's Use Fn: something else uses it, and not
    /// everything that does was accepted before.
    public func needsConfirmation(accepted: Set<String>) -> Bool {
        !conflictTokens.isSubset(of: accepted)
    }

    /// The lines that say so, in order: the apps, then macOS, then a
    /// keyboard without Fn.
    public var notes: [FnKeyNote] {
        var notes: [FnKeyNote] = []
        if !appsUsingFn.isEmpty { notes.append(.apps(appsUsingFn)) }
        if globeAction != .doNothing { notes.append(.globe(globeAction)) }
        if !hasFnKey { notes.append(.noFnKey) }
        return notes
    }
}

/// One thing the picker says about Fn before it is chosen.
public enum FnKeyNote: Equatable, Sendable {
    case apps([String])
    case globe(GlobeKeyAction)
    case noFnKey

    /// The words, one or two sentences.
    public var text: String {
        switch self {
        case .apps(let names): OnboardingCopy.AskKey.appsUseFn(names)
        case .globe(let action): OnboardingCopy.AskKey.globeUsesFn(action)
        case .noFnKey: OnboardingCopy.AskKey.noFnKey
        }
    }

    /// The exact step in System Settings, for macOS's own setting.
    public var step: String? {
        if case .globe = self { return OnboardingCopy.AskKey.globeStep }
        return nil
    }

    /// A warning (orange icon) or a note (grey).
    public var isWarning: Bool {
        if case .noFnKey = self { return false }
        return true
    }
}

/// Reading the facts on this Mac. Each is injected, so tests and renders
/// never read the real ones.
public struct FnKeyFacts: Sendable {
    public var installedApps: @Sendable () -> [InstalledApp]
    public var appleFnUsageType: @Sendable () -> Int?
    public var keyboardHasFn: @Sendable () -> Bool

    public init(
        installedApps: @escaping @Sendable () -> [InstalledApp],
        appleFnUsageType: @escaping @Sendable () -> Int?,
        keyboardHasFn: @escaping @Sendable () -> Bool
    ) {
        self.installedApps = installedApps
        self.appleFnUsageType = appleFnUsageType
        self.keyboardHasFn = keyboardHasFn
    }

    public func check() -> FnKeyCheck {
        FnKeyCheck(installed: installedApps(), appleFnUsageType: appleFnUsageType(), keyboardHasFn: keyboardHasFn())
    }

    /// Facts for a Mac where nothing else uses Fn.
    public static let clear = FnKeyFacts(
        installedApps: { [] }, appleFnUsageType: { 0 }, keyboardHasFn: { true }
    )

    /// This Mac's: the two Applications folders, macOS's Globe setting and
    /// the keyboards IOKit lists. Nothing is opened or asked: no keyboard is
    /// opened for input, so no permission prompt can show.
    public static let thisMac = FnKeyFacts(
        installedApps: { MacFacts.installedApps() },
        appleFnUsageType: { MacFacts.appleFnUsageType() },
        keyboardHasFn: { MacFacts.keyboardHasFn() }
    )
}

/// The real readers behind `FnKeyFacts.thisMac`.
public enum MacFacts {
    /// The folders apps are installed in.
    public static func applicationFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Every `.app` directly in `folders`, with its bundle id from its
    /// Info.plist.
    public static func installedApps(in folders: [URL] = applicationFolders()) -> [InstalledApp] {
        folders.flatMap { folder -> [InstalledApp] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".app") }.map { name in
                let plist = folder.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
                let info = NSDictionary(contentsOf: plist)
                return InstalledApp(bundleId: info?["CFBundleIdentifier"] as? String, fileName: name)
            }
        }
    }

    /// macOS's "Press Globe key to" setting, or nil when it was never set.
    public static func appleFnUsageType() -> Int? {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? NSNumber)?.intValue
    }

    /// Whether a connected keyboard has Fn: a Mac's built-in keyboard, or
    /// an Apple keyboard (Apple's USB and Bluetooth vendor ids). Many other
    /// keyboards have no Fn the Mac can see. An empty list means the
    /// registry couldn't say: Fn isn't refused on a guess.
    public static func keyboardHasFn() -> Bool {
        hasFn(keyboards())
    }

    public static func hasFn(_ keyboards: [Keyboard]) -> Bool {
        keyboards.isEmpty || keyboards.contains(where: \.hasFn)
    }

    /// One keyboard as IOKit lists it.
    public struct Keyboard: Equatable, Sendable {
        public let builtIn: Bool
        public let vendorId: Int?

        public init(builtIn: Bool, vendorId: Int?) {
            self.builtIn = builtIn
            self.vendorId = vendorId
        }

        /// Apple's USB vendor id, and its Bluetooth one.
        public static let appleVendorIds: Set<Int> = [0x05AC, 0x004C]

        public var hasFn: Bool { builtIn || vendorId.map(Self.appleVendorIds.contains) == true }
    }

    /// The keyboards in the I/O Registry: their properties only.
    public static func keyboards() -> [Keyboard] {
        #if canImport(IOKit)
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return [] }
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Keyboard] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let builtIn = (property(kIOHIDBuiltInKey) as? Bool) ?? false
            let vendor = (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue
            found.append(Keyboard(builtIn: builtIn, vendorId: vendor))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found
        #else
        return []
        #endif
    }
}

/// Writes setup's choice where the app keeps it, and tells the app.
public enum SetupAskKeyWriter {
    /// The app keeps the person's Use Fn here: the conflicts they accepted.
    public static let acceptedKey = "ai.hippocampus.prefs.askKeyFnAccepted"
    /// Posted, with nothing in it, after setup writes a choice: the app
    /// reads its defaults again (`SoloKeyMonitor`).
    public static let notification = Notification.Name("ai.hippocampus.setup.askKeyChosen")

    /// The accepted conflicts as stored: sorted tokens, one string.
    public static func acceptedValue(_ tokens: Set<String>) -> String {
        tokens.sorted().joined(separator: ",")
    }

    public static func accepted(from stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Write `key` and, for Fn taken over a conflict, what was accepted,
    /// with `set`; then `post` the notice.
    public static func choose(
        _ key: SetupAskKey,
        accepting tokens: Set<String>,
        set: (String, String?) -> Void,
        post: () -> Void
    ) {
        set(AskShortcutLabel.preferenceKey, key.rawValue)
        if key == .fn, !tokens.isEmpty {
            set(acceptedKey, acceptedValue(tokens))
        }
        post()
    }

    /// The app's own defaults, by name, and a distributed notification.
    public static func chooseOnThisMac(_ key: SetupAskKey, accepting tokens: Set<String>) {
        choose(key, accepting: tokens, set: { name, value in
            CFPreferencesSetAppValue(name as CFString, value as CFString?, AskShortcutLabel.applicationID as CFString)
            CFPreferencesAppSynchronize(AskShortcutLabel.applicationID as CFString)
        }, post: {
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: nil, userInfo: nil, deliverImmediately: true
            )
        })
    }

    /// The conflicts the person accepted before, from the app's defaults.
    public static func acceptedOnThisMac() -> Set<String> {
        accepted(from: AskShortcutLabel.appValue(acceptedKey))
    }
}

/// Opening Keyboard settings, for the Globe key's step.
public enum KeyboardSettingsLink {
    public static let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// Setup's key picker (SPEC-DELTA 7): Shift twice or Fn (Globe), with what
/// else uses Fn said before Fn is taken. Nothing is written until Done or
/// Use Fn; Cancel leaves the stored key as it was.
@MainActor
public final class AskKeyPickerModel: ObservableObject, Identifiable {
    /// The card picked in the sheet, not the choice until it is confirmed.
    /// Nil when the person keeps a key only Preferences offers (right ⌘).
    @Published public var selection: SetupAskKey?
    /// What else uses Fn on this Mac, read when the sheet opens and again
    /// when the person comes back from Keyboard settings.
    @Published public private(set) var check: FnKeyCheck

    /// The stored key, when it is one setup offers.
    public let stored: SetupAskKey?
    private let facts: FnKeyFacts
    private let accepted: Set<String>

    /// - Parameters:
    ///   - stored: the app's stored key (`ai.hippocampus.prefs.askKey`);
    ///     nothing stored is Shift twice.
    ///   - accepted: what else using Fn the person accepted before.
    public init(stored: String?, facts: FnKeyFacts, accepted: Set<String>) {
        let key = SetupAskKey(stored: stored)
        self.stored = key
        self.selection = key
        self.facts = facts
        self.accepted = accepted
        self.check = facts.check()
    }

    /// Read again: Keyboard settings may have changed the Globe key.
    public func recheck() {
        let fresh = facts.check()
        if fresh != check { check = fresh }
    }

    /// What the sheet says under the cards: only about Fn, once it is picked.
    public var notes: [FnKeyNote] {
        selection == .fn ? check.notes : []
    }

    /// Fn is picked and something else uses it that the person has not
    /// accepted: the button says Use Fn, so taking it is their own click.
    public var needsConfirmation: Bool {
        selection == .fn && check.needsConfirmation(accepted: accepted)
    }

    /// The sheet's default button.
    public var confirmLabel: String {
        needsConfirmation ? OnboardingCopy.AskKey.useFn : OnboardingCopy.done
    }

    /// Done or Use Fn: hands `write` the key and, for Fn taken over what
    /// else uses it, every conflict now accepted. Nothing when no card is
    /// picked, or the key is the one stored and nothing new was accepted.
    public func confirm(write: (SetupAskKey, Set<String>) -> Void) {
        guard let selection else { return }
        let conflicts = selection == .fn ? check.conflictTokens : []
        let newlyAccepted = !conflicts.isSubset(of: accepted)
        guard selection != stored || newlyAccepted else { return }
        write(selection, conflicts.isEmpty ? [] : conflicts.union(accepted))
    }
}
