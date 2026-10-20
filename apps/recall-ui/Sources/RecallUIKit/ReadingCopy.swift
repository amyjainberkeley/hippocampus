import Foundation

/// The words of a moment's formatted text (SPEC 4 and 9): what the reading
/// view says around the text itself, such as a mail thread's "Earlier in
/// this thread" and VoiceOver's name for a code block. None yet. Every
/// string passes `CopyStyleValidator` and `scripts/check-launch-copy.sh`.
public enum ReadingCopy {}
