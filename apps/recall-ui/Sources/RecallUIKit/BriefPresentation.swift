import Foundation

/// The shipping extractive format, not a general Markdown or HTML renderer.
/// Parse navigation before decoding evidence so quoted markers remain inert.
public enum BriefPresentation {
    public enum Row: Sendable, Equatable {
        case heading(String)
        case evidence(text: String, eventID: UInt64)
        case text(String)
    }

    private static let headings: Set<String> = ["What changed", "Open loops", "Recent activity"]
    private static let escapePattern = try! NSRegularExpression(pattern: "&#(35|38|42|60|62|91|92|93|95|96);")

    public static func rows(body: String, modelId: String, modelVersion: String) -> [Row] {
        guard modelId == "hippocampus-extractive", modelVersion == "2" else { return [.text(body)] }
        return body.split(separator: "\n").map { raw in
            let line = String(raw)
            if line.hasPrefix("## "), headings.contains(String(line.dropFirst(3))) {
                return .heading(String(line.dropFirst(3)))
            }
            if line.hasPrefix("- "), line.hasSuffix("]"),
               let marker = line.range(of: " [event:", options: .backwards),
               marker.lowerBound > line.index(line.startIndex, offsetBy: 2) {
                let digits = line[marker.upperBound..<line.index(before: line.endIndex)]
                if !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                   let id = UInt64(digits), id > 0 {
                    let text = String(line[line.index(line.startIndex, offsetBy: 2)..<marker.lowerBound])
                    return .evidence(text: decodeEscapes(text), eventID: id)
                }
            }
            return .text(line)
        }
    }

    /// Decode the author's finite escape alphabet once. Never decode newlines,
    /// arbitrary HTML, or recursively reinterpret a captured entity.
    private static func decodeEscapes(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in escapePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let number = UInt32(text[numberRange]), let scalar = UnicodeScalar(number) else { continue }
            result += text[cursor..<range.lowerBound]
            result.unicodeScalars.append(scalar)
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
