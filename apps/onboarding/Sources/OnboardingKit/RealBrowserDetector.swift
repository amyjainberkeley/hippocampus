#if canImport(AppKit)
import Foundation
import AppKit

@MainActor
public final class RealBrowserDetector: BrowserDetector, @unchecked Sendable {
    private let nativeHostPath: String

    public init(nativeHostPath: String = "/usr/local/bin/hippocampus-native-host") {
        self.nativeHostPath = nativeHostPath
    }

    public func installedBrowsers() -> [DetectedBrowser] {
        knownBrowsers.compactMap { entry in
            if NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.bundleId
            ) != nil {
                return DetectedBrowser(
                    id: entry.bundleId,
                    name: entry.name,
                    kind: entry.kind
                )
            }
            return nil
        }
    }

    public func checkExtensionInstalled(for browser: DetectedBrowser) -> ExtensionStatus {
        switch browser.kind {
        case .chromium:
            let hostManifestExists = FileManager.default.fileExists(atPath: nativeHostPath)
            return hostManifestExists ? .installed : .notInstalled
        case .safari:
            let hostManifestExists = FileManager.default.fileExists(atPath: nativeHostPath)
            return hostManifestExists ? .installed : .notInstalled
        }
    }
}
#endif
