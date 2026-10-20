import Foundation

/// The window's words for handing context to AI tools (SPEC 5 and 9): the
/// Ask {Tool} button and its menu, the notes after it opens a tool, the
/// first-use sheet and the AI Tools page. None yet: the button reads
/// `UserFacingCopy.copyForYourAI` until Ask {Tool} lands. Every string
/// passes `CopyStyleValidator` and `scripts/check-launch-copy.sh`.
public enum HandoffCopy {}
