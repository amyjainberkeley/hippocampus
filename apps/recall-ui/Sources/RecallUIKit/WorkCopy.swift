import Foundation

/// The words of Working On, its item pages, Web Pages, Looked Up and Resume
/// (SPEC 3 and 9, SPEC-DELTA 2 and 3). Buttons are Title Case, sentences
/// are sentences. Every string passes `CopyStyleValidator` and
/// `scripts/check-launch-copy.sh`.
public enum WorkCopy {
    /// The primary button on a Working On page and Today's card, and the
    /// sheet's default button (⌘↩).
    public static let resume = "Resume"
    public static let resumeTitle = "Pick up where you left off"
    /// The sheet when nothing from the last session can be opened again.
    public static let resumeNothing = "Nothing to reopen."
    public static let cancel = "Cancel"
}
