#if canImport(AppKit)
import Foundation
import AppKit

/// Per-browser truth source for "is the Hippocampus extension installed?"
///
/// Pre-PR #206 audit, both rows probed the same hard-coded path
/// (`/usr/local/bin/hippocampus-native-host`), which nothing in the build
/// pipeline ever populates — so the onboarding badge had zero causal
/// relationship with reality. This implementation reports per-browser
/// truth:
///
///   - Safari: presence of `HippocampusSafariExtension.appex` inside the
///     shipped `.app` (`/Applications/Hippocampus.app/Contents/PlugIns/`).
///     Detecting whether Safari has *enabled* the extension requires
///     `SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier:)`,
///     which is async + only works from the host app bundle that ships
///     the appex. Treated as out-of-scope here per the dispatch fallback:
///     "appex bundled = capable; show Open Safari Settings as the verify
///     step." The slide CTA "Open Safari → Settings" is that verify step.
///
///   - Chromium (Chrome / Arc / Brave / Edge): presence of the native-
///     messaging host manifest JSON inside the per-browser
///     `NativeMessagingHosts/` directory (paths matrix in
///     `docs/research/browser-extension-audit.md` §K). Presence is the
///     canonical signal for "the user can `chrome.runtime.connectNative`
///     into our host" — see audit §F and §Q3.
@MainActor
public final class RealBrowserDetector: BrowserDetector, @unchecked Sendable {
    private let fileChecker: any FileChecker
    private let safariAppexPath: String
    private let chromiumHostManifestDirs: [String: String]
    private let chromiumHostManifestFilename: String

    public init(
        fileChecker: any FileChecker = FoundationFileChecker(),
        safariAppexPath: String = RealBrowserDetector.defaultSafariAppexPath,
        chromiumHostManifestDirs: [String: String] = RealBrowserDetector.defaultChromiumHostManifestDirs(),
        chromiumHostManifestFilename: String = "ai.hippocampus.native_messaging.json"
    ) {
        self.fileChecker = fileChecker
        self.safariAppexPath = safariAppexPath
        self.chromiumHostManifestDirs = chromiumHostManifestDirs
        self.chromiumHostManifestFilename = chromiumHostManifestFilename
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
        case .safari:
            return fileChecker.fileExists(atPath: safariAppexPath)
                ? .installed
                : .notInstalled
        case .chromium:
            guard let dir = chromiumHostManifestDirs[browser.id] else {
                return .unknown
            }
            let manifestPath = "\(dir)/\(chromiumHostManifestFilename)"
            return fileChecker.fileExists(atPath: manifestPath)
                ? .installed
                : .notInstalled
        }
    }

    // MARK: - Default paths

    public static let defaultSafariAppexPath =
        "/Applications/Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex"

    /// Per-Chromium-family `NativeMessagingHosts/` directory under the
    /// current user's `~/Library/Application Support`. Source of truth:
    /// audit memo §K (`docs/research/browser-extension-audit.md:138-145`).
    public static func defaultChromiumHostManifestDirs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        let appSupport = homeDirectory
            .appendingPathComponent("Library/Application Support")
            .path
        return [
            "com.google.Chrome":          "\(appSupport)/Google/Chrome/NativeMessagingHosts",
            "company.thebrowser.Browser": "\(appSupport)/Arc/User Data/NativeMessagingHosts",
            "com.brave.Browser":          "\(appSupport)/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "com.microsoft.edgemac":      "\(appSupport)/Microsoft Edge/NativeMessagingHosts",
        ]
    }
}
#endif
