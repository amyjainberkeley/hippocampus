import AppKit
import RecallUIKit
import SwiftUI

struct DetailPaneView: View {
    let hit: Hit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().background(Color.brandCardBorder)
                if let urlStr = hit.url, !urlStr.isEmpty {
                    urlSection(urlStr)
                }
                ocrSection
            }
            .padding(16)
        }
        .background(Color.brandBgSecondary)
        .focusable()
        .onCopyCommand {
            [NSItemProvider(object: hit.ocrTextSnippet as NSString)]
        }
        .onKeyPress(.init("o"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            if let u = hit.url, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .ignored
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.appBundleId ?? "(no app)")
                    .font(.system(.title3, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
                Text(Formatters.sourceTag(hit.source))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.brandMintDim, lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.brandMintDim)
            }
            if let title = hit.windowTitle, !title.isEmpty {
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: hit.tsUs))
                if let s = hit.score {
                    Text(Formatters.scoreString(s))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.brandFgMuted)
                }
            }
            HStack(spacing: 8) {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.ocrTextSnippet, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.brandMint)

                if let urlStr = hit.url, URL(string: urlStr) != nil {
                    Button("Open URL") {
                        if let url = URL(string: urlStr) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.brandMint)
                }
            }
        }
    }

    private func urlSection(_ urlStr: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .foregroundStyle(Color.brandMintDim)
                .font(.caption)
            if let url = URL(string: urlStr) {
                Link(urlStr, destination: url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(urlStr)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OCR Text")
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
            if SyntaxHighlighter.looksLikeCode(hit.ocrTextSnippet) {
                highlightedCode
            } else {
                linkedText
            }
        }
    }

    private var highlightedCode: some View {
        let tokens = SyntaxHighlighter.tokenize(hit.ocrTextSnippet)
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
        let text = hit.ocrTextSnippet
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
