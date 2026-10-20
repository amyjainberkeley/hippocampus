import XCTest
@testable import RecallUIKit

/// Resume's seam to the Mac, as text only: the scripts it would send each
/// browser are pinned here and never run, so no test reaches a browser or
/// asks macOS anything.
final class SystemResumeTests: XCTestCase {
    private let chromium = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    /// Private windows are never read (SPEC-DELTA 3): Incognito and the
    /// other private windows in the Chrome family have a `mode` other than
    /// "normal", so only normal windows' tabs are asked for.
    func testTheChromeFamilyIsAskedOnlyForItsNormalWindowsTabs() {
        XCTAssertEqual(AppleScriptOpenTabs.script(for: "com.google.Chrome"),
                       "tell application id \"com.google.Chrome\" to get URL of every tab of "
                           + "(every window whose mode is \"normal\")")
        for browser in chromium {
            let script = AppleScriptOpenTabs.script(for: browser)
            XCTAssertEqual(script, "tell application id \"\(browser)\" to get URL of every tab of "
                               + "(every window whose mode is \"normal\")", browser)
        }
    }

    func testArcIsAskedOnlyForItsWindowsThatAreNotPrivate() {
        XCTAssertEqual(AppleScriptOpenTabs.script(for: "company.thebrowser.Browser"),
                       "tell application id \"company.thebrowser.Browser\" to get URL of every tab of "
                           + "(every window whose incognito is false)")
    }

    /// Safari can't tell a script which of its windows are private, so it is
    /// never asked and its tabs open again.
    func testSafariAndBrowsersThatCantLeaveOutPrivateWindowsAreNeverAsked() {
        for browser in ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
                        "com.example.Browser", ""] {
            XCTAssertNil(AppleScriptOpenTabs.script(for: browser), browser)
        }
        XCTAssertFalse(AppleScriptOpenTabs.browsers.contains("com.apple.Safari"))
    }

    func testEveryBrowserResumeChecksHasAScriptThatLeavesOutPrivateWindows() {
        XCTAssertEqual(AppleScriptOpenTabs.browsers, Set(chromium + ["company.thebrowser.Browser"]))
        for browser in AppleScriptOpenTabs.browsers {
            let script = try? XCTUnwrap(AppleScriptOpenTabs.script(for: browser))
            XCTAssertNotNil(script, browser)
            XCTAssertFalse(script?.contains("of every window\"") ?? true, browser)
            XCTAssertFalse(script?.hasSuffix("every tab of every window") ?? true, "\(browser) reads every window")
            XCTAssertTrue(script?.contains("whose") ?? false, browser)
        }
    }
}
