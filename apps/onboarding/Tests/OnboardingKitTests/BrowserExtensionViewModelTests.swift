import XCTest
@testable import OnboardingKit

@MainActor
final class BrowserExtensionViewModelTests: XCTestCase {

    private let chrome = DetectedBrowser(id: "com.google.Chrome", name: "Chrome", kind: .chromium)
    private let safari = DetectedBrowser(id: "com.apple.Safari", name: "Safari", kind: .safari)

    private func makeVM(browsers: [DetectedBrowser] = []) -> (BrowserExtensionViewModel, StubBrowserDetector) {
        let detector = StubBrowserDetector(browsers: browsers)
        let vm = BrowserExtensionViewModel(detector: detector)
        return (vm, detector)
    }

    private final class FakeLauncher: BrowserLauncher, @unchecked Sendable {
        var openCalls: [(String, String)] = []
        var revealCalls: [URL] = []
        var returnSuccess = true

        func openInBrowser(browserName: String, url: String) -> Bool {
            openCalls.append((browserName, url))
            return returnSuccess
        }

        func revealInFinder(_ url: URL) {
            revealCalls.append(url)
        }
    }

    private struct FakeLocator: ChromiumExtensionLocator {
        let url: URL?
        func bundledChromiumExtensionURL() -> URL? { url }
    }

    func testRowsPopulatedFromDetector() {
        let (vm, _) = makeVM(browsers: [chrome, safari])
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertEqual(vm.rows[0].browser.name, "Chrome")
        XCTAssertEqual(vm.rows[1].browser.name, "Safari")
        XCTAssertEqual(vm.rows[0].extensionStatus, .unknown)
    }

    func testNoBrowsersDetected() {
        let (vm, _) = makeVM(browsers: [])
        XCTAssertFalse(vm.hasBrowsers)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func testCheckExtensionUpdatesStatus() {
        let (vm, detector) = makeVM(browsers: [chrome])
        detector.stubbedStatuses["com.google.Chrome"] = .installed
        vm.checkExtension(for: "com.google.Chrome")
        XCTAssertEqual(vm.rows[0].extensionStatus, .installed)
        XCTAssertEqual(detector.checkCallCount, 1)
    }

    func testCheckExtensionNotInstalled() {
        let (vm, detector) = makeVM(browsers: [safari])
        detector.stubbedStatuses["com.apple.Safari"] = .notInstalled
        vm.checkExtension(for: "com.apple.Safari")
        XCTAssertEqual(vm.rows[0].extensionStatus, .notInstalled)
    }

    func testCheckExtensionUnknownBrowserIsNoop() {
        let (vm, detector) = makeVM(browsers: [chrome])
        vm.checkExtension(for: "com.nonexistent.Browser")
        XCTAssertEqual(detector.checkCallCount, 0)
        XCTAssertEqual(vm.rows[0].extensionStatus, .unknown)
    }

    /// PR-3 regression contract: fresh rows must start in `.unknown`,
    /// which the `BrowserExtensionSlide.extensionStatusBadge` now
    /// renders as an animated "checking…" hourglass instead of the
    /// prior `EmptyView()`. If a future refactor changes the default
    /// state (say, to `.notInstalled`) the slide would show a scary
    /// orange x-circle to every user on first paint before any probe
    /// ran — this test guards the invariant that drives the loading
    /// badge UX.
    func testFreshRowStartsInUnknownState() {
        let (vm, _) = makeVM(browsers: [chrome, safari])
        for row in vm.rows {
            XCTAssertEqual(
                row.extensionStatus, .unknown,
                "Row for \(row.browser.name) should start in .unknown; " +
                "the slide's `extensionStatusBadge(.unknown)` case renders " +
                "the animated hourglass loading badge (see PR-3)."
            )
        }
    }

    func testRefreshAllStatusesUpdatesEveryRowOncePerBrowser() {
        let (vm, detector) = makeVM(browsers: [chrome, safari])
        detector.stubbedStatuses["com.google.Chrome"] = .installed
        detector.stubbedStatuses["com.apple.Safari"] = .notInstalled
        vm.refreshAllStatuses()
        XCTAssertEqual(vm.rows[0].extensionStatus, .installed)
        XCTAssertEqual(vm.rows[1].extensionStatus, .notInstalled)
        XCTAssertEqual(detector.checkCallCount, 2)
    }

    // MARK: - Chromium install flow (added 2026-05-24 after CEO
    // reported the chrome:// URL scheme silently failing).

    func testInstallChromiumSpawnsBrowserAtExtensionsPage() {
        let launcher = FakeLauncher()
        let dir = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/Resources/Extensions/Chromium")
        let locator = FakeLocator(url: dir)
        let detector = StubBrowserDetector(browsers: [chrome])
        let vm = BrowserExtensionViewModel(
            detector: detector,
            extensionLocator: locator,
            browserLauncher: launcher
        )
        vm.installAction(for: chrome)
        XCTAssertEqual(launcher.openCalls.count, 1)
        XCTAssertEqual(launcher.openCalls.first?.0, "Chrome")
        XCTAssertEqual(launcher.openCalls.first?.1, "chrome://extensions")
        XCTAssertEqual(launcher.revealCalls, [dir])
        XCTAssertEqual(vm.rows[0].installInstructions?.unpackedDirPath, dir.path)
        XCTAssertTrue(vm.rows[0].installInstructions?.didOpenBrowser ?? false)
        XCTAssertEqual(vm.rows[0].installInstructions?.browserName, "Chrome")
    }

    func testInstallChromiumSurfacesFailureWhenOpenFails() {
        let launcher = FakeLauncher()
        launcher.returnSuccess = false
        let vm = BrowserExtensionViewModel(
            detector: StubBrowserDetector(browsers: [chrome]),
            extensionLocator: FakeLocator(url: nil),
            browserLauncher: launcher
        )
        vm.installAction(for: chrome)
        XCTAssertEqual(vm.rows[0].installInstructions?.didOpenBrowser, false)
        XCTAssertNil(vm.rows[0].installInstructions?.unpackedDirPath)
        XCTAssertEqual(launcher.revealCalls, []) // no reveal when no bundled dir
    }

    func testInstallChromiumWithArcUsesArcAsBrowserName() {
        let arc = DetectedBrowser(id: "company.thebrowser.Browser", name: "Arc", kind: .chromium)
        let launcher = FakeLauncher()
        let vm = BrowserExtensionViewModel(
            detector: StubBrowserDetector(browsers: [arc]),
            extensionLocator: FakeLocator(url: URL(fileURLWithPath: "/tmp/x")),
            browserLauncher: launcher
        )
        vm.installAction(for: arc)
        XCTAssertEqual(launcher.openCalls.first?.0, "Arc")
        XCTAssertEqual(vm.rows[0].installInstructions?.browserName, "Arc")
    }

    func testInstallSafariDoesNotSpawnChromium() {
        let launcher = FakeLauncher()
        let vm = BrowserExtensionViewModel(
            detector: StubBrowserDetector(browsers: [safari]),
            extensionLocator: FakeLocator(url: nil),
            browserLauncher: launcher
        )
        vm.installAction(for: safari)
        XCTAssertTrue(launcher.openCalls.isEmpty, "Safari install must not invoke chromium launcher")
    }
}
