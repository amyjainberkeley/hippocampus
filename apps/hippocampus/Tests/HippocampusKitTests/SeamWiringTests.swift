// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// The app's seams (SPEC 8.1, SPEC-DELTA 5 to 7): each later package fills
/// its own file, and the one place that calls it is already here. Each is a
/// no-op until its package lands, so the app behaves exactly as before.
final class SeamWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testTheCalendarRequestSaysWhatItIsForInPlainWords() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSCalendarsFullAccessUsageDescription"] as? String,
                       "Hippocampus shows your calendar on Today and names your meetings. It stays on this Mac.",
                       "the window and the app share this Info.plist, so macOS shows these words for either")
    }

    func testTheLaunchRepairIsCalledOnce() throws {
        // Only the source is read: once filled, the repair edits the AI
        // tools' own settings, which no test may touch.
        let app = try source("Sources/Hippocampus/HippocampusApp.swift")
        XCTAssertEqual(count("SessionContextInstaller.repairOnLaunch()", in: app), 1)
    }

    func testDemoMemoryReachesEveryChildThroughOneCall() throws {
        let supervisor = try source("Sources/HippocampusKit/ProcessSupervisor.swift")
        XCTAssertEqual(count("DemoMemory.", in: supervisor), 1)
        XCTAssertTrue(supervisor.contains("return DemoMemory.childEnvironment(environment)"))
        XCTAssertNil(DemoMemory.storeURL, "every child reads the person's own memory")
    }

    func testTheMenuAndPreferencesShowTheirSections() throws {
        let menu = try source("Sources/Hippocampus/StatusMenuView.swift")
        XCTAssertTrue(menu.contains("extraItems: DemoMemory.menuItems(optionHeld: NSEvent.modifierFlags.contains(.option))"))
        XCTAssertTrue(menu.contains("case .extra(let id): DemoMemory.perform(id)"))
        let preferences = try source("Sources/Hippocampus/PreferencesWindow.swift")
        for section in ["AskKeyPicker(store: store, askKey: askKey)", "CalendarPreferencesSection()",
                        "DemoMemoryPreferencesSection()"] {
            XCTAssertEqual(count(section, in: preferences), 1, section)
        }
        XCTAssertFalse(preferences.contains("Picker(\"Open Ask with\""), "the key picker is in AskKeyPicker.swift")
        let picker = try source("Sources/Hippocampus/AskKeyPicker.swift")
        XCTAssertTrue(picker.contains("Picker(\"Open Ask with\", selection: $store.askKey)"))
        XCTAssertTrue(picker.contains(".onAppear { askKey.recheck() }"))
    }
}
