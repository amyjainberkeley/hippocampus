// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// Preferences' calendar switch (SPEC-DELTA 5), over a fake store: nothing
/// here touches EventKit or asks the real system for access.
@MainActor
final class CalendarPreferenceModelTests: XCTestCase {
    private var opened: [URL] = []

    private func model(_ store: FakeCalendarAccess, choice: Bool? = nil) -> (CalendarPreferenceModel, CalendarSetting) {
        let setting = CalendarSetting.inMemory(choice)
        let model = CalendarPreferenceModel(store: store, setting: setting, openURL: { [weak self] in
            self?.opened.append($0)
        })
        return (model, setting)
    }

    func testTheSwitchFollowsThePersonsChoiceThenWhatMacOSAllows() {
        typealias Row = (choice: Bool?, permission: CalendarPermission, state: CalendarPreferenceModel.State)
        let rows: [Row] = [
            (nil, .notDetermined, .off), (nil, .fullAccess, .off), (nil, .denied, .off), (nil, .addOnly, .off),
            (false, .fullAccess, .off), (false, .denied, .off),
            (true, .fullAccess, .on), (true, .notDetermined, .off),
            (true, .denied, .denied), (true, .addOnly, .denied),
            (nil, .restricted, .restricted), (true, .restricted, .restricted), (false, .restricted, .restricted),
        ]
        for row in rows {
            XCTAssertEqual(CalendarPreferenceModel.state(choice: row.choice, permission: row.permission), row.state,
                           "\(String(describing: row.choice)), \(row.permission)")
        }
    }

    func testShowingAndRecheckingNeverAskMacOS() {
        let store = FakeCalendarAccess(.notDetermined)
        let (model, _) = model(store)
        model.recheck()
        model.recheck()
        XCTAssertEqual(model.state, .off)
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(store.requestCount, 0, "only turning the switch on asks")
        XCTAssertEqual(store.readCount, 0, "Preferences reads no events")
    }

