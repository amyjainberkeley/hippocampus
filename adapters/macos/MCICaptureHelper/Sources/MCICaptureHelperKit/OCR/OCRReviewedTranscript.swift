import Foundation

/// Local re-reading of already retained evidence. Never replaces the capture
/// admission gate. Both the raw candidates and the exact preview must clear
/// the same text privacy rules used by the capture emitter.
public enum OCRReviewedTranscript: Equatable, Sendable {
    case text(String, omittedLines: Int)
    case unreadable
    case blocked
    case timedOut

    public static func review(_ result: OCRResult) -> Self {
        guard !result.timedOut else { return .timedOut }
        let raw = result.recognizedLines.map(\.text).joined(separator: "\n")
        guard !raw.isEmpty, raw.utf8.count <= maxOCRTextBytes else { return .unreadable }
        guard !SuppressionCascade.containsSecretOrPII(raw) else { return .blocked }
        let readable = OCRMemoryText.make(from: result.recognizedLines)
        guard !readable.isEmpty else { return .unreadable }
        guard !SuppressionCascade.containsSecretOrPII(readable) else { return .blocked }
        return .text(readable, omittedLines: result.recognizedLines.filter { !OCRMemoryText.isReadable($0) }.count)
    }
}
