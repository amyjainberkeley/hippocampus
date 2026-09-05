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

    public static let appBundles: Set<String> = [
        // Memory viewers must not turn recalled evidence into new observations.
        "ai.hippocampus", "recall-ui", "onboarding",
        "com.1password.1password", "com.1password.1password7",
        "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.dashlane",
        "com.lastpass.lastpass", "com.apple.keychainaccess",
        "com.apple.passwords", "com.apple.systempreferences",
        // System consent and authentication dialogs are not work context.
        "com.apple.usernotificationcenter", "com.apple.securityagent",
    ]

    public static let sensitiveDomains: Set<String> = [
        "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
        "citibank.com", "capitalone.com", "americanexpress.com",
        "schwab.com", "fidelity.com", "vanguard.com", "paypal.com",
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com",
    ]

    public func appIsDenied(bundleId: String) -> Bool {
        Self.appBundles.contains(bundleId.lowercased()) || user.appIsDenied(bundleId: bundleId)
    }

    public func urlIsDenied(_ url: String) -> Bool {
        if user.urlIsDenied(url) { return true }
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return Self.sensitiveDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func windowTitleIsDenied(_ title: String) -> Bool {
        if user.windowTitleIsDenied(title) { return true }
        let folded = title.lowercased()
        return ["incognito", "private browsing", "private window", "inprivate"]
            .contains { folded.contains($0) }
    }
}
