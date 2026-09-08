import Foundation

/// Display-only formatting for the already escaped export packet. Never parse decoded text again.
public enum HandoffPreview {
    public struct Block: Identifiable {
        public let id: Int
        public let text: AttributedString
        public let isHeading: Bool
    }

    public static func blocks(_ markdown: String) -> [Block] {
        // Metadata uses single newlines; make them Markdown hard breaks for display.
        let displayMarkdown = markdown.replacingOccurrences(of: "\n", with: "  \n")
        guard var parsed = try? AttributedString(markdown: displayMarkdown,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .full)) else {
            return [Block(id: 0, text: AttributedString(markdown), isHeading: false)]
        }
        parsed.link = nil
        parsed.imageURL = nil
        return parsed.runs[\.presentationIntent].enumerated().map { index, item in
            let (intent, range) = item
            let isHeading = intent?.components.contains {
                if case .header = $0.kind { return true }
                return false
            } ?? false
            return Block(id: index, text: AttributedString(parsed[range]), isHeading: isHeading)
        }
    }
}
