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
}
