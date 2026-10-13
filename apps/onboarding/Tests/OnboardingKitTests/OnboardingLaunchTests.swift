import XCTest
@testable import OnboardingKit

final class OnboardingLaunchTests: XCTestCase {
    func testEveryScreenOpensFromItsOwnRoute() {
        XCTAssertEqual(OnboardingScreen.allCases.map(\.routeName), ["welcome", "permissions", "promise", "try-it"])
        for screen in OnboardingScreen.allCases {
            XCTAssertEqual(OnboardingScreen(launchRoute: screen.routeName), screen)
            XCTAssertEqual(OnboardingLaunch.parse(screen.routeName), .flow(screen))
        }
    }

    func testTheOldLastStepOpensTryIt() {
        XCTAssertEqual(OnboardingLaunch.parse("done"), .flow(.tryIt))
    }

    func testPanelRoutesAndTheirOldNamesOpenPanels() {
        XCTAssertEqual(OnboardingLaunch.parse("app-access"), .panel(.appAccess))
        XCTAssertEqual(OnboardingLaunch.parse("allowlist"), .panel(.appAccess))
        XCTAssertEqual(OnboardingLaunch.parse("browser-extension"), .panel(.browserExtension))
        XCTAssertEqual(OnboardingLaunch.parse("mcp-servers"), .panel(.mcpServers))
        for route in ["never-read", "trust", "denylist", "privacy"] {
            XCTAssertEqual(OnboardingLaunch.parse(route), .panel(.neverRead), route)
        }
        for panel in OnboardingPanel.allCases {
            XCTAssertEqual(OnboardingPanel(launchRoute: panel.routeName), panel)
        }
    }

    func testRetiredUnknownAndMissingRoutesResumeTheFlow() {
        for route in ["how-it-works", "hotkey", "live-preview", "retention", "prepare-brain", "connect-ai", "nope", ""] {
            XCTAssertEqual(OnboardingLaunch.parse(route), .flow(nil), route)
        }
        XCTAssertEqual(OnboardingLaunch.parse(nil), .flow(nil))
    }

    func testRoutesIgnoreCaseAndSurroundingSpace() {
        XCTAssertEqual(OnboardingLaunch.parse("  Try-It \n"), .flow(.tryIt))
        XCTAssertEqual(OnboardingLaunch.parse("TRUST"), .panel(.neverRead))
    }

    func testBeforeConsentEveryPanelRouteOpensTheFlow() {
        for panel in OnboardingPanel.allCases {
            XCTAssertEqual(OnboardingLaunch.panel(panel).resolved(consentGiven: false), .flow(nil))
            XCTAssertEqual(OnboardingLaunch.panel(panel).resolved(consentGiven: true), .panel(panel))
        }
        XCTAssertEqual(OnboardingLaunch.flow(.promise).resolved(consentGiven: false), .flow(.promise))
    }

    func testEveryOldStepHasARouteThatOpensIt() {
        for step in OnboardingStep.allCases {
            XCTAssertEqual(OnboardingStep(launchRoute: step.routeName), step, step.routeName)
        }
    }

    // MARK: - The resume file

    func testTheResumeFileHoldsTheRouteName() throws {
        let file = try temporaryDirectory().appendingPathComponent(".onboarding-state")
        let store = FileOnboardingStateStore(path: file)
        store.save(OnboardingScreen.permissions)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "permissions\n")
        XCTAssertEqual(store.loadScreen(), .permissions)

        store.save(OnboardingStep.retention)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "retention\n")
        XCTAssertEqual(store.load(), .retention)
        XCTAssertNil(store.loadScreen(), "a retired step is not a screen")
    }

    func testAnOldNumericResumeFileLoadsAsNothing() throws {
        let file = try temporaryDirectory().appendingPathComponent(".onboarding-state")
        let store = FileOnboardingStateStore(path: file)
        // "3" was Permissions in the thirteen-step flow and is Try it's index now.
        for legacy in ["3\n", "12", " 0 \n"] {
            try legacy.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertNil(store.loadRoute(), legacy)
            XCTAssertNil(store.loadScreen(), legacy)
            XCTAssertNil(store.load(), legacy)
        }
    }

    func testAResumeFileThatIsNotARouteLoadsAsNothing() throws {
        let file = try temporaryDirectory().appendingPathComponent(".onboarding-state")
        let store = FileOnboardingStateStore(path: file)
        for junk in ["", "try it", "../etc", "permissions\nwelcome", String(repeating: "a", count: 80)] {
            try junk.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertNil(store.loadRoute(), junk)
        }
        store.clear()
        XCTAssertNil(store.loadRoute())
    }

    func testTheInMemoryStoreKeepsRoutesForBothFlows() {
        let store = InMemoryOnboardingStateStore(initial: .retention)
        XCTAssertEqual(store.loadRoute(), "retention")
        store.save(OnboardingScreen.tryIt)
        XCTAssertEqual(store.loadScreen(), .tryIt)
        XCTAssertNil(store.load())
        XCTAssertEqual(InMemoryOnboardingStateStore(route: "promise").loadScreen(), .promise)
    }
}
