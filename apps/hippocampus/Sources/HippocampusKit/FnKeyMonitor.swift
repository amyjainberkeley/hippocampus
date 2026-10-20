// SPDX-License-Identifier: Apache-2.0
//
// FnKeyMonitor.swift — the Fn (Globe) key as Ask's key (SPEC-DELTA 7).

import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.hid
#endif

/// Fn (Globe), offered beside Shift twice as the key that opens Ask
/// (SPEC-DELTA 7). Shift twice stays the default: it works on every
/// keyboard and doesn't fight Wispr Flow or macOS dictation, which hold Fn.
///
/// - Fn opens Ask only on a tap with no other key, so Fn with the arrows or
///   the F-keys keeps working. `SoloKeyDetector` decides the tap from
///   modifier changes alone: like every Ask key, Fn is heard through
///   `.flagsChanged`, which carries no typed character, and nothing here
///   reads or stores one (a no-keylogging promise, held by tests).
/// - Before Fn listens, the checks run (`FnKeyCheck`): a known Fn app
///   installed in /Applications or ~/Applications, found by bundle id and
///   named; macOS's own "Press Globe key to" setting (com.apple.HIToolbox
///   AppleFnUsageType), with the exact step in Keyboard settings; and a
///   keyboard with Fn at all.
/// - Fn is never taken from another app silently: while something else
///   uses it, Shift twice keeps opening Ask until the person clicks Use Fn,
///   and a new conflict asks again (`acceptedKey`).
/// - A keyboard without Fn falls back to Shift twice, with a one-line note.
///
/// Setup offers the same choice and writes it where Preferences keeps it;
/// onboarding can't link this module, so its copy of these checks
/// (`AskKeyChoice.swift`) is held to the same apps and names by tests.
public enum FnKeyMonitor {
    /// The device-independent modifier bit for Fn
    /// (`NSEvent.ModifierFlags.function`).
    public static let functionMask: UInt = 1 << 23

    /// The Fn (Globe) key's code in a modifier change (`kVK_Function`), and
    /// the code some keyboards give the Globe key.
    public static let keyCodes: Set<UInt16> = [63, 179]

    /// Fn (Globe) is a choice in Preferences and setup.
    public static var isOffered: Bool { true }

    /// Where the person's Use Fn is kept: the conflicts they accepted,
    /// sorted and joined with commas. Setup writes the same.
    public static let acceptedKey = "ai.hippocampus.prefs.askKeyFnAccepted"

    /// Where the key itself is kept (`PreferencesStore`'s `askKey`).
    public static let preferenceKey = "ai.hippocampus.prefs.askKey"

    /// Setup posts this, carrying nothing, after it writes a choice: the
    /// app reads the key again.
    public static let setupChoseNotification = Notification.Name("ai.hippocampus.setup.askKeyChosen")

    /// The accepted conflicts as stored.
    public static func acceptedValue(_ tokens: Set<String>) -> String {
        tokens.sorted().joined(separator: ",")
    }

    public static func accepted(from stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Dictation apps that use Fn by default or offer it as their key, by
    /// bundle id, or by bundle name where no id is published. Setup's list
    /// (`FnApp.known`) names the same.
    public static let knownApps: [FnApp] = [
        FnApp(name: "Wispr Flow", bundleIds: ["com.electron.wispr-flow"]),
        FnApp(name: "Superwhisper", bundleIds: ["com.superduper.superwhisper"]),
        FnApp(name: "VoiceInk", bundleIds: ["com.prakashjoshipax.VoiceInk"]),
        FnApp(name: "Willow Voice", bundleIds: [], bundleNames: ["Willow Voice.app", "Willow.app"]),
    ]
}

/// An app known to hold Fn for its own shortcut.
public struct FnApp: Equatable, Sendable {
    public let name: String
    public let bundleIds: [String]
    public let bundleNames: [String]

    public init(name: String, bundleIds: [String], bundleNames: [String] = []) {
        self.name = name
        self.bundleIds = bundleIds
        self.bundleNames = bundleNames
    }
}

/// An app found in /Applications or ~/Applications: its bundle id and file
/// name only.
public struct InstalledApp: Equatable, Sendable {
    public let bundleId: String?
    public let fileName: String

    public init(bundleId: String?, fileName: String) {
        self.bundleId = bundleId
        self.fileName = fileName
    }
}

/// What macOS does when the Globe key is pressed ("Press Globe key to").
public enum GlobeKeyAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// Never set, or a value this build doesn't know: macOS uses the key.
    case macOSDefault

    /// From com.apple.HIToolbox AppleFnUsageType.
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

/// The checks before Fn listens.
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

    /// A keyboard with Fn, and nothing else using it.
    public static let clear = FnKeyCheck(hasFnKey: true, appsUsingFn: [], globeAction: .doNothing)

