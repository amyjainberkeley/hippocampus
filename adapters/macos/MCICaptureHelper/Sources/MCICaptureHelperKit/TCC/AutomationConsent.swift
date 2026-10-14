// SPDX-License-Identifier: Apache-2.0
//
// AutomationConsent — whether this process may already send Apple Events
// to an app. RULINGS G8: Hippocampus never shows an Automation prompt, so
// every script it runs first asks macOS here, with `askUserIfNeeded` false,
// and runs only when the person already allowed it.

import Foundation

#if canImport(AppKit)
    import AppKit
    import CoreServices
#endif

public enum AutomationConsent {
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
