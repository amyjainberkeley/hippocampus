// HippocampusURLRouteTests — cycle 8.48. Verifies the pure parser
// that `HippocampusApp.application(_:open:)` uses to decide what to
// do with a `hippocampus://…` URL.
//
// The AppDelegate itself needs a real NSApplication run-loop to
// exercise; keeping the parse logic in `HippocampusURLRoute.parse`
// means we can test the routing decisions headlessly here.

import XCTest
@testable import HippocampusKit

final class HippocampusURLRouteTests: XCTestCase {

    func testPreferencesRecognizesEachExactSectionPath() throws {
        let sections: [(String, PreferencesSection)] = [
            ("general", .general), ("capture", .capture), ("sources", .sources),
            ("privacy", .privacy), ("advanced", .advanced), ("about", .about),
        ]
        for (path, section) in sections {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences/\(path)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .openPreferences(section: section), path)
        }
    }

    func testPreferencesRejectsUnknownAndNoncanonicalPaths() throws {
        for suffix in [
            "", "/", "/unknown", "/General", "/general/", "/general/extra",
            "//general", "/./general", "/privacy/../general", "/%67eneral",
            "/general%2F", "/general%00", "/general;capture", "/general%20",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences\(suffix)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, suffix)
        }
    }

    func testPreferencesRejectsQueriesAndFragmentsInsteadOfPerformingActions() throws {
        for suffix in [
            "?", "?section=capture", "?enable=1", "?install=claude",
            "?show=1", "?tab=privacy&capture=on", "#", "#capture",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://preferences/sources\(suffix)"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, suffix)
        }
    }

    func testPreferencesRejectsDecoratedAuthorities() throws {
        for authority in [
            "user@preferences", "user:password@preferences", "preferences:123",
            "preferences:", "%70references", "preferences.", "preferences.example.com",
        ] {
            let url = try XCTUnwrap(URL(string: "hippocampus://\(authority)/general"))
            XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown, authority)
        }
    }

    /// Setup's "Try Again" restarts remembering in place (onboarding-app
    /// contract section 3b); only the exact URL does.
    func testRestartIsAnExactRoute() throws {
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: "hippocampus://restart"))), .restartRemembering)
        for decorated in ["hippocampus://restart/", "hippocampus://restart?now=1", "hippocampus://restart#x",
                          "hippocampus://restart/app", "hippocampus://user@restart"] {
            XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: decorated))), .unknown, decorated)
        }
    }

    /// The window's Add Browser Extension… opens setup's extension panel
    /// (SPEC 3.5); only the exact URL does, and no other panel is a link.
    func testSetupsBrowserExtensionPanelIsAnExactRoute() throws {
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: "hippocampus://setup/browser-extension"))),
                       .showSetupPanel(.browserExtension))
        for decorated in ["hippocampus://setup", "hippocampus://setup/", "hippocampus://setup/browser-extension/",
                          "hippocampus://setup/browser-extension?install=chrome", "hippocampus://setup/browser-extension#x",
                          "hippocampus://setup/Browser-Extension", "hippocampus://setup/browser-extension/more",
                          "hippocampus://user@setup/browser-extension", "hippocampus://setup:1/browser-extension",
                          "hippocampus://setup/app-access", "hippocampus://setup/never-read",
                          "hippocampus://setup/mcp-servers", "hippocampus://setup/%62rowser-extension"] {
            XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: decorated))), .unknown, decorated)
        }
    }

    /// Web Pages' note and Looked Up's empty state open that panel, not
    /// Preferences › AI Tools, which says nothing about browsers. They ask
    /// the app that started the window on the typed route a pane takes
    /// (`.browserExtension`), whose link is this exact route.
    func testTheWindowsAddBrowserExtensionButtonsOpenSetupsExtensionPanel() throws {
        let recall = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("recall-ui/Sources", isDirectory: true)
        let places = recall.appendingPathComponent("RecallUI/Places", isDirectory: true)
        let webPages = try String(contentsOf: places.appendingPathComponent("WebPagesPlace.swift"), encoding: .utf8)
        let lookedUp = try String(contentsOf: places.appendingPathComponent("LookedUpPlace.swift"), encoding: .utf8)
        let destinations = try String(contentsOf: recall.appendingPathComponent("RecallUIKit/WorkspacePreferences.swift"),
                                      encoding: .utf8)
        let link = try XCTUnwrap(destinations.range(of: #"hippocampus://setup/[a-z-]+"#, options: .regularExpression))
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: String(destinations[link])))),
                       .showSetupPanel(.browserExtension))
        XCTAssertTrue(webPages.contains("WorkspacePreferencesRouter.shared.open(.browserExtension"))
        for (name, source) in [("WebPagesPlace", webPages), ("LookedUpPlace", lookedUp)] {
            XCTAssertTrue(source.contains("BrowserExtensionSetup.open()"), name)
            XCTAssertFalse(source.contains("open(.sources"), "\(name) still opens Preferences › AI Tools")
            XCTAssertFalse(source.contains("withApplicationAt:"), "\(name) opens a link Launch Services may give the window")
        }
    }

    // MARK: - Recall route (existing surfaces, regression-guarded)

    func testRecallWithoutTabQuery() {
        let url = URL(string: "hippocampus://recall")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
    }

    func testRecallWithTabQuery() {
        let url = URL(string: "hippocampus://recall?tab=brief")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: "brief", focusEventId: nil, openPopup: false)
        )
    }

    func testRecallWithPopupQuery() {
        let url = URL(string: "hippocampus://recall?popup=1")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: nil, focusEventId: nil, openPopup: true)
        )
    }

    func testRecallCarriesFocusedEvent() {
        let url = URL(string: "hippocampus://recall?tab=search&focus=42")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(url),
            .openRecall(tab: "search", focusEventId: 42, openPopup: false)
        )
    }

    func testRecallRejectsZeroAndMalformedFocusValues() {
        let zero = URL(string: "hippocampus://recall?focus=0")!
        let malformed = URL(string: "hippocampus://recall?focus=not-a-number")!
        XCTAssertEqual(
            HippocampusURLRoute.parse(zero),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
        XCTAssertEqual(
            HippocampusURLRoute.parse(malformed),
            .openRecall(tab: nil, focusEventId: nil, openPopup: false)
        )
    }

    // MARK: - Onboarding route (cycle 8.48 — new)

    func testShowOnboardingPathForm() {
        // Canonical form — matches the Raycast-style path pattern.
        let url = URL(string: "hippocampus://onboarding/show")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .showOnboarding)
    }

    func testShowOnboardingQueryForm() {
        // Legacy form the cycle 8.46 Action Panel initially shipped.
        // Kept working so any older external caller doesn't break.
        let url = URL(string: "hippocampus://onboarding?show=1")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .showOnboarding)
    }

    func testOnboardingWithoutRecognizedPathOrQueryIsUnknown() {
        // `hippocampus://onboarding` by itself doesn't do anything —
        // requires the explicit `/show` or `?show=1`. Prevents a
        // stray future host from accidentally re-opening onboarding.
        let url = URL(string: "hippocampus://onboarding")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown)
    }

    // MARK: - Rejection cases

    func testForeignSchemeReturnsNil() {
        // AppKit may hand us URLs from other schemes registered
        // against the bundle (e.g. `onboarding://start?migration=…`).
        // Those aren't ours to route.
        let url = URL(string: "onboarding://start")!
        XCTAssertNil(HippocampusURLRoute.parse(url))
    }

    func testUnknownHostIsUnknownNotNil() {
        // Scheme is ours, host isn't. Distinct from a foreign scheme
        // so callers can log-and-ignore without swallowing bugs.
        let url = URL(string: "hippocampus://banana")!
        XCTAssertEqual(HippocampusURLRoute.parse(url), .unknown)
    }

    func testAskOpensTheCommandBarWithAnOptionalQuestion() throws {
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: "hippocampus://ask"))), .ask(question: nil))
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: "hippocampus://ask?q=what%20did%20I%20decide"))),
                       .ask(question: "what did I decide"))
        XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: "hippocampus://ask?q=%20"))), .ask(question: nil))
    }
}
