#if canImport(AppKit)
import XCTest
@testable import OnboardingKit

/// Per-browser truth source for `checkExtensionInstalled` — drives every
/// branch via `StubFileChecker` (no live filesystem touched). The matrix
/// matches `docs/research/browser-extension-audit.md` §K.
@MainActor
final class RealBrowserDetectorTests: XCTestCase {

    // MARK: - Fixture paths (must match RealBrowserDetector defaults)

    private let safariAppex =
        "/Applications/Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex"

    private static let fixtureAppSupport =
        "/Users/fixture/Library/Application Support"

    private static let chromiumDirs: [String: String] = [
        "com.google.Chrome":          "\(fixtureAppSupport)/Google/Chrome/NativeMessagingHosts",
        "company.thebrowser.Browser": "\(fixtureAppSupport)/Arc/User Data/NativeMessagingHosts",
        "com.brave.Browser":          "\(fixtureAppSupport)/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "com.microsoft.edgemac":      "\(fixtureAppSupport)/Microsoft Edge/NativeMessagingHosts",
    ]

    private let hostManifestFilename = "ai.hippocampus.native_messaging.json"

    private func chromiumManifest(_ bundleId: String) -> String {
        "\(Self.chromiumDirs[bundleId]!)/\(hostManifestFilename)"
    }

    // MARK: - Builders

    private func makeDetector(existing: Set<String>) -> RealBrowserDetector {
        let stub = StubFileChecker(existingPaths: existing)
        return RealBrowserDetector(
            fileChecker: stub,
            safariAppexPath: safariAppex,
            chromiumHostManifestDirs: Self.chromiumDirs,
            chromiumHostManifestFilename: hostManifestFilename
        )
    }

    private let safari   = DetectedBrowser(id: "com.apple.Safari", name: "Safari", kind: .safari)
    private let chrome   = DetectedBrowser(id: "com.google.Chrome", name: "Chrome", kind: .chromium)
    private let arc      = DetectedBrowser(id: "company.thebrowser.Browser", name: "Arc", kind: .chromium)
    private let brave    = DetectedBrowser(id: "com.brave.Browser", name: "Brave", kind: .chromium)
    private let edge     = DetectedBrowser(id: "com.microsoft.edgemac", name: "Edge", kind: .chromium)

    // MARK: - Safari

    /// Per dispatch fallback: appex bundled = capable; the slide CTA
    /// "Open Safari → Settings" is the user-side verify step. We treat
    /// "capable" as `.installed` for the badge.
    func testSafariAppexPresentReportsInstalled() {
        let detector = makeDetector(existing: [safariAppex])
        XCTAssertEqual(detector.checkExtensionInstalled(for: safari), .installed)
    }

    /// The "disabled in Safari" case is not directly detectable here (it
    /// requires `SFSafariExtensionManager.getStateOfSafariExtension`,
    /// async + bundle-coupled). With the appex still present on disk,
    /// the detector reports `.installed` and lets the slide CTA carry
    /// the verify step. This test pins that mapping so a future regress
    /// to "always notInstalled" would fail loudly.
    func testSafariAppexPresentButDisabledInSafariStillReportsInstalled() {
        // Simulated state: the appex IS bundled into Hippocampus.app,
        // but the user has *not* toggled Hippocampus on in Safari →
        // Extensions. With the present probe, that distinction is not
        // observable; we surface `.installed` and rely on the slide
        // CTA to make the user verify.
        let detector = makeDetector(existing: [safariAppex])
        XCTAssertEqual(detector.checkExtensionInstalled(for: safari), .installed)
    }

    func testSafariAppexAbsentReportsNotInstalled() {
        let detector = makeDetector(existing: [])
        XCTAssertEqual(detector.checkExtensionInstalled(for: safari), .notInstalled)
    }

    /// Safari truth source MUST NOT consult any of the Chromium host-
    /// manifest paths — pre-audit, both rows shared one probe; this
    /// test pins the separation.
    func testSafariProbeIgnoresChromiumHostManifests() {
        // Every Chromium host manifest exists; the Safari appex does
        // not. Safari must still report `.notInstalled`.
        let allChromiumManifests = Set(
            Self.chromiumDirs.keys.map { chromiumManifest($0) }
        )
        let detector = makeDetector(existing: allChromiumManifests)
        XCTAssertEqual(detector.checkExtensionInstalled(for: safari), .notInstalled)
    }

    // MARK: - Chromium (per-browser independence)

