import XCTest
@testable import RecallUIKit

final class AskShortcutLabelTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "recall-ask-key-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testWhatTheAppPublishesIsWhatTheWindowShows() {
        defaults.set("right ⌘", forKey: AskShortcutLabel.effectiveLabelKey)
        defaults.set("Tap right ⌘", forKey: AskShortcutLabel.effectivePhraseKey)
        defaults.set("shiftTwice", forKey: AskShortcutLabel.askKeyKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "right ⌘", phrase: "Tap right ⌘"))
    }

    func testAnEmptyLabelMeansNothingOpensAsk() {
        defaults.set("", forKey: AskShortcutLabel.effectiveLabelKey)
        defaults.set("Press Shift twice", forKey: AskShortcutLabel.effectivePhraseKey)
        let label = AskShortcutLabel.current(defaults: defaults)
        XCTAssertFalse(label.opensAsk)
        XCTAssertEqual(label, AskShortcutLabel(label: "", phrase: ""))
    }

    func testWithoutWhatTheAppPublishesTheChosenKeyStandsIn() {
        let expected: [String: AskShortcutLabel] = [
            "shiftTwice": AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"),
            "rightShift": AskShortcutLabel(label: "right ⇧", phrase: "Tap right Shift"),
            "rightCommand": AskShortcutLabel(label: "right ⌘", phrase: "Tap right ⌘"),
            "rightOption": AskShortcutLabel(label: "right ⌥", phrase: "Tap right ⌥"),
            "off": AskShortcutLabel(label: "⌃⇧Space", phrase: "Press ⌃⇧Space"),
            "capsLock": AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"),
        ]
        for (key, label) in expected {
            defaults.set(key, forKey: AskShortcutLabel.askKeyKey)
            XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), label, key)
        }
        defaults.removeObject(forKey: AskShortcutLabel.askKeyKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"))
    }

    func testALabelWithoutAPhraseSaysPress() {
        defaults.set("⌃⌥Space", forKey: AskShortcutLabel.effectiveLabelKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "⌃⌥Space", phrase: "Press ⌃⌥Space"))
    }

    func testTheKeysAreTheOnesTheAppWrites() {
        XCTAssertEqual(AskShortcutLabel.effectiveLabelKey, "ai.hippocampus.ask.effectiveLabel")
        XCTAssertEqual(AskShortcutLabel.effectivePhraseKey, "ai.hippocampus.ask.effectivePhrase")
        XCTAssertEqual(AskShortcutLabel.askKeyKey, "ai.hippocampus.prefs.askKey")
        XCTAssertEqual(Set(UserFacingCopy.askKeyNames.keys), ["shiftTwice", "rightShift", "rightCommand", "rightOption", "off"])
    }
}

final class RecallRouteTests: XCTestCase {
    func testTheAppsThreeNamesOpenTheThreePlaces() {
        XCTAssertEqual(RecallRoute(tab: "overview"), RecallRoute(place: .overview))
        XCTAssertEqual(RecallRoute(tab: "ask"), RecallRoute(place: .ask))
        XCTAssertEqual(RecallRoute(tab: "you"), RecallRoute(place: .you))
        XCTAssertEqual(RecallRoute(tab: " You "), RecallRoute(place: .you))
    }

    func testEveryOlderNameKeepsWorking() {
        let places: [String: RecallRoute] = [
            "today": RecallRoute(place: .overview), "now": RecallRoute(place: .overview),
            "daily": RecallRoute(place: .overview), "brief": RecallRoute(place: .overview),
            "briefs": RecallRoute(place: .overview), "search": RecallRoute(place: .ask),
            "timeline": RecallRoute(place: .ask, showsHistory: true),
            "history": RecallRoute(place: .ask, showsHistory: true),
            "episodes": RecallRoute(place: .ask, showsHistory: true),
            "sessions": RecallRoute(place: .ask, showsHistory: true),
            "timeline-strip": RecallRoute(place: .ask, showsHistory: true),
            "strip": RecallRoute(place: .ask, showsHistory: true),
            "settings": RecallRoute(place: .you),
            "privacy": RecallRoute(place: .you, showsPrivacy: true),
            "dashboard": RecallRoute(place: .you, showsPrivacy: true),
            "privacy-dashboard": RecallRoute(place: .you, showsPrivacy: true),
        ]
        for (name, route) in places {
            XCTAssertEqual(RecallRoute(tab: name), route, name)
            XCTAssertEqual(RecallRoute(tab: name.uppercased()), route, name)
            XCTAssertNotNil(RecallTab.from(deepLinkValue: name), "\(name) still opens today's window")
        }
    }

    func testUnknownNamesAreIgnored() {
        for name in ["", "nope", "0", "overview2"] {
            XCTAssertNil(RecallRoute(tab: name), name)
        }
    }

    func testTheRouteComesFromTheLaunchEnvironmentOrTheLink() throws {
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "you"]), RecallRoute(place: .you))
        XCTAssertNil(RecallRoute(environment: [:]))
        let link = try XCTUnwrap(URL(string: "hippocampus://recall?tab=privacy"))
        XCTAssertEqual(RecallRoute(url: link), RecallRoute(place: .you, showsPrivacy: true))
        XCTAssertNil(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://ask?tab=you"))))
    }

    func testTodaysWindowOpensOverviewAndAskByTheirNewNames() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "overview"), .now)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "ask"), .search)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "ask"]).initialTab, .search)
        XCTAssertEqual(RecallPlace.allCases, [.overview, .ask, .you])
    }
}
