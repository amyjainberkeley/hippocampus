// SPDX-License-Identifier: TBD-private
//
// RunningAppsDetector — surfaces currently-running, user-launched apps
// (bundle id + display name) for the V2-P10 allowlist slide.
//
// Headless-testable via the `RunningAppsDetector` protocol. Real impl
// in `RealRunningAppsDetector` uses `NSWorkspace.runningApplications`
// + filters to regular-activation-policy processes to skip helpers,
// daemons, etc.

import Foundation

/// A user-visible app the onboarding UI offers as an opt-in candidate.
public struct DetectedApp: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let displayName: String

    public init(bundleId: String, displayName: String) {
        self.bundleId = bundleId
        self.displayName = displayName
    }
}

/// Snapshot of running, user-visible apps. Sorted by display name.
public protocol RunningAppsDetector: Sendable {
    func detect() async -> [DetectedApp]
}

public struct StubRunningAppsDetector: RunningAppsDetector {
    private let apps: [DetectedApp]

    public init(apps: [DetectedApp] = Self.defaultApps) {
        self.apps = apps
    }

    public func detect() async -> [DetectedApp] {
        apps.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    public static let defaultApps: [DetectedApp] = [
        DetectedApp(bundleId: "com.apple.MobileSMS", displayName: "Messages"),
        DetectedApp(bundleId: "com.apple.mail", displayName: "Mail"),
        DetectedApp(bundleId: "com.spotify.client", displayName: "Spotify"),
        DetectedApp(bundleId: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        DetectedApp(bundleId: "com.apple.dt.Xcode", displayName: "Xcode"),
    ]
}
