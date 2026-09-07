import Foundation

/// Keep the existing cited preview, then attach the selected event's bounded
/// stored text without routing it through the shared excerpt export limits.
public enum ScreenshotInspectorContext {
    public static func markdown(hit: Hit, text: EventText?) -> String {
        let preview = VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit])
        guard let text, text.matches(hit) else { return preview }
        let heading = text.isTruncated ? "Stored text (truncated)" : "Complete stored text"
        let limit = text.isTruncated ? " Truncated at the 128 KiB UTF-8 text limit." : ""

        // A longer fence keeps even captured Markdown/HTML inside the literal
        // block. The 128 KiB input bound also bounds both generated fences.
        var run = 0
        var longestRun = 0
        for byte in text.text.utf8 {
            run = byte == 96 ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return preview + "\n## \(heading)\n\nThe cited excerpt above is a preview; the stored text follows.\(limit)\n\n"
            + fence + "text\n" + text.text + "\n" + fence + "\n"
    }
}
