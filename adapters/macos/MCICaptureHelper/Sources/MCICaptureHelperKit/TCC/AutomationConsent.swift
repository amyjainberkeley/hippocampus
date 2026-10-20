// SPDX-License-Identifier: Apache-2.0
//
// AutomationConsent — whether this process may already send Apple Events
// to an app. RULINGS G8: Hippocampus never shows an Automation prompt, so
// every script it runs first asks macOS here, with `askUserIfNeeded` false,
// and runs only when the person already allowed it. The page-address
// readers also need the person's own switch (`addressReadingKey`).

import Foundation

#if canImport(AppKit)
    import AppKit
    import CoreServices
#endif

public enum AutomationConsent {
    /// The person's own switch for saving a browser's page address through
    /// Automation while Hippocampus remembers (the URL readers). macOS's
    /// Automation grant is one per browser and is also given for other
    /// things: Resume's open-tab check and setup's Safari settings ask for
    /// it. So a yes to macOS never turns address reading on by itself; only
    /// this switch does. Off unless set (`readsAddresses(stored:)`); the
    /// private-window check, which reads no address, doesn't depend on it.
    public static let addressReadingKey = "ai.hippocampus.browser.readAddressesWithAutomation"

    /// Whether the value stored under `addressReadingKey` turns address
    /// reading on. Unset, or anything but `true`, is off.
    public static func readsAddresses(stored: Any?) -> Bool {
        stored as? Bool == true
    }

    /// The switch as the capture helper reads it: the app's own defaults,
    /// which the helper shares because it runs inside the app's bundle.
    public static func readsAddressesNow() -> Bool {
        readsAddresses(stored: UserDefaults.standard.object(forKey: addressReadingKey))
    }

    /// True only when the person already allowed this process to control the
    /// app. Never shows a prompt: a question macOS would have to ask the
    /// person, a refusal, an app that is not running and any error are all
    /// false.
    ///
    /// It asks about "get data" (`core`/`getd`), the event the scripts send.
    /// macOS lets a few events, such as activate, through without consent,
    /// so asking about one of those would answer yes before the person had
    /// been asked anything.
    public static func isAlreadyGranted(_ bundleId: String) -> Bool {
        #if canImport(AppKit)
            guard !bundleId.isEmpty else { return false }
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            return withExtendedLifetime(target) {
                guard let address = target.aeDesc else { return false }
                return AEDeterminePermissionToAutomateTarget(
                    address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), false
                ) == noErr
            }
        #else
            return false
        #endif
    }
}
