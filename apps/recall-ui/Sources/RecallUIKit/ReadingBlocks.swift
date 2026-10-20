import Foundation

/// One block of a moment's text, as the FFI's reading carries it (`blocks`,
/// `core/brain/src/reading_blocks.rs`, SPEC 4.2). Every block holds only text
/// that was read; its kind changes only how it is drawn.
public enum ReadingBlock: Equatable, Sendable {
    /// Prose.
    case paragraph(String)
    /// A kind this window doesn't draw yet, drawn as its text.
    case other(kind: String, text: String)

    /// The text the block holds, as read.
    public var text: String {
        switch self {
        case let .paragraph(text): text
        case let .other(_, text): text
        }
    }
}

extension ReadingBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, text
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        let text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        self = kind == "paragraph" ? .paragraph(text) : .other(kind: kind, text: text)
    }
}

/// A moment's text as blocks.
public enum ReadingBlocks {
    /// The blocks to draw for `main` when a reading carries none of its own:
    /// one paragraph holding all of it, or none when it holds no text.
    public static func fallback(main: String) -> [ReadingBlock] {
        main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(main)]
    }
}
