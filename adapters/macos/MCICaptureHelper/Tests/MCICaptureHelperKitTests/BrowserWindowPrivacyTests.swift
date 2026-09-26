import Foundation
import XCTest
@testable import MCICaptureHelperKit

final class BrowserWindowPrivacyTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 25, width: 1200, height: 775)
    private let url = "https://example.org/page"
    private var captured: FocusedWindow {
        FocusedWindow(bundleId: "com.google.Chrome", windowId: 42, axRect: rect)
    }
    private func allows(_ output: String) -> Bool {
        BrowserWindowPrivacyProbe.isNormalWindow(.success(output), expectedURL: url, capturedRect: rect)
    }
    func testNormalModeRequiresUniqueCapturedBoundsAndExactURL() {
        XCTAssertTrue(allows("normal\t0\t25\t1200\t800\t\(url)\n"))
        XCTAssertFalse(allows("normal\t0\t25\t1200\t800\thttps://example.org/other\n"))
        XCTAssertFalse(allows("normal\t10\t25\t1210\t800\t\(url)\n"))
    }
    func testNormalFrontWindowCannotAuthorizePrivateCapturedWindow() {
        let normal = "normal\t100\t100\t1300\t875\t\(url)\n"
        let privateWindow = "incognito\t0\t25\t1200\t800\t\(url)\n"
        XCTAssertFalse(allows(normal + privateWindow))
        XCTAssertFalse(allows(privateWindow + normal))
    }
    func testOverlappingWindowBoundsAreAmbiguousEvenIfBothNormal() {
        let normal = "normal\t0\t25\t1200\t800\t\(url)\n"
        XCTAssertFalse(allows(normal + normal))
        XCTAssertFalse(allows(normal + "incognito\t0\t25\t1200\t800\t\(url)\n"))
    }
    func testMalformedMissingUnknownAndSensitiveWindowsNeverPermitPixels() {
        for output in ["", "normal", "\t0\t25\t1200\t800\t\(url)",
                       "normal\t0\t25\t1200\t800\t\(url)\textra", "normal\tNaN\t25\t1200\t800\t\(url)",
                       "normal\t0\t25\t1200\t800\t"] {
            XCTAssertFalse(allows(output))
        }
        for result in [AppleScriptOutcome.timeout, .scriptError] {
            XCTAssertFalse(BrowserWindowPrivacyProbe.isNormalWindow(result, expectedURL: url, capturedRect: rect))
        }
        XCTAssertFalse(BrowserWindowPrivacyProbe.isNormalWindow(
            .success("normal\t0\t25\t1200\t800\thttps://secure.chase.com/"),
            expectedURL: "https://secure.chase.com/", capturedRect: rect))
    }
    func testMissingOrMismatchedCaptureIdentityNeverRunsScript() {
        struct ForbiddenRunner: AppleScriptRunner {
            func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
                XCTFail("No script may run without captured-window identity")
                return .scriptError
            }
        }
        let probe = BrowserWindowPrivacyProbe(runner: ForbiddenRunner(), focusedWindow: { nil })
        let context = WorkflowContext(appBundleId: "com.google.Chrome", url: url)
        XCTAssertFalse(probe.permitsPixels(for: context, capturedWindow: nil))
        XCTAssertFalse(probe.permitsPixels(for: context, capturedWindow: captured))
    }
    func testFocusChangeDuringQueryRejectsSameBrowserSameURL() {
        final class Focus: @unchecked Sendable {
            private let lock = NSLock()
            private var value: FocusedWindow
            init(_ value: FocusedWindow) { self.value = value }
            func read() -> FocusedWindow { lock.lock(); defer { lock.unlock() }; return value }
            func change(_ value: FocusedWindow) { lock.lock(); defer { lock.unlock() }; self.value = value }
        }
        struct Runner: AppleScriptRunner {
            let focus: Focus
            let output: String
            func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
                focus.change(FocusedWindow(bundleId: "com.google.Chrome", windowId: 99,
                                           axRect: CGRect(x: 0, y: 25, width: 1200, height: 775)))
                return .success(output)
            }
        }
        let focus = Focus(captured)
        let probe = BrowserWindowPrivacyProbe(
            runner: Runner(focus: focus, output: "normal\t0\t25\t1200\t800\t\(url)\n"),
            focusedWindow: { focus.read() })
        XCTAssertFalse(probe.permitsPixels(for: WorkflowContext(appBundleId: "com.google.Chrome", url: url), capturedWindow: captured))
    }
    func testUnsupportedBrowserVariantsStayExcluded() {
        for bundle in ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.apple.SafariTechnologyPreview"] {
            XCTAssertTrue(BrowserPixelCapturePolicy.excludedBundleIds.contains(bundle))
            XCTAssertNil(BrowserWindowPrivacyProbe.scripts[bundle])
        }
    }
}
