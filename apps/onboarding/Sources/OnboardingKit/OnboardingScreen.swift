// SPDX-License-Identifier: TBD-private
//
// The four-screen setup (Welcome, Permissions, Promise, Try it) and the
// panels that open on their own. A route is the name the app passes in
// `MCI_ONBOARDING_STEP` (`hippocampus://setup/<panel>` becomes the panel's
// route) and the name the resume file holds.

import Foundation

/// One screen of the four-screen setup, in order.
public enum OnboardingScreen: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case welcome = 0
    case permissions = 1
    case promise = 2
    case tryIt = 3

    /// A flow route. "done" was the old last step and means Try it; panel
    /// routes and the retired steps are not screens.
    public init?(launchRoute: String) {
        switch OnboardingLaunch.normalized(launchRoute) {
        case "welcome": self = .welcome
        case "permissions": self = .permissions
        case "promise": self = .promise
        case "try-it", "done": self = .tryIt
        default: return nil
        }
    }

    public var id: Int { rawValue }

    /// The name the resume file holds and the app may pass.
    public var routeName: String {
        switch self {
        case .welcome: "welcome"
        case .permissions: "permissions"
        case .promise: "promise"
        case .tryIt: "try-it"
        }
    }
}

/// A single screen opened by route, outside the flow, with one "Done".
public enum OnboardingPanel: String, Sendable, Equatable, CaseIterable {
    case appAccess = "app-access"
    case browserExtension = "browser-extension"
    case mcpServers = "mcp-servers"
    /// What is never read: the Promise screen's lines, read-only.
    case neverRead = "never-read"

    /// "allowlist" is the old Preferences route to app access; "trust",
    /// "denylist" and "privacy" opened the old trust screen.
    public init?(launchRoute: String) {
        switch OnboardingLaunch.normalized(launchRoute) {
        case "app-access", "allowlist": self = .appAccess
        case "browser-extension": self = .browserExtension
        case "mcp-servers": self = .mcpServers
        case "never-read", "trust", "denylist", "privacy": self = .neverRead
        default: return nil
        }
    }

    public var routeName: String { rawValue }
}

/// What a launch route opens.
public enum OnboardingLaunch: Equatable, Sendable {
    /// The flow at a screen, or resuming from the saved screen when nil.
    case flow(OnboardingScreen?)
    case panel(OnboardingPanel)

    /// Retired steps ("how-it-works", "hotkey", "live-preview", "retention",
    /// "prepare-brain", "connect-ai"), unknown names and no route at all
    /// open the flow where it left off.
    public static func parse(_ raw: String?) -> OnboardingLaunch {
        guard let raw else { return .flow(nil) }
        if let panel = OnboardingPanel(launchRoute: raw) { return .panel(panel) }
        return .flow(OnboardingScreen(launchRoute: raw))
    }

    /// Panels are for people who already said yes. Before consent every
    /// route opens the flow.
    public func resolved(consentGiven: Bool) -> OnboardingLaunch {
        if case .panel = self, !consentGiven { return .flow(nil) }
        return self
    }

    /// Only the flow keeps its place in the resume file. A panel keeps its
    /// state in memory, so opening one never moves where setup resumes.
    public var usesResumeFile: Bool {
        if case .flow = self { return true }
        return false
    }

    static func normalized(_ route: String) -> String {
        route.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
