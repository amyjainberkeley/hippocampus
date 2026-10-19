// SPDX-License-Identifier: Apache-2.0
//
// The window Try it reads: the frontmost window on screen that is not
// Hippocampus's own. Setup's window is in front while Try it shows, so this
// is the window right behind it, the one the person was working in, until
// they bring another forward. Whole-screen reading leaves Hippocampus's own
// windows out of the pixels, so that window is read in full.
//
// Whether it is read follows the capture helper's rules, which onboarding
// does not link; `CaptureListParityTests` holds the copies below to the
// helper's source. Never read: password managers, authenticators, System
// Settings and system dialogs. Skipped: the person's own exclusions, a
// browser window whose title shows it is private, and everything while
// secure text entry is on (a password field in use).

import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon
#endif

/// One window as the window server lists it, front to back.
public struct ListedWindow: Equatable, Sendable {
    public let ownerPid: Int32
    public let bundleId: String?
    public let appName: String?
    public let title: String?
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect

    public init(
        ownerPid: Int32, bundleId: String?, appName: String?, title: String?,
        layer: Int = 0, alpha: Double = 1, bounds: CGRect
    ) {
        self.ownerPid = ownerPid
        self.bundleId = bundleId
        self.appName = appName
        self.title = title
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// The window Try it reads, as the person sees it.
public struct FrontWindow: Equatable, Sendable {
    public let bundleId: String
    public let appName: String
    /// The window's title, when it has one.
    public let title: String?

    public init(bundleId: String, appName: String, title: String?) {
        self.bundleId = bundleId
        self.appName = appName
        self.title = title
    }

    /// Smaller windows are not read on their own (the helper's
    /// `BackgroundCapturePolicy.minimumWindowSide`).
    public static let minimumSide: CGFloat = 80

    /// macOS's own surfaces, which can sit among ordinary windows but are
    /// never the window a person works in: Stage Manager's strip, the Dock,
    /// Control Center, notifications, Spotlight and the screenshot tools.
    static let systemSurfaces: Set<String> = [
        "com.apple.windowmanager", "com.apple.dock", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.spotlight", "com.apple.systemuiserver",
        "com.apple.screencaptureui", "com.apple.wallpaper.agent",
    ]

    /// The frontmost ordinary window that belongs to neither this process
    /// nor Hippocampus. Nil when there is none: an empty desktop.
    public static func pick(
        from windows: [ListedWindow],
        ownPid: Int32,
        nameFor: (String) -> String = BundleDisplayNameResolver.displayName(for:)
    ) -> FrontWindow? {
        for window in windows {
            guard window.layer == 0, window.alpha > 0.05,
                  window.bounds.width >= minimumSide, window.bounds.height >= minimumSide,
                  window.ownerPid != ownPid,
                  let bundleId = window.bundleId?.trimmingCharacters(in: .whitespaces), !bundleId.isEmpty,
                  !ReadProof.ownBundleIds.contains(bundleId.lowercased()),
                  !systemSurfaces.contains(bundleId.lowercased())
            else { continue }
            let name = window.appName?.trimmingCharacters(in: .whitespaces)
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FrontWindow(
                bundleId: bundleId,
                appName: name.flatMap { $0.isEmpty ? nil : $0 } ?? nameFor(bundleId),
                title: title.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return nil
    }
}

/// Where Try it looks for the window in front.
public protocol FrontWindowSource: Sendable {
    func frontWindow() -> FrontWindow?
}

#if canImport(AppKit)
/// The window server's list of on-screen windows, front to back. Titles
/// come with Screen Recording, which Try it always has: consent needs it.
public struct WindowServerFrontWindowSource: FrontWindowSource {
    public init() {}

    public func frontWindow() -> FrontWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var apps: [Int32: NSRunningApplication?] = [:]
        let windows: [ListedWindow] = list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { return nil }
            if apps[pid] == nil { apps[pid] = NSRunningApplication(processIdentifier: pid) }
            let app = apps[pid] ?? nil
            return ListedWindow(
                ownerPid: pid,
                bundleId: app?.bundleIdentifier,
                appName: app?.localizedName ?? info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: bounds
            )
        }
        return FrontWindow.pick(from: windows, ownPid: ProcessInfo.processInfo.processIdentifier)
    }
}
#endif

/// Why the window in front is not read.
public enum SkipReason: Equatable, Sendable {
    /// A password manager, an authenticator, System Settings or a system dialog.
    case neverRead
    /// The person asked Hippocampus to skip this app.
    case excluded
    /// A browser window that shows it is private.
    case privateWindow
    /// Secure text entry is on: nothing is read anywhere until it ends.
    case passwordField
}

/// The capture helper's rules for which windows are read, as Try it needs
/// them to say why a window is not.
public struct ReadRules: Sendable, Equatable {
    /// The person's own exclusions, by app identifier, matched exactly as
    /// the helper's `Denylist.appIsDenied` matches them.
    public let excludedApps: Set<String>

    public init(excludedApps: Set<String> = []) {
        self.excludedApps = excludedApps
    }

    /// Nil when the window is read.
    public func skipReason(for window: FrontWindow) -> SkipReason? {
        if Self.isNeverRead(window.bundleId) { return .neverRead }
        if excludedApps.contains(window.bundleId) { return .excluded }
        if Self.isBrowser(window.bundleId), let title = window.title, Self.titleIsPrivate(title) {
            return .privateWindow
        }
        return nil
    }

    // MARK: - Copies of the helper's lists

    /// System agents whose windows the capture helper never reads, matched by
    /// exact identifier. Mirrors `SensitiveCaptureDenylist.appBundles` minus
    /// Hippocampus's own apps (those are `ReadProof.ownBundleIds`, never read
    /// because they are memory viewers).
    static let neverReadApps: Set<String> = [
        // System Settings, which held the Passwords pane before macOS 15.
        "com.apple.systempreferences",
        // System consent and sign-in dialogs: the permission prompt, the
        // administrator password prompt, the Touch ID or password sheet, a
        // file server's sign-in and iCloud Keychain's approval prompt.
        "com.apple.usernotificationcenter", "com.apple.securityagent",
        "com.apple.localauthentication.uiagent", "com.apple.netauthagent",
        "com.apple.security.keychain-circle-notification",
        // The lock screen and screen saver, and the login window.
        "com.apple.loginwindow", "com.apple.screensaver.engine", "com.apple.screensaver",
    ]

    /// Password managers and authenticators the helper never reads, matched by
    /// identifier family: a family covers its own identifier and every
    /// identifier beneath it, a whole dot-separated label at a time (so
    /// "com.1password" covers "com.1password.1password" but not
    /// "com.1passwordfan"). Mirrors
    /// `SensitiveCaptureDenylist.passwordManagerFamilies` exactly.
    static let neverReadPasswordManagerFamilies: Set<String> = [
        // Apple Passwords and its menu bar extra, and Keychain Access.
        "com.apple.passwords", "com.apple.keychainaccess",
        // 1Password 8 and 7, the browser helper, and 1Password for Safari.
        "com.1password", "2bua8c4s2c.com.1password", "com.agilebits",
        "com.bitwarden", // Bitwarden and its helper
        "com.dashlane",
        "com.lastpass", // the app, the earlier App Store app, LastPass for Safari
        "org.keepassxc", "org.keepassx", // KeePassXC, and the identifier older builds used
        // Keeper, direct and from the App Store, and Keeper for Safari.
        "com.keepersecurity.passwordmanager", "com.callpod.keepermac", "com.keepersecurity.safari",
        "com.nordsec.nordpass", "com.nordpass", // NordPass, direct and from the App Store
        "me.proton.pass", "me.proton.authenticator", // Proton Pass and Proton Authenticator
        "in.sinew.enpass-desktop", // Enpass
        "com.sibersystems.roboform", "com.sibersystems.roboformmac", // RoboForm, direct and App Store
        "com.markmcguill.strongbox", // Strongbox, every edition
        "com.hicknhacksoftware.macpass", // MacPass
        "com.outercorner.secrets", "com.outercorner.secrets-safari", // Secrets, and Secrets for Safari
        "com.keepassium", // KeePassium and KeePassium Pro
        "net.zetetic.strip", // Codebook
        "com.safeincloud", // SafeInCloud
        "com.mseven.msecuremac", // mSecure
        "pw.buttercup", // Buttercup
        "net.antelle.keeweb", // KeeWeb
        "com.app77.pwsafemac", // pwSafe
        "com.zoho.vault", // Zoho Vault
        "com.bitdefender.securepass", // Bitdefender SecurePass
        "com.symantec.nortonpasswordmanager", // Norton's password manager for Safari
        "com.avira.passwordmanager", // Avira Password Manager
        "com.eset.passwordmanager", // ESET Password Manager
        "com.keepsolid.passwarden", // Passwarden
        "com.pcloud.pcloudpass", // pCloud Pass
        "com.synology.c2.password", // Synology C2 Password
        "net.devolutions.authenticator", // Devolutions Password Manager
        "com.lockitsolutions.lockit", // Lockit
        "design.codeux.authpass", // AuthPass
        "com.onekeepass", // OneKeePass
        "com.2stable.passwords", // Password Manager by 2Stable
        "app.elpass.macos", // Elpass
        "app.bramble.desktop", // Bramble
        "app.rowel.desktop", // Rowel
        "com.jumpcloud.pwm", // JumpCloud Password Manager
        "org.qtpass", // QtPass
        "app.padloc", // Padloc
        "com.ascendo.datavaultmac", // Data Vault
        "com.logmeonce", // LogMeOnce
        "com.softwareops.myeyesonlyprouniversal", // My Eyes Only
        "com.saaspass.password-manager-authenticator", // SAASPASS
        // Authenticator apps, which show sign-in codes.
        "com.neilsardesai.step-two-mac", // Step Two
        "maccatalyst.de.cooperrs.authenticator", // OTP Auth
        "com.2stable.2fa", // Authenticator App by 2Stable
        "com.zoho.iamlogin", // Zoho OneAuth
        "com.yubico.yubioath", // Yubico Authenticator
        "io.ente.auth", // Ente Auth
        "com.twofas.org", // 2FAS Auth and 2FAS Pass
        "me.tij.raivo-macos", // Raivo
        "com.okta.mobile", // Okta Verify
        "com.symantec.vip-access", // Symantec VIP Access
        "com.pingidentity.pingid", // PingID
        "com.secureauth.secureauth-otp", // SecureAuth Passcode
    ]

    /// Browsers, whose private windows are skipped (the helper's
    /// `BrowserPixelCapturePolicy.browserBundleIds`).
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
    ]

    /// Words in a window title that mark a private window (the helper's
    /// `BrowserPixelCapturePolicy.privateTitleMarkers`): Firefox's "— Private
    /// Browsing", Chrome's "New Incognito Tab", Edge's "New InPrivate tab".
    /// Safari shows a private window in its top bar only, which setup cannot
    /// see before the read; the helper skips such a window all the same.
    static let privateTitleMarkers = ["incognito", "private browsing", "private window", "inprivate"]

    /// Whether the helper never reads this app, by its rule
    /// (`SensitiveCaptureDenylist.isNeverReadApp`): an exact `neverReadApps`
    /// identifier, or one in or under a `neverReadPasswordManagerFamilies`
    /// family. Case-insensitive.
    static func isNeverRead(_ bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        if neverReadApps.contains(id) { return true }
        var family = Substring(id)
        while !family.isEmpty {
            if neverReadPasswordManagerFamilies.contains(String(family)) { return true }
            guard let dot = family.lastIndex(of: ".") else { return false }
            family = family[..<dot]
        }
        return false
    }

    static func isBrowser(_ bundleId: String) -> Bool {
        browserBundleIds.contains(bundleId)
    }

    static func titleIsPrivate(_ title: String) -> Bool {
        let folded = title.lowercased()
        return privateTitleMarkers.contains { folded.contains($0) }
    }
}

/// The person's own exclusions, from the file the capture helper reads
/// (`~/Library/Application Support/MCI/denylist.toml`, the helper's
/// `defaultDenylistPath`). Only app identifiers matter to Try it.
public enum PersonExclusions {
    public static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MCI").appendingPathComponent("denylist.toml")
    }

