// SPDX-License-Identifier: TBD-private
import Foundation

public protocol BinaryLocator: Sendable {
    func helperPath() -> URL?
    func agentPath() -> URL?
    func recallUIPath() -> URL?
    func onboardingPath() -> URL?
    func knownSafeAppsPath() -> URL?
}

public struct BundleBinaryLocator: BinaryLocator, Sendable {
    private let bundleURL: URL

    public init(bundle: Bundle = .main) {
        self.bundleURL = bundle.bundleURL
    }

    public func helperPath() -> URL? {
        resolve("MCICaptureHelper")
    }

    public func agentPath() -> URL? {
        resolve("mci-agent")
    }

    public func recallUIPath() -> URL? {
        resolve("recall-ui")
    }

    public func onboardingPath() -> URL? {
        resolve("onboarding")
    }

    public func knownSafeAppsPath() -> URL? {
        let bundleResources = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("known-safe-apps.toml")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            return bundleResources
        }
        return nil
    }

    private func resolve(_ name: String) -> URL? {
        // Path 1: inside .app bundle → Contents/MacOS/<name>
        let inBundle = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: inBundle.path) {
            return inBundle
        }

        // Path 2: `swift run` dev mode — binary is at
        // <pkg>/.build/debug/Hippocampus, siblings are elsewhere.
        // Walk up from the executable to the workspace root.
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let devBuild = execURL
            .deletingLastPathComponent()  // .build/debug/
            .deletingLastPathComponent()  // .build/
            .deletingLastPathComponent()  // apps/hippocampus/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repo root

        let devPaths: [String]
        switch name {
        case "MCICaptureHelper":
            devPaths = [
                "adapters/macos/MCICaptureHelper/.build/debug/mci-capture-helper",
                "adapters/macos/MCICaptureHelper/.build/release/mci-capture-helper",
            ]
        case "mci-agent":
            devPaths = [
                "target/debug/mci-agent",
                "target/release/mci-agent",
            ]
        case "recall-ui":
            devPaths = [
                "apps/recall-ui/.build/debug/recall-ui",
                "apps/recall-ui/.build/release/recall-ui",
            ]
        case "onboarding":
            devPaths = [
                "apps/onboarding/.build/debug/onboarding",
                "apps/onboarding/.build/release/onboarding",
            ]
        default:
            devPaths = []
        }

        for relative in devPaths {
            let candidate = devBuild.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
