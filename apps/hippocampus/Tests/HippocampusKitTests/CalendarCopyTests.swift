// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// The calendar's words and promises in the menu-bar app (SPEC-DELTA 5): the
/// same bar as `MenuBarCopyStyleTests`, what the switch says is read, and
/// what the code may read and ask. Nothing here touches EventKit.
final class CalendarCopyTests: XCTestCase {
    private static let marketingWords: Set<String> = [
        "seamless", "seamlessly", "effortless", "effortlessly", "unlock", "supercharge", "magic", "magical",
        "delve", "powerful", "smart", "simply", "leverage", "utilize", "robust", "elevate", "empower",
        "unleash", "harness", "frictionless", "revolutionary", "hiccup", "oops", "whoops", "gotcha",
    ]
    private static let jargon = [
        "scstream", "sqlcipher", "sentinel", "denylist", "mci-agent", "errno", "eventkit", "tcc", "entitlement",
        "captured", "captures",
    ]

    private var strings: [String] {
        let hours = "2:00 – 2:30 PM"
        return CalendarCopy.all + [
            CalendarCopy.lastMeeting("with Mira", when: CalendarCopy.onDay("Tuesday, October 13", hours),
                                     title: "Pricing review"),
            CalendarCopy.lastMeeting("about pricing", when: CalendarCopy.today(hours), title: "Pricing review"),
            CalendarCopy.lastMeeting("with Teo", when: CalendarCopy.yesterday(hours), title: "Teo 1:1"),
        ]
    }

    func testTheWordsKeepTheLaunchCopyBar() {
        for text in strings {
            let lower = text.lowercased()
            let words = Set(lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            for word in Self.marketingWords where words.contains(word) {
                XCTFail("marketing word “\(word)”: \(text)")
            }
            for term in Self.jargon where words.contains(term) || lower.contains(term + " ") {
                XCTFail("jargon “\(term)”: \(text)")
            }
            XCTAssertFalse(text.contains("!"), text)
            XCTAssertLessThan(text.filter { $0 == "\u{2014}" }.count, 2, text)
            XCTAssertFalse(lower.contains("nothing leaves your mac"), text)
        }
    }

    func testTheSwitchSaysExactlyWhatIsRead() {
        XCTAssertEqual(CalendarCopy.toggle, "Show my calendar on Today")
        for part in ["title", "time", "calendar", "place", "this Mac"] {
            XCTAssertTrue(CalendarCopy.about.contains(part), part)
        }
        XCTAssertTrue(CalendarCopy.notAllowed.contains("System Settings › Privacy & Security › Calendars"))
        XCTAssertEqual(CalendarCopy.openSystemSettings, "Open System Settings…")
    }

    // MARK: What the code may read and ask

    /// Who is invited, the organizer, notes, links and places: never read by
    /// the app, which needs only titles and times.
    func testTheAppReadsOnlyTitlesAndTimes() throws {
        let source = try CalendarSource.read("Sources/HippocampusKit/Calendar/CalendarAccess.swift")
        for banned in [".attendees", ".organizer", ".notes", ".hasNotes", ".hasAttendees", ".url", "EKParticipant",
                       ".structuredLocation", ".location", "requestWriteOnlyAccessToEvents", ".save(", ".remove("] {
            XCTAssertFalse(source.contains(banned), "\(banned) is never read or used")
        }
        XCTAssertEqual(source.components(separatedBy: "requestFullAccessToEvents()").count - 1, 1,
                       "one place asks macOS")
    }

    /// Only Preferences' switch asks macOS: Ask, pictures and everything else
    /// read what is already allowed.
    func testOnlyThePreferencesSwitchAsksMacOS() throws {
        let fileManager = FileManager.default
        let sources = CalendarSource.package.appendingPathComponent("Sources")
        let files = try XCTUnwrap(fileManager.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var askers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("requestFullAccess()") || text.contains("requestFullAccessToEvents") {
                askers.append(file.lastPathComponent)
            }
            XCTAssertFalse(text.contains("requestAccess(to: .event"), "\(file.lastPathComponent) uses the old request")
        }
        XCTAssertEqual(Set(askers), ["CalendarAccess.swift", "CalendarPreferenceModel.swift"])
        let model = try CalendarSource.read("Sources/HippocampusKit/Calendar/CalendarPreferenceModel.swift")
        XCTAssertEqual(model.components(separatedBy: "requestFullAccess()").count - 1, 1)
        XCTAssertTrue(model.contains("public func setOn(_ on: Bool) async"))
    }

    func testTheRequestSaysWhatItIsForAndTheAppMayAsk() throws {
        let data = try Data(contentsOf: CalendarSource.package.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNotNil(plist["NSCalendarsFullAccessUsageDescription"] as? String)
        // macOS before 14 shows the older key: the same words, never the
        // retired promise about tagging captured moments.
        XCTAssertEqual(plist["NSCalendarsUsageDescription"] as? String,
                       plist["NSCalendarsFullAccessUsageDescription"] as? String)

        let entitlements = try Data(contentsOf: CalendarSource.package
            .appendingPathComponent("Resources/Hippocampus.entitlements"))
        let granted = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any]
        )
        XCTAssertEqual(granted["com.apple.security.personal-information.calendars"] as? Bool, true,
                       "with the hardened runtime, macOS asks about calendars only for an app that may ask")
        let helper = try Data(contentsOf: CalendarSource.package
            .appendingPathComponent("Resources/MCICaptureHelper.entitlements"))
        let helperGranted = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: helper, format: nil) as? [String: Any]
        )
        XCTAssertNil(helperGranted["com.apple.security.personal-information.calendars"], "only the app asks")
    }

    func testPreferencesShowsTheSwitchAndLooksAgainWhenTheAppComesBack() throws {
        let section = try CalendarSource.read("Sources/Hippocampus/CalendarPreferencesSection.swift")
        XCTAssertTrue(section.contains("Toggle(CalendarCopy.toggle"))
        XCTAssertTrue(section.contains(".onAppear { model.recheck() }"))
        XCTAssertTrue(section.contains("NSApplication.didBecomeActiveNotification"))
        XCTAssertTrue(section.contains("Button(CalendarCopy.openSystemSettings)"))
        let renders = try CalendarSource.read("Sources/Hippocampus/Renders/CalendarRenders.swift")
        for name in ["\"calendar-off\"", "\"calendar-on\"", "\"calendar-denied\""] {
            XCTAssertTrue(renders.contains(name), name)
        }
        XCTAssertFalse(renders.contains("EventKitCalendarAccess"), "pictures never read the real calendar")
    }
}
