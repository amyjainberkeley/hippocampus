import RecallUIKit
import SwiftUI

/// A moment's text as the detail's "On screen" draws it (SPEC 4.6): its
/// blocks (headings, paragraphs, lists, code, terminal output, tables, chat
/// turns, quotes) in one selectable text view, on the card History has always
/// drawn the text on.
///
/// The text view's string is built off the main thread. A reading without
/// blocks of its own (a reader without the FFI's blocks, or the row's excerpt
/// before the reading is there) is drawn as one block of its text, code when
/// it reads like code, as the detail always drew it.
struct FormattedReadingView: View {
    /// What the detail shows of the moment: its reading's text, or the row's
    /// excerpt when the reading could not be read. Never empty.
    let text: String
    /// The moment's reading, when it was read: its blocks.
    var reading: EventReading?
    /// A selection to show (the renders' picture of one).
    var selection: NSRange?

    @State private var built: ReadingAttributedText.Built?
    /// Whose text `built` is: a string made for another moment is never
    /// shown while this one's is made.
    @State private var builtFor: Identity?
    /// Quotes (by block) that were opened, for this moment only.
    @State private var openQuotes: Set<Int> = []
    @State private var openQuotesFor: UInt64?

    /// The moment the text is, or the text itself before its reading is
    /// there.
    private enum Identity: Equatable {
        case moment(UInt64)
        case text(String)
    }

    private var identity: Identity {
        reading.map { .moment($0.eventId) } ?? .text(text)
    }

    private var blocks: [ReadingBlock] {
        if let blocks = reading?.blocks, !blocks.isEmpty { return blocks }
        return ReadingBlocks.fallback(main: text)
    }

    /// What the string is built from, and whose it is: when either changes,
    /// it is built again. A reading whose blocks match the excerpt it
    /// replaces (a short moment's text) is still a new owner, so its string
    /// is made and shown.
    private struct Source: Equatable {
        let identity: Identity
        let blocks: [ReadingBlock]
        let openQuotes: Set<Int>
    }

    private var source: Source {
        Source(identity: identity, blocks: blocks,
               openQuotes: openQuotesFor == reading?.eventId ? openQuotes : [])
    }

    var body: some View {
        content
            .padding(MCI.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .fill(MCI.Color.background)
            )
            .task(id: source) {
                let source = self.source
                let made = await Task.detached(priority: .userInitiated) {
                    ReadingAttributedText.make(source.blocks, expandedQuotes: source.openQuotes)
                }.value
                guard !Task.isCancelled else { return }
                built = made
                builtFor = source.identity
            }
    }

    @ViewBuilder
    private var content: some View {
        if let built, builtFor == identity {
            ReadingTextView(built: built, onOpenQuote: { index in
                if openQuotesFor != reading?.eventId {
                    openQuotes = []
                    openQuotesFor = reading?.eventId
                }
                openQuotes.insert(index)
            }, selection: selection)
        } else {
            // A frame while the first string is built, a few milliseconds.
            Color.clear.frame(height: 19)
        }
    }
}