    public init(installed: [InstalledApp], appleFnUsageType: Int?, keyboardHasFn: Bool) {
        let ids = Set(installed.compactMap { $0.bundleId?.lowercased() })
        let names = Set(installed.map { $0.fileName.lowercased() })
        let apps = FnKeyMonitor.knownApps.filter { app in
            app.bundleIds.contains { ids.contains($0.lowercased()) }
                || app.bundleNames.contains { names.contains($0.lowercased()) }
        }
        self.init(hasFnKey: keyboardHasFn, appsUsingFn: apps.map(\.name),
                  globeAction: GlobeKeyAction(appleFnUsageType: appleFnUsageType))
    }

    /// What else uses Fn: "app:<name>" for each app, "globe" for macOS.
    public var conflictTokens: Set<String> {
        var tokens = Set(appsUsingFn.map { "app:\($0)" })
        if globeAction != .doNothing { tokens.insert("globe") }
        return tokens
    }

    /// Fn waits for Use Fn: something uses it that wasn't accepted before.
    public func needsConfirmation(accepted: Set<String>) -> Bool {
        !conflictTokens.isSubset(of: accepted)
    }

    /// What listens for Ask when Fn is chosen: Fn, or Shift twice while
    /// there is no Fn key or Fn waits for Use Fn.
    public func listeningKey(accepted: Set<String>) -> SoloKey {
        hasFnKey && !needsConfirmation(accepted: accepted) ? .fn : .shiftTwice
    }

    /// The warnings to show while Fn waits: the apps, then macOS.
    public var warnings: [FnKeyNote] {
        var notes: [FnKeyNote] = []
        if !appsUsingFn.isEmpty { notes.append(.apps(appsUsingFn)) }
        if globeAction != .doNothing { notes.append(.globe(globeAction)) }
        return notes
    }
}

/// One thing Preferences says about Fn before it is taken.
public enum FnKeyNote: Equatable, Sendable, Identifiable {
    case apps([String])
    case globe(GlobeKeyAction)

    public var id: String {
        switch self {
        case .apps(let names): "apps:" + names.joined(separator: ",")
        case .globe: "globe"
        }
    }

    public var text: String {
        switch self {
        case .apps(let names): AskKeyCopy.appsUseFn(names)
        case .globe(let action): AskKeyCopy.globeUsesFn(action)
        }
    }

    /// The exact step in Keyboard settings, for macOS's own setting.
    public var step: String? {
        if case .globe = self { return AskKeyCopy.globeStep }
        return nil
    }
}

/// Reading the facts on this Mac, injected so tests and pictures never read
/// the real ones.
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

    /// Nothing else uses Fn and a keyboard has it.
    public static let clear = FnKeyFacts(installedApps: { [] }, appleFnUsageType: { 0 }, keyboardHasFn: { true })

    /// This Mac's: the Applications folders' listings and the apps' bundle
    /// ids, macOS's Globe key setting, and the keyboards' I/O Registry
    /// properties. Nothing is opened for input and nothing is asked, so no
    /// permission prompt can show.
    public static let thisMac = FnKeyFacts(
        installedApps: { FnKeyMacFacts.installedApps() },
        appleFnUsageType: { FnKeyMacFacts.appleFnUsageType() },
        keyboardHasFn: { FnKeyMacFacts.keyboardHasFn() }
    )
}

/// The real readers behind `FnKeyFacts.thisMac`.
public enum FnKeyMacFacts {
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

    /// macOS's "Press Globe key to" setting, or nil when never set.
    public static func appleFnUsageType() -> Int? {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? NSNumber)?.intValue
    }

    /// A Mac's built-in keyboard, or an Apple keyboard, is connected. An
    /// empty list means the registry couldn't say, not that there is no
    /// Fn: the key isn't refused on a guess.
    public static func keyboardHasFn() -> Bool {
        hasFn(keyboards())
    }

    /// Whether these keyboards have Fn, as `keyboardHasFn` decides.
    public static func hasFn(_ keyboards: [Keyboard]) -> Bool {
        keyboards.isEmpty || keyboards.contains(where: \.hasFn)
    }

    /// One keyboard as the I/O Registry lists it.
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

    /// The keyboards' properties, from the I/O Registry. No device is opened.
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

/// Fn's checks, with the Applications folders read at most once a minute:
/// the watch looks again every two seconds while it waits for
/// Accessibility. macOS's Globe setting and the keyboards are read each
/// time; both are cheap.
@MainActor
public final class FnKeyChecker {
    private let facts: FnKeyFacts
    private let maxAge: TimeInterval
    private let now: () -> Date
    private var apps: (at: Date, list: [InstalledApp])?

    public init(facts: FnKeyFacts, maxAge: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.facts = facts
        self.maxAge = maxAge
        self.now = now
    }

    public func check() -> FnKeyCheck {
        let list: [InstalledApp]
        if let apps, now().timeIntervalSince(apps.at) < maxAge {
            list = apps.list
        } else {
            list = facts.installedApps()
            apps = (now(), list)
        }
        return FnKeyCheck(installed: list, appleFnUsageType: facts.appleFnUsageType(), keyboardHasFn: facts.keyboardHasFn())
    }

    /// Read the folders again next time: setup has just looked at them.
    public func forget() {
        apps = nil
    }
}

/// Opening Keyboard settings, for the Globe key's step.
public enum KeyboardSettingsLink {
    public static let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
