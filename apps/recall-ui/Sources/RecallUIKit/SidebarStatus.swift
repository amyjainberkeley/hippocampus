import Foundation

/// The line at the foot of the window's sidebar: whether Hippocampus is
/// remembering, read from the status it saves (RULINGS W10).
public struct SidebarStatus: Equatable, Sendable {
    public let text: String
    /// The hi mark keeps its blue dot only while this is true.
    public let remembering: Bool

    /// "Remembering" while the saved status is fresh and nothing blocks it; a
    /// skipped window still counts, because the rest of the screen is read
    /// (RULINGS B1). "Not remembering" when the status is old or names a
    /// block. "Not remembering right now." when there is no status at all.
    public init(receipt: CaptureHealthReceipt?, now: Date = Date()) {
        guard let receipt else {
            text = UserFacingCopy.footerNoStatus
            remembering = false
            return
        }
        if receipt.isStale(now: now) || receipt.blockedReason != nil {
            text = UserFacingCopy.footerNotRemembering
            remembering = false
        } else {
            text = UserFacingCopy.footerRemembering
            remembering = true
        }
    }
}
