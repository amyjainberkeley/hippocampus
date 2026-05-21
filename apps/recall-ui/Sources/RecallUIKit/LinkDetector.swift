import Foundation

public struct DetectedLink: Equatable, Sendable {
    public let url: String
    public let range: Range<String.Index>

    public init(url: String, range: Range<String.Index>) {
        self.url = url
        self.range = range
    }
}

public enum LinkDetector {
    // swiftlint:disable:next force_try
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\[\](){}\"\'`]+"#,
        options: [.caseInsensitive]
    )

    public static func detect(in text: String) -> [DetectedLink] {
        let nsRange = NSRange(text.startIndex..., in: text)
        return urlRegex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return DetectedLink(url: String(text[range]), range: range)
        }
    }
}
