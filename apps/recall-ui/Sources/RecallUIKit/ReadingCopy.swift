import Foundation

/// The words of a moment's formatted text (SPEC 4 and 9): what the reading
/// view says around the text itself. Every string passes `CopyStyleValidator`
/// and `scripts/check-launch-copy.sh`.
public enum ReadingCopy {
    /// A mail's quoted thread, closed when it is longer than six lines
    /// (SPEC 9, 152).
    public static let earlierInThread = "Earlier in this thread"
    /// VoiceOver's name for a code block, and its rotor of code blocks
    /// (SPEC 9, 153).
    public static let code = "Code"
    /// VoiceOver's rotor of lists.
    public static let lists = "Lists"
    /// VoiceOver's words for a checklist's ticked and empty boxes.
    public static let checked = "Done"
    public static let unchecked = "Not done"

    /// VoiceOver's name for a list (SPEC 2.15): "List, 4 items".
    public static func list(items: Int) -> String {
        items == 1 ? "List, 1 item" : "List, \(items) items"
    }
}
