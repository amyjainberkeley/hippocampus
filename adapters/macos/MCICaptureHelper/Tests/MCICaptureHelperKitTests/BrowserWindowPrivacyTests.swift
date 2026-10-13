import Foundation
import XCTest
@testable import MCICaptureHelperKit

/// The Automation probe (RULINGS G8): it runs only when the person already
/// allowed it, and its answer can only add a skip.
final class BrowserWindowPrivacyTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 25, width: 1200, height: 775)
    private var captured: FocusedWindow {
        FocusedWindow(bundleId: "com.google.Chrome", windowId: 42, axRect: rect)
    }
    private let context = WorkflowContext(appBundleId: "com.google.Chrome")

    func testAnIncognitoWindowWithTheCapturedBoundsIsPrivate() {
        XCTAssertEqual(BrowserWindowPrivacyProbe.mode(of: rect, in: "incognito\t0\t25\t1200\t800\n"), true)
        XCTAssertEqual(BrowserWindowPrivacyProbe.mode(of: rect, in: "normal\t0\t25\t1200\t800\n"), false)
        XCTAssertNil(BrowserWindowPrivacyProbe.mode(of: rect, in: "incognito\t10\t25\t1210\t800\n"),
                     "a listing without the captured window says nothing about it")
    }

    func testAnyIncognitoWindowSharingTheBoundsMakesItPrivate() {
        let normal = "normal\t0\t25\t1200\t800\n"
        let incognito = "incognito\t0\t25\t1200\t800\n"
        XCTAssertEqual(BrowserWindowPrivacyProbe.mode(of: rect, in: normal + incognito), true)
        XCTAssertEqual(BrowserWindowPrivacyProbe.mode(of: rect, in: incognito + normal), true)
        XCTAssertEqual(BrowserWindowPrivacyProbe.mode(of: rect, in: normal + normal), false)
    }

    func testAMalformedListingNeverClaimsAnything() {
        for listing in ["", "normal", "\t0\t25\t1200\t800", "normal\t0\t25\t1200\t800\textra",
                        "normal\tNaN\t25\t1200\t800", "incognito\t0\t25\t1200"] {
            XCTAssertNil(BrowserWindowPrivacyProbe.mode(of: rect, in: listing), listing)
        }
    }

    func testNoAnswerFromTheBrowserIsNotPrivate() {
        for outcome in [AppleScriptOutcome.timeout, .scriptError, .success("garbage")] {
            let probe = BrowserWindowPrivacyProbe(runner: Fixed(outcome))
            XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: captured))
        }
        XCTAssertTrue(BrowserWindowPrivacyProbe(runner: Fixed(.success("incognito\t0\t25\t1200\t800\n")))
            .isPrivate(for: context, capturedWindow: captured))
    }

    func testMissingOrMismatchedCaptureIdentityNeverRunsScript() {
        struct ForbiddenRunner: AppleScriptRunner {
            func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
                XCTFail("No script may run without captured-window identity")
                return .scriptError
            }
        }
        let probe = BrowserWindowPrivacyProbe(runner: ForbiddenRunner())
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: nil))
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: FocusedWindow(bundleId: "com.google.Chrome", windowId: 42)))
        XCTAssertFalse(probe.isPrivate(for: WorkflowContext(appBundleId: "com.apple.Safari"),
                                       capturedWindow: FocusedWindow(bundleId: "com.apple.Safari", windowId: 1, axRect: rect)))
    }

    func testTheListingIsAskedOfTheBrowserItTalksTo() {
        for bundle in BrowserWindowPrivacyProbe.scripts.keys {
            let runner = Listing(["normal\t0\t25\t1200\t800\n"])
            let window = FocusedWindow(bundleId: bundle, windowId: 42, axRect: rect)
            _ = BrowserWindowPrivacyProbe(runner: runner).isPrivate(for: WorkflowContext(appBundleId: bundle), capturedWindow: window)
            XCTAssertEqual(runner.targets, [bundle])
        }
    }

    func testListingScriptsUseARealTabSeparatorAndNeverReadAddresses() {
        // Inside `tell application "Google Chrome"`, `tab` is the browser's
        // tab class and coerces to the text "tab": every row failed to parse.
        for (bundle, script) in BrowserWindowPrivacyProbe.scripts {
            XCTAssertFalse(script.contains("& tab &"), bundle)
            XCTAssertTrue(script.contains("character id 9"), bundle)
            XCTAssertFalse(script.contains("URL"), bundle)
        }
    }

    func testAFreshListingIsReusedForAWindowItHolds() {
        let runner = Listing(["normal\t0\t25\t1200\t800\n"])
        let clock = Clock()
        let window = captured
        let probe = BrowserWindowPrivacyProbe(runner: runner, now: { clock.read() })
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: window))
        clock.advance(0.5)
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: window))
        XCTAssertEqual(runner.runs, 1)
        clock.advance(0.6)
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: window))
        XCTAssertEqual(runner.runs, 2, "an expired listing is taken again")
    }

    func testAWindowTheCachedListingHasNotSeenIsLookedUpAfresh() {
        let newRect = CGRect(x: 300, y: 125, width: 900, height: 675)
        let newWindow = FocusedWindow(bundleId: "com.google.Chrome", windowId: 77, axRect: newRect)
        let before = "normal\t0\t25\t1200\t800\n"
        let after = before + "incognito\t300\t125\t1200\t800\n"
        let runner = Listing([before, after])
        let probe = BrowserWindowPrivacyProbe(runner: runner, now: { Date(timeIntervalSince1970: 1_000) })
        XCTAssertFalse(probe.isPrivate(for: context, capturedWindow: captured))
        // A private window opens: the cached listing does not hold it.
        XCTAssertTrue(probe.isPrivate(for: context, capturedWindow: newWindow))
        XCTAssertEqual(runner.runs, 2)
    }

    func testEveryBrowserVariantIsReadAndOnlyChromiumOnesAreAsked() {
        for bundle in ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.apple.SafariTechnologyPreview",
                       "com.apple.Safari", "company.thebrowser.Browser"] {
            XCTAssertTrue(BrowserPixelCapturePolicy.browserBundleIds.contains(bundle))
            XCTAssertNil(BrowserWindowPrivacyProbe.scripts[bundle])
        }
    }

    // MARK: - Fixtures

    private struct Fixed: AppleScriptRunner {
        let outcome: AppleScriptOutcome
        init(_ outcome: AppleScriptOutcome) { self.outcome = outcome }
        func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome { outcome }
    }

    private final class Listing: AppleScriptRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [String]
        private(set) var runs = 0
        private(set) var targets: [String] = []
        init(_ outputs: [String]) { self.outputs = outputs }
        func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
            XCTFail("the probe names the browser it asks")
            return .scriptError
        }
        func run(_ source: String, target: String, timeoutMs: Int) -> AppleScriptOutcome {
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(timeoutMs, BrowserWindowPrivacyProbe.timeoutMs)
            runs += 1
            targets.append(target)
            return .success(outputs.count > 1 ? outputs.removeFirst() : outputs[0])
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }
}
