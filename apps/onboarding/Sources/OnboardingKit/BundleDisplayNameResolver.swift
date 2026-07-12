// SPDX-License-Identifier: TBD-private
//
// BundleDisplayNameResolver — turn a raw bundle id (`com.apple.MobileSMS`)
// into a human-friendly display name (`Messages`) for the AllowlistSlide
// baseline rows.
//
// Resolution ladder (all local, no network — §PR-3 constraint):
//   1. `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` +
//      `CFBundleDisplayName` / `CFBundleName` from the app's Info.plist.
//      Works if the app is installed.
//   2. Static fallback table of common Apple / third-party bundles the
//      onboarding baseline is likely to reference. Covers the ships-in-
//      the-box Apple apps that may not always be found by NSWorkspace
//      (e.g. Messages.app on a locked-down SIP fork).
//   3. Prettify the last dot-component of the bundle id via a camel-case
//      splitter — `com.apple.MobileSMS` → `MobileSMS` → `Mobile SMS`.
//      Safe last-resort: never returns the raw bundle id.
//
// This resolver is used by `AllowlistEditorViewModel.load()` for baseline
// (read-only) rows only. Detected-running rows already get a display name
// from `NSWorkspace.runningApplications` via `RealRunningAppsDetector`,
// and user-added rows can carry a user-typed rationale.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum BundleDisplayNameResolver {

    /// Best-effort human-friendly name for a bundle id. Never returns the
    /// raw bundle id — falls back through NSWorkspace → static table →
    /// prettified last component.
    public static func displayName(for bundleId: String) -> String {
        if let fromWorkspace = displayNameFromWorkspace(bundleId: bundleId) {
            return fromWorkspace
        }
        if let fromTable = commonBundleTable[bundleId] {
            return fromTable
        }
        return prettifyLastComponent(bundleId: bundleId)
    }

    /// Static lookup for the common shipping bundles the CSO baseline
    /// tends to reference. Kept small on purpose — the NSWorkspace path
    /// covers everything installed, so this only backfills bundles that
    /// might resolve to a URL but whose Info.plist doesn't carry a
    /// user-facing name (rare, but possible).
    static let commonBundleTable: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.Terminal": "Terminal",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mail": "Mail",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.dt.Xcode": "Xcode",
        "com.apple.iCal": "Calendar",
        "com.apple.Notes": "Notes",
        "com.apple.Music": "Music",
        "com.apple.Photos": "Photos",
        "com.apple.systempreferences": "System Settings",
        "com.microsoft.VSCode": "VS Code",
        "com.google.Chrome": "Chrome",
        "com.tinyspeck.slackmacgap": "Slack",
        "notion.id": "Notion",
        "com.linear.LinearMac": "Linear",
        "company.thebrowser.Browser": "Arc",
        "com.figma.Desktop": "Figma",
        "com.1password.1password": "1Password",
        "com.chase.sig.Chase": "Chase Banking",
    ]

    // MARK: - Internals

    /// Ask NSWorkspace where the app lives, then read the display name
    /// from its Info.plist. `nil` if the app isn't installed or if the
    /// plist has no user-facing name.
    static func displayNameFromWorkspace(bundleId: String) -> String? {
        #if canImport(AppKit)
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        ) else {
            return nil
        }
        guard let bundle = Bundle(url: url) else {
            return nil
        }
        // CFBundleDisplayName is the user-facing name if set; fall back
        // to CFBundleName. Both are optional in the Info.plist spec.
        if let displayName = bundle.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(
            forInfoDictionaryKey: "CFBundleName"
        ) as? String, !name.isEmpty {
            return name
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Take the last dot-component and split camel case: `MobileSMS` →
    /// `Mobile SMS`. Preserves runs of capitals (`SMS`, `URL`) as a
    /// single token — the humanized name looks like a proper noun.
    static func prettifyLastComponent(bundleId: String) -> String {
        let last = bundleId.split(separator: ".").last.map(String.init)
            ?? bundleId
        guard !last.isEmpty else { return bundleId }
        // Uppercase the first character.
        let firstCased = last.prefix(1).uppercased() + last.dropFirst()
        return splitCamelCase(firstCased)
    }

    /// Insert a space before each capital that follows a lowercase OR
    /// that starts a new capital-then-lowercase run — so `MobileSMS`
    /// becomes `Mobile SMS`, `URLSession` becomes `URL Session`.
    static func splitCamelCase(_ input: String) -> String {
        var out = ""
        let chars = Array(input)
        for i in 0..<chars.count {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
                let boundary: Bool
                if c.isUppercase && prev.isLowercase {
                    // aB → a B
                    boundary = true
                } else if c.isUppercase, let n = next,
                          n.isLowercase, prev.isUppercase {
                    // ABc → A Bc (end of a caps run, start of a word)
                    boundary = true
                } else {
                    boundary = false
                }
                if boundary { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }
}