    func testTurningOnAsksMacOSOnceAndShowsTheCalendarWhenAllowed() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .person(allows: true))
        let (model, setting) = model(store)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(model.state, .on)
        XCTAssertTrue(model.isOn)
        XCTAssertEqual(setting.choice, true)
        XCTAssertEqual(model.caption, CalendarCopy.about)
        XCTAssertFalse(model.offersSystemSettings)
    }

    func testWhenThePersonSaysNoTheSwitchKeepsTheirChoiceAndSaysWhy() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .person(allows: false))
        let (model, setting) = model(store)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(model.state, .denied)
        XCTAssertTrue(model.isOn, "the switch keeps the person's choice, and the caption says why nothing shows")
        XCTAssertEqual(setting.choice, true)
        XCTAssertEqual(model.caption, CalendarCopy.notAllowed)
        XCTAssertTrue(model.offersSystemSettings)
        XCTAssertTrue(model.canChange, "turning it off clears the explanation")
    }

    func testAfterAnEarlierNoTurningOnDoesNotAskAgain() async {
        let store = FakeCalendarAccess(.denied)
        let (model, _) = model(store, choice: false)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 0, "macOS won't ask twice: System Settings is where it changes")
        XCTAssertEqual(model.state, .denied)
        XCTAssertTrue(model.offersSystemSettings)
    }

    func testAddOnlyAccessIsNotEnoughToShowTheCalendar() async {
        let store = FakeCalendarAccess(.addOnly)
        let (model, _) = model(store)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 0)
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(model.caption, CalendarCopy.notAllowed)
    }

    func testAccessTakenBackLaterShowsOnTheNextLookAndComesBackWhenAllowed() {
        let store = FakeCalendarAccess(.fullAccess)
        let (model, _) = model(store, choice: true)
        XCTAssertEqual(model.state, .on)
        store.change(to: .denied)
        model.recheck()
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(model.caption, CalendarCopy.notAllowed)
        store.change(to: .fullAccess)
        model.recheck()
        XCTAssertEqual(model.state, .on, "allowed again in System Settings: it shows without another click")
        XCTAssertEqual(store.requestCount, 0)
    }

    func testTurningOffStopsItAndClearsTheExplanation() async {
        let store = FakeCalendarAccess(.denied)
        let (model, setting) = model(store, choice: true)
        XCTAssertEqual(model.state, .denied)
        await model.setOn(false)
        XCTAssertEqual(setting.choice, false)
        XCTAssertEqual(model.state, .off)
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(model.caption, CalendarCopy.about)
        XCTAssertFalse(model.offersSystemSettings)

        let allowed = FakeCalendarAccess(.fullAccess)
        let (on, onSetting) = self.model(allowed, choice: true)
        await on.setOn(false)
        XCTAssertEqual(on.state, .off, "off even while macOS still allows it")
        XCTAssertEqual(onSetting.choice, false)
        XCTAssertEqual(allowed.requestCount, 0)
    }

    func testOnAMacThatDoesNotAllowItTheSwitchCantChange() async {
        let store = FakeCalendarAccess(.restricted)
        let (model, setting) = model(store)
        XCTAssertEqual(model.state, .restricted)
        XCTAssertFalse(model.isOn)
        XCTAssertFalse(model.canChange)
        XCTAssertFalse(model.offersSystemSettings, "the person can't allow it in System Settings")
        XCTAssertEqual(model.caption, CalendarCopy.restricted)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 0)
        XCTAssertEqual(model.state, .restricted)
        XCTAssertNil(setting.choice, "no choice is written that the Mac won't allow")

        // Once the Mac allows it, the switch works again.
        store.change(to: .notDetermined)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(model.state, .on)
    }

    func testAnErrorAfterMacOSDecidedIsNotCalledAFailureToAsk() async {
        // macOS answered, then the request still reported an error: what
        // macOS decided is what shows.
        let store = FakeCalendarAccess(.notDetermined, answer: .decidesThenFails(allows: true))
        let (model, setting) = model(store)
        await model.setOn(true)
        XCTAssertEqual(model.state, .on)
        XCTAssertFalse(model.couldNotAsk)
        XCTAssertEqual(model.caption, CalendarCopy.about)
        XCTAssertEqual(setting.choice, true)
    }

    func testANoteThatMacOSCouldntBeAskedGoesOnceMacOSDecides() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .fails)
        let (model, _) = model(store)
        await model.setOn(true)
        XCTAssertTrue(model.couldNotAsk)
        model.recheck()
        XCTAssertTrue(model.couldNotAsk, "still undecided: the note stays")
        store.change(to: .denied)
        model.recheck()
        XCTAssertFalse(model.couldNotAsk)
        XCTAssertEqual(model.state, .off, "the person turned nothing on since")
    }

    func testWhenMacOSCantBeAskedTheChoiceGoesBackAndSaysSo() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .fails)
        let (model, setting) = model(store)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(model.state, .off)
        XCTAssertEqual(setting.choice, false, "the window agrees: nothing is read")
        XCTAssertTrue(model.couldNotAsk)
        XCTAssertEqual(model.caption, CalendarCopy.couldNotAsk)
        await model.setOn(false)
        XCTAssertFalse(model.couldNotAsk, "the next change clears it")
    }

    func testWhenMacOSDecidesNothingTheChoiceGoesBack() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .undecided)
        let (model, setting) = model(store)
        await model.setOn(true)
        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(model.state, .off)
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(setting.choice, false, "Preferences and the window agree: off")
        XCTAssertEqual(model.caption, CalendarCopy.couldNotAsk)
    }

    func testWhileMacOSIsAskingTheSwitchHoldsStill() async {
        let store = FakeCalendarAccess(.notDetermined, answer: .held)
        let (model, setting) = model(store)
        let turningOn = Task { await model.setOn(true) }
        while !store.isHoldingAQuestion { await Task.yield() }
        XCTAssertEqual(model.state, .asking)
        XCTAssertTrue(model.isOn)
        XCTAssertFalse(model.canChange)
        await model.setOn(false)
        model.recheck()
        XCTAssertEqual(model.state, .asking, "nothing changes under macOS's question")
        XCTAssertEqual(setting.choice, true)
        store.answer(allows: true)
        await turningOn.value
        XCTAssertEqual(model.state, .on)
        XCTAssertEqual(store.requestCount, 1)
    }

    func testOpenSystemSettingsOpensCalendarsPrivacy() {
        let (model, _) = model(FakeCalendarAccess(.denied), choice: true)
        model.openSystemSettings()
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"])
    }

    func testTheChoiceIsKeptInTheAppsDefaultsUnderTheWindowsKey() throws {
        let defaults = CalendarMemoryDefaults()
        let setting = CalendarSetting(defaults: defaults)
        XCTAssertNil(setting.choice, "unset until the person chooses")
        setting.set(true)
        XCTAssertEqual(defaults.object(forKey: "ai.hippocampus.calendar.show") as? Bool, true)
        setting.set(false)
        XCTAssertEqual(setting.choice, false)
        XCTAssertFalse(setting.isOn)

        // The window reads the same key (RecallUIKit's CalendarSetting).
        let window = try CalendarSource.read(
            "apps/recall-ui/Sources/RecallUIKit/Calendar/CalendarSetting.swift", from: CalendarSource.repository
        )
        XCTAssertTrue(window.contains("public static let key = \"\(CalendarSetting.key)\""))
    }
}
