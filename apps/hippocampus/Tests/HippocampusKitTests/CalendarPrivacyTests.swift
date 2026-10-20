// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// The calendar's promises in the app (SPEC-DELTA 5): never handed to an AI
/// tool on its own, and never part of the memory, so About You can't learn
/// anything from it. Only source and manifests are read here.
final class CalendarPrivacyTests: XCTestCase {
    /// What builds or sends a message for an AI tool never reads the
    /// calendar. Events reach a tool only when the person picks them: if a
    /// change adds that, keep it behind the person's pick, and change this
    /// list with it.
    func testNoAIToolsMessageIsBuiltFromTheCalendar() throws {
        let kit = CalendarSource.package.appendingPathComponent("Sources/HippocampusKit")
        var files = ["SessionContextInstaller.swift", "SessionContextHook.swift", "HandoffCopy.swift",
                     "CommandBar/PanelHandoff.swift", "CommandBar/AskThisWindow.swift"]
            .map { kit.appendingPathComponent($0) }
        let handoff = kit.appendingPathComponent("Handoff")
        if let more = try? FileManager.default.contentsOfDirectory(at: handoff, includingPropertiesForKeys: nil) {
            files += more.filter { $0.pathExtension == "swift" }
        }
        var read = 0
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for name in ["CalendarMeeting", "CalendarAnswerer", "CalendarQuestion", "EventKitCalendarAccess",
                         "EventKit"] {
                XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) mentions \(name)")
            }
        }
        XCTAssertGreaterThan(read, 2, "the check reads the handoff's files")
    }

    /// The agent and the brain have no calendar reader, so no event is ever
    /// stored, learned from, or offered to a connected tool.
    func testTheMemoryNeverTakesInTheCalendar() throws {
        for manifest in ["apps/agent/Cargo.toml", "core/brain/Cargo.toml", "core/Cargo.toml"] {
            let url = CalendarSource.repository.appendingPathComponent(manifest)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("mci-calendar-reader"), "\(manifest) reads the calendar")
            XCTAssertFalse(text.contains("objc2-event-kit"), "\(manifest) reads the calendar")
        }
    }
}
