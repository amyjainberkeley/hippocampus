import Foundation

/// Global capture consent admits ordinary applications. An app catalogue is
/// optional scoping, not evidence that a password field is safe.
public enum CaptureAdmissionPolicy: Sendable {
    case approvedApplications
    case ordinaryApplications

    func admits(bundleID: String?, approved: Set<String>) -> Bool {
        guard let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch self {
        case .approvedApplications: return approved.contains(bundleID)
        case .ordinaryApplications: return true
        }
    }
}

/// Always applied in production in addition to the owner's exclusions.
public struct SensitiveCaptureDenylist: DenylistProbe {
    private let user: Denylist

    public init(entries: [DenylistEntry]) {
        user = Denylist(entries: entries)
    }

    /// Never read, by exact identifier (lowercase; matching ignores case).
    /// Password managers are in `passwordManagerFamilies`.
    public static let appBundles: Set<String> = [
        // Memory viewers must not turn recalled evidence into new observations.
        "ai.hippocampus", "recall-ui", "onboarding",
        // System Settings, which held the Passwords pane before macOS 15.
        "com.apple.systempreferences",
        // System consent and sign-in dialogs are not work context: the
        // permission prompt, the administrator password prompt, the Touch ID
        // or password sheet, a file server's sign-in and iCloud Keychain's
        // approval prompt (each read from its bundle on macOS 26.5).
        "com.apple.usernotificationcenter", "com.apple.securityagent",
        "com.apple.localauthentication.uiagent", "com.apple.netauthagent",
        "com.apple.security.keychain-circle-notification",
        // The lock screen and screen saver: the Mac is not in use, and the
        // login window shows the account name and password field.
        "com.apple.loginwindow", "com.apple.screensaver.engine", "com.apple.screensaver",
    ]

    /// Password managers and authenticator apps, by identifier family. A
    /// family covers its own identifier and every identifier beneath it, a
    /// whole dot-separated label at a time: "com.bitwarden" covers
    /// "com.bitwarden.desktop" and "com.bitwarden.desktop.helper", never
    /// "com.bitwardenfan". Lowercase; matching ignores case.
    ///
    /// Every family stands for identifiers read in October 2026 from the
    /// app itself (Apple's, on macOS 26.5), Apple's App Store catalogue, the
    /// Homebrew cask that installs the app, or the developer's own source.
    /// `NeverReadPasswordManagersTests.verified` lists each identifier and
    /// where it was read, and fails for a family no identifier backs.
    public static let passwordManagerFamilies: Set<String> = [
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

    public static let sensitiveDomains: Set<String> = [
        "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
        "citibank.com", "capitalone.com", "americanexpress.com",
        "schwab.com", "fidelity.com", "vanguard.com", "paypal.com",
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com",
        // Password managers' web vaults: 1Password's Canadian and European
        // accounts, Bitwarden's and LastPass's European ones, Google
        // Password Manager, Proton Pass, Keeper, NordPass, Zoho Vault and
        // RoboForm (each answered at its address in October 2026).
        "1password.ca", "1password.eu", "bitwarden.eu", "lastpass.eu", "passwords.google.com",
        "pass.proton.me", "keepersecurity.com", "keepersecurity.eu", "nordpass.com",
        "vault.zoho.com", "vault.zoho.eu", "online.roboform.com",
    ]

    /// Whether Hippocampus never reads this app, whatever the case of its
    /// identifier: an app in `appBundles`, or one in or under a family in
    /// `passwordManagerFamilies`. Applies on every path and every display.
    public static func isNeverReadApp(_ bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        if appBundles.contains(id) { return true }
        var family = Substring(id)
        while !family.isEmpty {
            if passwordManagerFamilies.contains(String(family)) { return true }
            guard let dot = family.lastIndex(of: ".") else { return false }
            family = family[..<dot]
        }
        return false
    }

    public func appIsDenied(bundleId: String) -> Bool {
        Self.isNeverReadApp(bundleId) || user.appIsDenied(bundleId: bundleId)
    }

    public func urlIsDenied(_ url: String) -> Bool {
        if user.urlIsDenied(url) { return true }
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return Self.sensitiveDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func windowTitleIsDenied(_ title: String) -> Bool {
        if user.windowTitleIsDenied(title) { return true }
        return BrowserPixelCapturePolicy.titleIsPrivate(title)
    }
}
