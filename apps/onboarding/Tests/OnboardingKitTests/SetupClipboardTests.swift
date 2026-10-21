// SPDX-License-Identifier: Apache-2.0
//
// Setup's clipboard (storage review S7): its one copy stays on this Mac and
// out of clipboard-history apps, and nothing else in setup writes to a
// pasteboard. Fakes only: no real pasteboard.

#if canImport(AppKit)
import AppKit
import XCTest
@testable import OnboardingKit

@MainActor
private final class RecordingSetupPasteboard: SetupPasteboard {
    var options: [NSPasteboard.ContentsOptions] = []
    var contents: [NSPasteboard.PasteboardType: Data] = [:]

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        self.options.append(options)
        contents = [:]
        return 1
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = Data(string.utf8)
        return true
    }

    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = data
        return true
    }
}

@MainActor
final class SetupClipboardTests: XCTestCase {
    func testSetupsCopyStaysOnThisMacAndOutOfClipboardHistory() {
        let board = RecordingSetupPasteboard()
        XCTAssertTrue(SetupClipboard.copy("chrome://extensions", to: board))
        XCTAssertEqual(board.options, [.currentHostOnly], "never Universal Clipboard")
        XCTAssertEqual(board.contents[.string], Data("chrome://extensions".utf8))
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.TransientType")])
    }

    func testNoOtherFileInSetupWritesToAPasteboard() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let writes = [".setString(", ".setData(", "writeObjects(", ".clearContents()", "declareTypes(",
                      "prepareForNewContents(", "NSPasteboard.general", "NSPasteboard(name:"]
        var checked = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "SetupClipboard.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            for write in writes {
                XCTAssertFalse(source.contains(write), "\(file.lastPathComponent) writes to a pasteboard: \(write)")
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }
}
#endif
