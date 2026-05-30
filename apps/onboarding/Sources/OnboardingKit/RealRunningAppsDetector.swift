// SPDX-License-Identifier: TBD-private
//
// RealRunningAppsDetector — NSWorkspace-backed enumeration of running
// regular apps for the V2-P10 allowlist slide.
//
// Filters:
//   - `activationPolicy == .regular` (skip helpers, daemons, agents).
//   - `bundleIdentifier != nil` (skip ad-hoc / unsigned processes).
//   - Skip the onboarding process itself.

import Foundation
#if canImport(AppKit)
import AppKit

public struct RealRunningAppsDetector: RunningAppsDetector {
    public init() {}

    public func detect() async -> [DetectedApp] {
        await MainActor.run {
            let ownBundle = Bundle.main.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { running -> DetectedApp? in
                    guard let bundleId = running.bundleIdentifier else { return nil }
                    if let own = ownBundle, bundleId == own { return nil }
                    let name = running.localizedName
                        ?? running.bundleURL?.deletingPathExtension().lastPathComponent
                        ?? bundleId
                    return DetectedApp(bundleId: bundleId, displayName: name)
                }
            // Dedupe by bundleId — older macOS versions occasionally
            // surface the same app twice (multi-process). Keep first.
            var seen: Set<String> = []
            var result: [DetectedApp] = []
            for app in apps where !seen.contains(app.bundleId) {
                seen.insert(app.bundleId)
                result.append(app)
            }
            return result.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        }
    }
}
#endif
