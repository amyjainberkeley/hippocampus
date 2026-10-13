import Foundation

/// Keep the existing cited preview, then attach the selected moment's bounded
/// reading without routing it through the shared excerpt export limits. What
/// the person was reading comes first; the rest of the window follows under
/// its own heading. Never the stored text, so never a header (RULINGS T14).
public enum ScreenshotInspectorContext {
    public static func markdown(hit: Hit, text: EventReading?) -> String {
        let preview = VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])
        guard let text, text.matches(hit) else { return preview }
        let heading = text.isTruncated ? "Text (shortened)" : "Text"
        let limit = text.isTruncated ? "Shortened to fit.\n\n" : ""
        var result = preview + "\n## \(heading)\n\n" + limit + literalBlock(text.main)
        if !text.rest.isEmpty {
            result += "\n## Also in this window\n\n" + literalBlock(text.rest)
        }
        return result
    }

    // A longer fence keeps even captured Markdown/HTML inside the literal
    // block. The bounded reading also bounds both generated fences.
    private static func literalBlock(_ text: String) -> String {
        var run = 0
        var longestRun = 0
        for byte in text.utf8 {
            run = byte == 96 ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return fence + "text\n" + text + "\n" + fence + "\n"
    }
}
