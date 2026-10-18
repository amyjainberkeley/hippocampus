import XCTest
@testable import OnboardingKit

/// Which window Try it reads, and why it would be skipped. Every window
/// here is made up: nothing lists this Mac's windows.
final class FrontWindowTests: XCTestCase {
    private let ownPid: Int32 = 500
    private let page = CGRect(x: 0, y: 0, width: 900, height: 700)

    private func window(
        _ bundleId: String?, _ name: String? = nil, title: String? = nil, pid: Int32 = 900,
        layer: Int = 0, alpha: Double = 1, bounds: CGRect? = nil
    ) -> ListedWindow {
        ListedWindow(ownerPid: pid, bundleId: bundleId, appName: name, title: title,
                     layer: layer, alpha: alpha, bounds: bounds ?? page)
    }

    func testTheWindowInFrontIsTheFirstOrdinaryOneThatIsNotHippocampus() {
        let list = [
            // Setup's own window, then the app's other windows.
            window("ai.hippocampus", "Hippocampus", title: "Hippocampus", pid: ownPid),
            window("ai.hippocampus", "Hippocampus", pid: 600),
            window("recall-ui", "Hippocampus"),
            // The menu bar, a floating panel and a sliver.
            window("com.apple.controlcenter", "Control Center", layer: 25),
            window("com.example.overlay", "Overlay", alpha: 0),
            window("com.example.sliver", "Sliver", bounds: CGRect(x: 0, y: 0, width: 40, height: 700)),
            window(nil, "Window Server"),
            window("com.apple.Safari", "Safari", title: "  Pricing | Stripe "),
            window("com.apple.Notes", "Notes", title: "Launch plan"),
        ]
        XCTAssertEqual(FrontWindow.pick(from: list, ownPid: ownPid),
                       FrontWindow(bundleId: "com.apple.Safari", appName: "Safari", title: "Pricing | Stripe"))
    }

    func testMacOSsOwnSurfacesAreNeverTheWindowInFront() {
        let list = [
            window("com.apple.WindowManager", "WindowManager", title: "Stage strip"),
            window("com.apple.dock", "Dock"),
            window("com.apple.Spotlight", "Spotlight", title: "Spotlight"),
            window("com.apple.notificationcenterui", "Notification Center"),
            window("com.apple.TextEdit", "TextEdit", title: "Draft"),
        ]
        XCTAssertEqual(FrontWindow.pick(from: list, ownPid: ownPid)?.bundleId, "com.apple.TextEdit")
    }

    func testAnUntitledWindowAndAnUnnamedAppStillRead() {
        let picked = FrontWindow.pick(from: [window("com.apple.TextEdit", nil, title: "  ")], ownPid: ownPid,
                                      nameFor: { _ in "TextEdit" })
        XCTAssertEqual(picked, FrontWindow(bundleId: "com.apple.TextEdit", appName: "TextEdit", title: nil))
    }

    func testAnEmptyDesktopHasNoWindowInFront() {
        XCTAssertNil(FrontWindow.pick(from: [], ownPid: ownPid))
        XCTAssertNil(FrontWindow.pick(from: [window("ai.hippocampus", pid: ownPid)], ownPid: ownPid))
    }

    // MARK: - Read rules

    func testNeverReadAppsAreSkippedByTheHelpersRule() {
        let rules = ReadRules()
        for bundle in ["com.apple.systempreferences", "com.apple.Passwords", "com.1password.1password",
                       "com.bitwarden.desktop", "COM.APPLE.KEYCHAINACCESS", "com.apple.loginwindow"] {
            XCTAssertEqual(rules.skipReason(for: FrontWindow(bundleId: bundle, appName: "App", title: nil)), .neverRead, bundle)
        }
        // A family covers whole labels only.
        XCTAssertNil(rules.skipReason(for: FrontWindow(bundleId: "com.1passwordfan.app", appName: "Fan", title: nil)))
    }

    func testThePersonsExclusionsAreSkippedExactly() {
        let rules = ReadRules(excludedApps: ["com.tinyspeck.slackmacgap"])
        XCTAssertEqual(rules.skipReason(for: FrontWindow(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", title: nil)),
                       .excluded)
        XCTAssertNil(rules.skipReason(for: FrontWindow(bundleId: "com.tinyspeck.slackmacgap.helper", appName: "Slack", title: nil)))
    }

    func testOnlyABrowserWindowThatShowsItIsPrivateIsSkipped() {
        let rules = ReadRules()
        let privateTitles: [(String, String)] = [
            ("com.google.Chrome", "New Incognito Tab"), ("org.mozilla.firefox", "Mozilla Firefox — Private Browsing"),
            ("com.microsoft.edgemac", "New InPrivate tab"), ("com.brave.Browser", "Private Window"),
        ]
        for (bundle, title) in privateTitles {
            XCTAssertEqual(rules.skipReason(for: FrontWindow(bundleId: bundle, appName: "Browser", title: title)),
                           .privateWindow, title)
        }
        // A browser is read like any window (RULINGS G8), and a page that
        // is not private is read.
        XCTAssertNil(rules.skipReason(for: FrontWindow(bundleId: "com.apple.Safari", appName: "Safari", title: "Pricing | Stripe")))
        XCTAssertNil(rules.skipReason(for: FrontWindow(bundleId: "com.apple.Safari", appName: "Safari", title: nil)))
        // Only a browser's title can mark it private.
        XCTAssertNil(rules.skipReason(for: FrontWindow(bundleId: "com.apple.Notes", appName: "Notes", title: "Incognito notes")))
    }

    // MARK: - The person's exclusions file

    func testTheExclusionsFileGivesItsAppEntriesOnly() {
        let toml = """
        # My exclusions
        [[denylist]]
        kind = "appBundle"
        pattern = "com.tinyspeck.slackmacgap"

        [[denylist]]
        pattern = "https://bank.example.com/"
        kind = "urlPrefix"

        [[denylist]]
        kind = "windowTitleSubstring"
        pattern = "Payroll"

        [[denylist]]
        kind = "appBundle"
        pattern = "com.apple.MobileSMS"
        """
        XCTAssertEqual(PersonExclusions.appBundles(fromTOML: toml), ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"])
    }

    func testAnExclusionsFileItCannotReadAddsNothing() throws {
        XCTAssertEqual(PersonExclusions.appBundles(fromTOML: "kind = appBundle\npattern = \"x\""), [])
        XCTAssertEqual(PersonExclusions.appBundles(fromTOML: "[[denylist]]\nkind = \"appBundle\"\npattern = \"\""), [])
        let missing = try temporaryDirectory().appendingPathComponent("denylist.toml")
        XCTAssertEqual(PersonExclusions.load(from: missing), [])
        XCTAssertEqual(PersonExclusions.load(from: nil), [])
    }

    func testAnExclusionsFileOnDiskIsRead() throws {
        let file = try temporaryDirectory().appendingPathComponent("denylist.toml")
        try "[[denylist]]\nkind = \"appBundle\"\npattern = \"com.example.app\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(PersonExclusions.load(from: file), ["com.example.app"])
    }
}
