// SPDX-License-Identifier: Apache-2.0
//
// The copies AppKit makes for the menu-bar app (storage review S7): ⌘C on
// selected text in Ask or Preferences, an attributed string, NSTextView's own
// Copy.
// Each one, on a pasteboard the rules cover, starts on this Mac only, is
// marked concealed on its one item and still pastes as plain text. These use
// private, uniquely named pasteboards, released at the end: never the
// clipboard you copy to.

import AppKit
import XCTest
@testable import HippocampusKit

@MainActor
final class MenuBarClipboardGuardTests: XCTestCase {
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    /// A private pasteboard of its own, named so nothing else uses it.
    private func privateBoard(covered: Bool) -> NSPasteboard {
        let board = NSPasteboard(name: .init("ai.hippocampus.menubar-guard-test.\(UUID().uuidString)"))
        boards.append(board)
        if covered { ClipboardGuard.cover(board.name) }
        return board
    }

    private static let text = "Send the Quillfeather draft"

    /// Every way AppKit or SwiftUI writes a copy, as each one starts and writes.
    private static let appKitWrites: [(name: String, write: @MainActor (NSPasteboard) -> Void)] = [
        ("clearContents, then writeObjects (SwiftUI's Copy command)", { board in
            _ = board.clearContents()
            _ = board.writeObjects([text as NSString])
        }),
        ("clearContents, then setString", { board in
            _ = board.clearContents()
            _ = board.setString(text, forType: .string)
        }),
        ("declareTypes, then setString", { board in
            _ = board.declareTypes([.string], owner: nil)
            _ = board.setString(text, forType: .string)
        }),
        ("prepareForNewContents with no options, then setData", { board in
            _ = board.prepareForNewContents(with: [])
            _ = board.setData(Data(text.utf8), forType: .string)
        }),
        ("an attributed string, as selected text is copied", { board in
            _ = board.clearContents()
            _ = board.writeObjects([NSAttributedString(string: text)])
        }),
        ("NSTextView's own Copy (every type it writes for ⌘C)", { board in
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
            _ = view.writeSelection(to: board, types: view.writablePasteboardTypes)
        }),
    ]

    func testEveryCopyAppKitMakesStaysOnThisMacConcealedAndPastes() {
        let board = privateBoard(covered: true)
        for (name, write) in Self.appKitWrites {
            ClipboardGuard.forgetLastStart()
            write(board)
            XCTAssertEqual(ClipboardGuard.lastStartOptions, .currentHostOnly, "\(name): never Universal Clipboard")
            XCTAssertEqual(board.pasteboardItems?.count, 1, "\(name): one item")
            XCTAssertEqual(board.types?.contains(ClipboardHygiene.concealed), true, "\(name): concealed")
            XCTAssertEqual(board.string(forType: .string), Self.text, "\(name): still pastes")
            XCTAssertEqual(board.readObjects(forClasses: [NSString.self]) as? [String], [Self.text], name)
        }
    }

    /// The app's own copies on a covered pasteboard: the marker once, the
    /// transient marker only on a copy for an AI tool, and the text intact.
    func testTheAppsOwnCopiesAreMarkedOnce() {
        let board = privateBoard(covered: true)
        ClipboardGuard.forgetLastStart()
        XCTAssertTrue(ClipboardHygiene.copyToKeep(Self.text, to: board))
        XCTAssertEqual(ClipboardGuard.lastStartOptions, .currentHostOnly)
        XCTAssertEqual(board.types?.filter { $0 == ClipboardHygiene.concealed }.count, 1)
        XCTAssertEqual(board.types?.contains(ClipboardHygiene.transient), false)
        XCTAssertEqual(board.string(forType: .string), Self.text)

        XCTAssertTrue(ClipboardHygiene.copy(Self.text, to: board, schedule: { _, _ in }))
        XCTAssertEqual(board.types?.contains(ClipboardHygiene.concealed), true)
        XCTAssertEqual(board.types?.contains(ClipboardHygiene.transient), true)
        XCTAssertEqual(board.string(forType: .string), Self.text)
    }

    /// A pasteboard the rules don't cover (a drag, Find, Services) is left
    /// exactly as AppKit writes it.
    func testPasteboardsTheRulesDontCoverAreLeftAlone() {
        _ = privateBoard(covered: true)
        let board = privateBoard(covered: false)
        ClipboardGuard.forgetLastStart()
        _ = board.clearContents()
        _ = board.writeObjects([Self.text as NSString])
        XCTAssertNil(ClipboardGuard.lastStartOptions)
        XCTAssertEqual(board.types?.contains(ClipboardHygiene.concealed), false)
        XCTAssertEqual(board.string(forType: .string), Self.text)
    }

    /// Turning the rules on covers the general clipboard (checked by name:
    /// nothing is written to it), and turning them on again changes nothing.
    func testRuleEveryCopyCoversTheGeneralClipboard() {
        ClipboardHygiene.ruleEveryCopy()
        ClipboardHygiene.ruleEveryCopy()
        XCTAssertTrue(ClipboardGuard.covers(.general))
        // Still exchanged once: a covered copy is still marked.
        let board = privateBoard(covered: true)
        _ = board.clearContents()
        _ = board.setString(Self.text, forType: .string)
        XCTAssertEqual(board.types?.contains(ClipboardHygiene.concealed), true)
    }

    /// The menu-bar app turns the rules on before anything of the app exists.
    func testTheMenuBarAppTurnsTheRulesOnAtLaunch() throws {
        let entry = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hippocampus/HippocampusEntryPoint.swift")
        let source = try String(contentsOf: entry, encoding: .utf8)
        let rules = try XCTUnwrap(source.range(of: "ClipboardHygiene.ruleEveryCopy()"))
        let app = try XCTUnwrap(source.range(of: "HippocampusApp.main()"))
        XCTAssertLessThan(rules.lowerBound, app.lowerBound)
    }
}
