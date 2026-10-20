#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// A moment's formatted text (`reading-*`), light and dark: an article
    /// (and an older one before and after), Slack, Messages, a terminal,
    /// code, mail, Gmail read before windows were classified, an AI chat, a
    /// Notes checklist, a sheet, a document, a table the extension read, and
    /// a selection across paragraphs. Each is the detail's "On screen" at
    /// its width, drawn from the golden blocks the Rust tests check
    /// (`core/brain/tests/fixtures/reading/blocks/`): exactly what the FFI
    /// gives the window. Every word is made up.
    static var readingScenes: [Scene] {
        var scenes: [Scene] = []
        for picture in ReadingRenderFixture.pictures {
            for dark in [false, true] {
                scenes.append(.picture(picture.name + (dark ? "-dark" : ""),
                                       size: CGSize(width: ReadingRenderFixture.width, height: picture.height),
                                       dark: dark) {
                    AnyView(ReadingPicture(picture: picture))
                })
            }
        }
        return scenes
    }
}

/// The made-up windows the reading pictures are drawn from.
enum ReadingRenderFixture {
    /// The detail's width in the prototype's 1100-point window.
    static let width: CGFloat = 430

    struct Picture {
        let name: String
        /// The fixture under `core/brain/tests/fixtures/reading/blocks/`.
        let fixture: String
        let height: CGFloat
        var app = "com.google.Chrome"
        var source = "screen_ocr"
        /// Drawn as the window drew it before formatted transcripts: the
        /// stored lines in one block.
        var before = false
        /// The characters (UTF-16) to show selected.
        var selection: NSRange?
    }

    static let pictures: [Picture] = [
        Picture(name: "reading-article", fixture: "article.new", height: 640),
        // SPEC 4.10's before: the article's lines as stored, in one block.
        Picture(name: "reading-article-old-before", fixture: "article.new", height: 640, before: true),
        Picture(name: "reading-article-old-after", fixture: "article.old", height: 640),
        Picture(name: "reading-slack", fixture: "slack.new", height: 560, app: "com.tinyspeck.slackmacgap"),
        Picture(name: "reading-messages", fixture: "messages.new", height: 220, app: "com.apple.MobileSMS"),
        Picture(name: "reading-terminal", fixture: "terminal-assistant.new", height: 460, app: "com.apple.Terminal"),
        Picture(name: "reading-code", fixture: "vscode.new", height: 900, app: "com.microsoft.VSCode"),
        Picture(name: "reading-mail", fixture: "apple-mail-quote.new", height: 420, app: "com.apple.mail"),
        Picture(name: "reading-gmail-old", fixture: "gmail.old", height: 440),
        Picture(name: "reading-ai-chat", fixture: "chatgpt.new", height: 520, app: "com.openai.chat"),
        Picture(name: "reading-notes-checklist", fixture: "notes-checklist.new", height: 300, app: "com.apple.Notes"),
        Picture(name: "reading-sheet", fixture: "numbers.new", height: 300, app: "com.apple.iWork.Numbers"),
        Picture(name: "reading-document", fixture: "google-docs.new", height: 560),
        Picture(name: "reading-table", fixture: "extension-table.page", height: 340, source: "browser_page"),
        Picture(name: "reading-selection", fixture: "article.new", height: 640,
                selection: NSRange(location: 160, length: 360)),
    ]

    /// The fixtures, beside the Rust tests that check them: found from this
    /// source file, as a debug build is run where it was built.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Renders
        .deletingLastPathComponent() // RecallUI
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // recall-ui
        .deletingLastPathComponent() // apps
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("core/brain/tests/fixtures/reading/blocks")

    static func file(_ name: String) -> String {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    static func blocks(_ fixture: String) -> [ReadingBlock] {
        let data = Data(file("\(fixture).blocks.json").utf8)
        return (try? JSONDecoder().decode([ReadingBlock].self, from: data)) ?? []
    }

    /// What the window showed under "Also in this window" for a classified
    /// window: its chrome, after the separator.
    static func rest(_ stored: String) -> String {
        guard let separator = stored.range(of: ReadableText.chromeSeparator) else { return "" }
        return String(stored[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func reading(_ picture: Picture) -> EventReading? {
        let stored = file("\(picture.fixture).txt")
        let blocks = picture.before ? [] : Self.blocks(picture.fixture)
        let main = picture.before
            ? ReadableText.parts(stored: stored, sourceKind: picture.source).main
            : ReadingBlocks.plainText(blocks)
        return try? EventReading(eventId: 4_812, tsUs: 1_760_302_500_000_000, appBundleId: picture.app,
                                 sourceKind: picture.source, main: main,
                                 rest: picture.before ? "" : rest(stored), isTruncated: false, blocks: blocks)
    }
}

/// The detail's "On screen", as DetailPaneView draws it: the heading, the
/// formatted text on its card and "Also in this window".
private struct ReadingPicture: View {
    let picture: ReadingRenderFixture.Picture
    @State private var showsRest = false

    var body: some View {
        let reading = ReadingRenderFixture.reading(picture)
        VStack(alignment: .leading, spacing: 8) {
            Text(UserFacingCopy.momentTextHeading(sourceKind: picture.source))
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
            if let reading {
                if picture.before {
                    BeforeFormattedText(text: reading.main)
                } else {
                    FormattedReadingView(text: reading.text(includingRest: false), reading: reading,
                                         selection: picture.selection)
                }
                if !reading.rest.isEmpty {
                    AlsoInThisWindowDisclosure(rest: reading.rest, lineCount: reading.restLineCount,
                                               isExpanded: $showsRest)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(MCI.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The text as the detail drew it before formatted transcripts (WP0's
/// `FormattedReadingView`): one block of 13-point text on its card.
private struct BeforeFormattedText: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundColor(.brandFgPrimary)
            .font(.system(.body, design: .default))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.brandBgPrimary))
    }
}
#endif
