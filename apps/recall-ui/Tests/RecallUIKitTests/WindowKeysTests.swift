import AppKit
import SwiftUI
import XCTest
@testable import RecallUIKit

/// ⌘↩ has one meaning everywhere (SPEC 2.10): Ask {Tool} with the typed
/// question, or with what the page has selected. The field comes before
/// every page in the window, and of two ⌘↩ buttons the first drawn takes
/// the key, so the field's own ⌘↩ is on only while it holds a question.
final class WindowKeysTests: XCTestCase {
    func testTheFieldTakesCommandReturnOnlyWhileItHoldsAQuestion() {
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn(""),
                       "an empty field leaves ⌘↩ to the page: History's picked row, Today's card")
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn("   "))
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn("\n\t "))
        XCTAssertTrue(WindowKeys.fieldTakesCommandReturn("rounding half to even"))
        XCTAssertTrue(WindowKeys.fieldTakesCommandReturn("  tax  "))
    }

    /// The row menu's keys work on the list itself (SPEC 2.10): they used to
    /// live only on the menu's items, which are no keys at all while the
    /// menu is closed.
    func testTheRowMenusKeysActOnThePickedRowsFromTheList() {
        XCTAssertEqual(MomentKey(character: "c", modifiers: .command), .copyText)
        XCTAssertEqual(MomentKey(character: "C", modifiers: [.command, .shift]), .copyForYourAI)
        XCTAssertEqual(MomentKey(character: "c", modifiers: [.command, .shift]), .copyForYourAI)
        XCTAssertEqual(MomentKey(character: "o", modifiers: .command), .openLink)
        XCTAssertEqual(MomentKey(character: "R", modifiers: [.command, .shift]), .showRelated)
        XCTAssertEqual(MomentKey(character: "c", modifiers: [.command, .capsLock]), .copyText, "Caps Lock doesn't count")
        XCTAssertNil(MomentKey(character: "c", modifiers: []), "typing goes on to the list")
        XCTAssertNil(MomentKey(character: "c", modifiers: [.command, .option]))
        XCTAssertNil(MomentKey(character: "r", modifiers: .command), "⌘R is Refresh, the window's")
        XCTAssertNil(MomentKey(character: "o", modifiers: [.command, .shift]))
        XCTAssertNil(MomentKey(character: "k", modifiers: .command), "⌘K is the command bar")
    }

    func testTheShortcutsSheetListsEveryRowKey() {
        let chips = Set(WindowKeys.all.flatMap(\.keys))
        for key in MomentKey.allCases {
            XCTAssertTrue(chips.contains(key.chip), "\(key) is in the Keyboard Shortcuts sheet")
        }
    }

    func testTheShortcutsSheetSaysCommandReturnAsksWithTheSelectionOrTheQuestion() throws {
        let key = try XCTUnwrap(WindowKeys.all.first { $0.keys == ["\u{2318}\u{21A9}"] })
        XCTAssertEqual(key.group, .actions)
        XCTAssertTrue(key.does.contains("selection"))
        XCTAssertTrue(key.does.contains("typed question"))
    }
    /// The window draws the field row before every page, and of two ⌘↩
    /// buttons the first drawn takes the key. With the field's ⌘↩ always on,
    /// ⌘↩ on a picked History row, Today's card or a Working On page did
    /// nothing. Hosted as the window lays them out (the field row, then the
    /// page, or the results while the field holds text), in a window that is
    /// never ordered in: an empty field leaves ⌘↩ to the page's Ask {Tool},
    /// a typed question takes it.
    @MainActor
    func testCommandReturnReachesThePageWhileTheFieldIsEmpty() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let field = FieldText()
        let log = KeyLog()
        let size = NSSize(width: 320, height: 200)
        let hosting = NSHostingView(rootView: FieldThenPage(field: field, log: log))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = hosting
        defer { window.contentView = nil }
        func settle() {
            for _ in 0..<10 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func commandReturn() throws -> [String] {
            log.fired = []
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            _ = window.performKeyEquivalent(with: event)
            settle()
            return log.fired
        }
        settle()
        XCTAssertEqual(try commandReturn(), ["page"], "an empty field: the page's Ask {Tool}, with its selection")
        field.query = "rounding half to even"
        settle()
        XCTAssertEqual(try commandReturn(), ["field"], "a typed question: the field's")
        field.query = ""
        settle()
        XCTAssertEqual(try commandReturn(), ["page"], "cleared: the page's again")
    }
}

private final class KeyLog {
    var fired: [String] = []
}

private final class FieldText: ObservableObject {
    @Published var query = ""
}

/// The window's two ⌘↩ buttons as it draws them: the field row's, on only
/// while it holds a question (`WindowKeys.fieldTakesCommandReturn`), then
/// the page's Ask {Tool}, which the results replace while the field holds
/// something.
private struct FieldThenPage: View {
    @ObservedObject var field: FieldText
    let log: KeyLog

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "field")
                .background {
                    Button("") { log.fired.append("field") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!WindowKeys.fieldTakesCommandReturn(field.query))
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
            if field.query.isEmpty {
                Text(verbatim: "page")
                    .background {
                        Button("") { log.fired.append("page") }
                            .keyboardShortcut(.return, modifiers: .command)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                    }
            } else {
                Text(verbatim: "results")
            }
        }
        .frame(width: 320, height: 200)
    }
}