    func testChromeManifestPresentReportsInstalled() {
        let detector = makeDetector(existing: [chromiumManifest(chrome.id)])
        XCTAssertEqual(detector.checkExtensionInstalled(for: chrome), .installed)
    }

    func testChromeManifestAbsentReportsNotInstalled() {
        let detector = makeDetector(existing: [])
        XCTAssertEqual(detector.checkExtensionInstalled(for: chrome), .notInstalled)
    }

    func testArcManifestPresentReportsInstalled() {
        let detector = makeDetector(existing: [chromiumManifest(arc.id)])
        XCTAssertEqual(detector.checkExtensionInstalled(for: arc), .installed)
    }

    func testArcManifestAbsentReportsNotInstalled() {
        let detector = makeDetector(existing: [])
        XCTAssertEqual(detector.checkExtensionInstalled(for: arc), .notInstalled)
    }

    func testBraveManifestPresentReportsInstalled() {
        let detector = makeDetector(existing: [chromiumManifest(brave.id)])
        XCTAssertEqual(detector.checkExtensionInstalled(for: brave), .installed)
    }

    func testBraveManifestAbsentReportsNotInstalled() {
        let detector = makeDetector(existing: [])
        XCTAssertEqual(detector.checkExtensionInstalled(for: brave), .notInstalled)
    }

    func testEdgeManifestPresentReportsInstalled() {
        let detector = makeDetector(existing: [chromiumManifest(edge.id)])
        XCTAssertEqual(detector.checkExtensionInstalled(for: edge), .installed)
    }

    func testEdgeManifestAbsentReportsNotInstalled() {
        let detector = makeDetector(existing: [])
        XCTAssertEqual(detector.checkExtensionInstalled(for: edge), .notInstalled)
    }

    /// Installing one Chromium-family extension must not flip the status
    /// of a *different* browser's row. Pre-audit, both rows shared a
    /// single probe so installing Chrome would have flipped Safari too.
    func testChromiumBrowsersAreIndependent() {
        let detector = makeDetector(existing: [chromiumManifest(chrome.id)])
        XCTAssertEqual(detector.checkExtensionInstalled(for: chrome), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: arc), .notInstalled)
        XCTAssertEqual(detector.checkExtensionInstalled(for: brave), .notInstalled)
        XCTAssertEqual(detector.checkExtensionInstalled(for: edge), .notInstalled)
    }

    func testAllFourChromiumBrowsersInstalledIndependently() {
        let detector = makeDetector(existing: Set(
            [chrome.id, arc.id, brave.id, edge.id].map { chromiumManifest($0) }
        ))
        XCTAssertEqual(detector.checkExtensionInstalled(for: chrome), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: arc), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: brave), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: edge), .installed)
    }

    /// A browser kind=.chromium with a bundle id we don't have a path
    /// mapping for should report `.unknown` (not crash, not lie). Future
    /// Chromium-family browsers (Vivaldi, Opera, etc.) fall here until
    /// the path matrix is extended.
    func testUnknownChromiumBundleIdReportsUnknown() {
        let detector = makeDetector(existing: [])
        let unknown = DetectedBrowser(
            id: "com.vivaldi.Vivaldi",
            name: "Vivaldi",
            kind: .chromium
        )
        XCTAssertEqual(detector.checkExtensionInstalled(for: unknown), .unknown)
    }

    // MARK: - Default path resolution

    /// Pins the per-browser path matrix to the audit memo §K table.
    /// If a directory name moves under macOS, this test fails and the
    /// audit memo must be re-checked.
    func testDefaultChromiumHostManifestDirsMatchAuditMemoMatrix() {
        let dirs = RealBrowserDetector.defaultChromiumHostManifestDirs(
            homeDirectory: URL(fileURLWithPath: "/Users/fixture")
        )
        XCTAssertEqual(
            dirs["com.google.Chrome"],
            "/Users/fixture/Library/Application Support/Google/Chrome/NativeMessagingHosts"
        )
        XCTAssertEqual(
            dirs["company.thebrowser.Browser"],
            "/Users/fixture/Library/Application Support/Arc/User Data/NativeMessagingHosts"
        )
        XCTAssertEqual(
            dirs["com.brave.Browser"],
            "/Users/fixture/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        )
        XCTAssertEqual(
            dirs["com.microsoft.edgemac"],
            "/Users/fixture/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        )
    }

    func testDefaultSafariAppexPathPointsAtShippedBundlePlugIns() {
        XCTAssertEqual(
            RealBrowserDetector.defaultSafariAppexPath,
            "/Applications/Hippocampus.app/Contents/PlugIns/HippocampusSafariExtension.appex"
        )
    }
}
#endif
