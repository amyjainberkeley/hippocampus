import Foundation

/// The window's words for Demo Memory (SPEC-DELTA 6). Every string passes
/// `CopyStyleValidator` and `scripts/check-launch-copy.sh`.
public enum DemoCopy {
    /// The small tag by the window's title while it reads Demo Memory.
    public static let tag = "Demo"
    /// What VoiceOver reads for the tag.
    public static let tagLabel = "Demo Memory"
}
