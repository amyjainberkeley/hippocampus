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
    func testListingScriptsUseARealTabSeparator() {
        // Inside `tell application "Google Chrome"`, `tab` is the browser's
        // tab class and coerces to the text "tab": every row failed to parse
        // and every Chrome frame was refused.
        for (bundle, script) in BrowserWindowPrivacyProbe.scripts {
            XCTAssertFalse(script.contains("& tab &"), bundle)
            XCTAssertTrue(script.contains("character id 9"), bundle)
        }
    }

    private final class Listing: AppleScriptRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [String]
        private(set) var runs = 0
        init(_ outputs: [String]) { self.outputs = outputs }
        func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(timeoutMs, BrowserWindowPrivacyProbe.timeoutMs)
            runs += 1
            return .success(outputs.count > 1 ? outputs.removeFirst() : outputs[0])
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    func testFreshListingIsReusedWithoutAnotherQuery() {
        let runner = Listing(["normal\t0\t25\t1200\t800\t\(url)\n"])
        let clock = Clock()
        let window = captured
        let probe = BrowserWindowPrivacyProbe(runner: runner, focusedWindow: { window }, now: { clock.read() })
        let context = WorkflowContext(appBundleId: "com.google.Chrome", url: url)
        XCTAssertTrue(probe.permitsPixels(for: context, capturedWindow: window))
        clock.advance(0.5)
        XCTAssertTrue(probe.permitsPixels(for: context, capturedWindow: window))
        XCTAssertEqual(runner.runs, 1)
        clock.advance(0.6)
        XCTAssertTrue(probe.permitsPixels(for: context, capturedWindow: window))
        XCTAssertEqual(runner.runs, 2, "an expired listing is taken again")
    }

    func testCachedListingNeverAuthorizesAWindowItHasNotSeen() {
        let newRect = CGRect(x: 300, y: 125, width: 900, height: 675)
        let newWindow = FocusedWindow(bundleId: "com.google.Chrome", windowId: 77, axRect: newRect)
        let before = "normal\t0\t25\t1200\t800\t\(url)\n"
        let after = before + "incognito\t300\t125\t1200\t800\t\(url)\n"
        let runner = Listing([before, after])
        let clock = Clock()
        final class Focus: @unchecked Sendable {
            var window: FocusedWindow?
        }
        let focus = Focus()
        focus.window = captured
        let probe = BrowserWindowPrivacyProbe(runner: runner, focusedWindow: { focus.window }, now: { clock.read() })
        let context = WorkflowContext(appBundleId: "com.google.Chrome", url: url)
        XCTAssertTrue(probe.permitsPixels(for: context, capturedWindow: captured))
        // A private window opens: the cached listing does not contain it.
        focus.window = newWindow
        XCTAssertFalse(probe.permitsPixels(for: context, capturedWindow: newWindow))
        XCTAssertEqual(runner.runs, 1, "a denial from a very fresh listing is not retried")
        clock.advance(0.3)
        XCTAssertFalse(probe.permitsPixels(for: context, capturedWindow: newWindow))
        XCTAssertEqual(runner.runs, 2, "a stale denial is retried, and the private window is still refused")
    }

    func testUnsupportedBrowserVariantsStayExcluded() {
        for bundle in ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.apple.SafariTechnologyPreview"] {
            XCTAssertTrue(BrowserPixelCapturePolicy.excludedBundleIds.contains(bundle))
            XCTAssertNil(BrowserWindowPrivacyProbe.scripts[bundle])
        }
    }
}