    /// The `pattern` of each `[[denylist]]` table whose `kind` is
    /// "appBundle". A line it cannot read adds nothing; the helper's own
    /// parser decides what is skipped, this only explains it.
    public static func appBundles(fromTOML text: String) -> Set<String> {
        var bundles: Set<String> = []
        var kind: String?
        var pattern: String?
        func flush() {
            if kind == "appBundle", let pattern, !pattern.isEmpty { bundles.insert(pattern) }
            kind = nil
            pattern = nil
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "[[denylist]]" {
                flush()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].count >= 2, parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else {
                continue
            }
            let value = String(parts[1].dropFirst().dropLast())
            switch parts[0] {
            case "kind": kind = value
            case "pattern": pattern = value
            default: break
            }
        }
        flush()
        return bundles
    }

    /// The exclusions on this Mac; none when the file is missing.
    public static func load(from url: URL? = defaultURL) -> Set<String> {
        guard let url, let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return appBundles(fromTOML: text)
    }
}

/// Secure text entry: while it is on, the helper reads nothing at all
/// (`CarbonSecureEventInputProbe`), so Try it says a password field is in use.
public enum SecureTextEntry {
    public static func isOn() -> Bool {
        #if canImport(Carbon)
        IsSecureEventInputEnabled()
        #else
        false
        #endif
    }
}
