import RecallUIKit
import SwiftUI

/// A moment's text as the detail's "On screen" draws it (SPEC 4.6).
///
/// A seam for now: it draws the text as the detail always has, monospaced
/// with syntax colours when it reads like code and with its links otherwise,
/// so nothing on screen changes. The reading's blocks drawn as headings,
/// paragraphs, lists and code in one selectable text view land with
/// formatted transcripts.
struct FormattedReadingView: View {
    /// What the detail shows of the moment: its reading's `main`, or the
    /// row's excerpt when the reading could not be read. Never empty.
    let text: String
    /// The moment's reading, when it was read: its blocks and its kind of
    /// window.
    var reading: EventReading?

    /// What the transcript draws: `text`, with a coding assistant's markers
    /// as plain bullets.
    private var shownBody: String {
        SyntaxHighlighter.plainBullets(text)
    }

    var body: some View {
        if text.utf8.count > 8192 {
            // Avoid regex/highlighter work over a large inspection payload.
            Text(text)
                .font(.body)
                .foregroundStyle(Color.brandFgPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if SyntaxHighlighter.looksLikeCode(text) {
            highlightedCode
        } else {
            linkedText
        }
    }

    private var highlightedCode: some View {
        let tokens = SyntaxHighlighter.tokenize(shownBody)
        return tokens.reduce(Text("")) { result, token in
            result + Text(token.text).foregroundColor(Color.syntaxColor(for: token.type))
        }
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.brandBgPrimary)
        )
    }

    private var linkedText: some View {
        let text = shownBody
        let links = LinkDetector.detect(in: text)
        let built: Text = {
            guard !links.isEmpty else {
                return Text(text).foregroundColor(.brandFgPrimary)
            }
            var result = Text("")
            var pos = text.startIndex
            for link in links {
                if pos < link.range.lowerBound {
                    result = result + Text(text[pos..<link.range.lowerBound])
                        .foregroundColor(.brandFgPrimary)
                }
                result = result + Text(link.url)
                    .foregroundColor(.brandMint)
                    .underline()
                pos = link.range.upperBound
            }
            if pos < text.endIndex {
                result = result + Text(text[pos...])
                    .foregroundColor(.brandFgPrimary)
            }
            return result
        }()
        return built
            .font(.system(.body, design: .default))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brandBgPrimary)
            )
    }
}
