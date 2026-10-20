// SPDX-License-Identifier: Apache-2.0
//
// The window's copies of the clipboard rules and of which AI tools are on
// this Mac (SPEC 5.3.2, 5.3.6, 5.3.7); the menu-bar app's copies are held
// to the same tests. Fakes only: no real pasteboard, no Launch Services.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RecallUIKit

/// A pasteboard that records what was asked of it.
@MainActor
private final class RecordingPasteboard: HandoffPasteboard {
    var changeCount = 0
    var options: [NSPasteboard.ContentsOptions] = []
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    var cleared = 0

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        self.options.append(options)
        contents = [:]
        changeCount += 1
        return changeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = Data(string.utf8)
        return true
    }

    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = data
        return true
    }

    func clearContents() -> Int {
        contents = [:]
        cleared += 1
        changeCount += 1
        return changeCount
    }
}

@MainActor
final class WindowClipboardHygieneTests: XCTestCase {
    func testACopyStaysOnThisMacAndOutOfClipboardHistory() {
        let board = RecordingPasteboard()
        var later: (Duration, () -> Void)?
        XCTAssertTrue(ClipboardHygiene.copy("## Moment", to: board, schedule: { delay, work in later = (delay, work) }))
        XCTAssertEqual(board.options, [.currentHostOnly], "never Universal Clipboard")
        XCTAssertEqual(board.contents[.string], Data("## Moment".utf8))
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.TransientType")])
        XCTAssertEqual(later?.0, .seconds(120), "cleared after 2 minutes")
        later?.1()
        XCTAssertEqual(board.cleared, 1)
        XCTAssertNil(board.contents[.string])
    }

    func testItIsNotClearedWhenSomethingElseWasCopiedSince() {
        let board = RecordingPasteboard()
        var later: (() -> Void)?
        ClipboardHygiene.copy("## Moment", to: board, schedule: { _, work in later = work })
        board.changeCount += 1 // the person copied something else
        later?()
        XCTAssertEqual(board.cleared, 0)
    }

    func testAScreenshotFollowsTheSameRules() {
        let board = RecordingPasteboard()
        ClipboardHygiene.copy(jpeg: Data([0xFF, 0xD8]), to: board, schedule: { _, _ in })
        XCTAssertEqual(board.options, [.currentHostOnly])
        XCTAssertEqual(board.contents[NSPasteboard.PasteboardType("public.jpeg")], Data([0xFF, 0xD8]))
        XCTAssertNotNil(board.contents[ClipboardHygiene.concealed])
        XCTAssertNotNil(board.contents[ClipboardHygiene.transient])
    }

    /// A made-up picture, as JPEG, carrying where and when it was taken.
    private func picture(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.87, kCGImagePropertyGPSLongitude: 122.26],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Sam's desk"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Northwind"],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testAScreenshotGoesAtMost1568PixelsWithNoMetadata() throws {
        let original = try picture(width: 3_000, height: 2_000)
        XCTAssertNotNil(try properties(original)[kCGImagePropertyGPSDictionary], "the fixture carries a place")
        let jpeg = try XCTUnwrap(ClipboardHygiene.jpegForAI(original))
        let out = try properties(jpeg)
        XCTAssertEqual(out[kCGImagePropertyPixelWidth] as? Int, 1_568, "its long edge")
        XCTAssertEqual(Double(out[kCGImagePropertyPixelHeight] as? Int ?? 0), 1_045, accuracy: 1, "in proportion")
        XCTAssertNil(out[kCGImagePropertyGPSDictionary], "no place")
        XCTAssertNil((out[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNil((out[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testASmallScreenshotIsNeverEnlarged() throws {
        let jpeg = try XCTUnwrap(ClipboardHygiene.jpegForAI(try picture(width: 800, height: 600)))
        let out = try properties(jpeg)
        XCTAssertEqual(out[kCGImagePropertyPixelWidth] as? Int, 800)
        XCTAssertEqual(out[kCGImagePropertyPixelHeight] as? Int, 600)
        XCTAssertNil(out[kCGImagePropertyGPSDictionary])
    }

    func testSomethingThatIsntAPictureGivesNothing() {
        XCTAssertNil(ClipboardHygiene.jpegForAI(Data("## Moment".utf8)))
    }
}

final class WindowDestinationDetectorTests: XCTestCase {
    private func detector(
        schemes: [String: String] = [:], bundles: [String: String] = [:], executables: Set<String> = [],
        path: String = "/usr/bin:/bin"
    ) -> DestinationDetector {
        DestinationDetector(
            appForScheme: { scheme in schemes[scheme].map { URL(fileURLWithPath: $0) } },
            appForBundle: { bundle in bundles[bundle].map { URL(fileURLWithPath: $0) } },
            isExecutable: { executables.contains($0) },
            environment: ["HOME": "/Users/sam", "PATH": path]
        )
    }

    func testNoToolsMeansCopyForYourAI() {
        XCTAssertEqual(detector().installed(), [])
        XCTAssertEqual(DestinationDetector.none.installed(), [])
    }

    func testOnlyToolsOnThisMacAreOfferedInTheMenusOrder() {
        let found = detector(
            schemes: ["claude": "/Applications/Claude.app", "cursor": "/Applications/Cursor.app",
                      "codex": "/Applications/Codex.app", "vscode": "/Applications/Visual Studio Code.app"],
            bundles: ["com.openai.chat": "/Applications/ChatGPT.app"]
        ).installed()
        XCTAssertEqual(found.map(\.tool), [.claude, .claudeCode, .chatgpt, .codex, .cursor],
                       "VS Code waits until its link is verified")
        XCTAssertTrue(found.allSatisfy(\.hasApp))
        XCTAssertEqual(found.first { $0.tool == .chatgpt }?.appURL?.path, "/Applications/ChatGPT.app")
    }

    func testTheAppThatHandlesTheLinkWins() {
        // Two versions installed: Launch Services names the handler.
        let found = detector(schemes: ["claude": "/Users/sam/Applications/Claude.app"],
                             executables: ["/opt/homebrew/bin/claude"]).installed()
        XCTAssertEqual(found.first { $0.tool == .claudeCode }?.appURL?.path, "/Users/sam/Applications/Claude.app")
        XCTAssertNil(found.first { $0.tool == .claudeCode }?.commandLine)
    }

    func testClaudeCodesCommandLineAloneIsCopiedForTerminal() {
        for place in ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "/Users/sam/.local/bin/claude"] {
            let found = detector(executables: [place]).installed()
            XCTAssertEqual(found.map(\.tool), [.claudeCode], place)
            XCTAssertEqual(found.first?.commandLine, place)
            XCTAssertFalse(found.first?.hasApp ?? true)
        }
        let onPath = detector(executables: ["/Users/sam/bin/claude"], path: "/usr/bin:/Users/sam/bin").installed()
        XCTAssertEqual(onPath.first?.commandLine, "/Users/sam/bin/claude")
    }

    @MainActor
    func testTerminalOpensOnlyInAFolderOnThisMac() {
        let project = URL(fileURLWithPath: "/Users/sam/dev/trailhead-shop", isDirectory: true)
        XCTAssertEqual(TerminalHere.folder(project, isDirectory: { $0 == "/Users/sam/dev/trailhead-shop" }), project)
        XCTAssertNil(TerminalHere.folder(project, isDirectory: { _ in false }), "a folder moved since is never opened")
        XCTAssertNil(TerminalHere.folder(URL(string: "https://devnotes.example/rounding")!, isDirectory: { _ in true }))
        XCTAssertEqual(TerminalHere.bundleIdentifier, "com.apple.Terminal")
    }
}
