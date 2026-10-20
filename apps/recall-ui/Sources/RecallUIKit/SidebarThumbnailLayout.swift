import CoreGraphics

/// Where a Working On item's little screenshot sits in its row (SPEC-DELTA 2:
/// "about 26 x 16 pt, in place of the kind symbol").
///
/// The screenshot is wider than a symbol, so it can't fit the symbol's slot
/// without pushing the item's name out of line with every other row's. It
/// reaches back toward the row's edge instead, and is nudged toward its name
/// so that it sits inside the selection with room on both sides.
///
/// The row's measures are the system's medium sidebar rows', taken from the
/// window's pictures: the selection's edge 10 pt in from the list's, the
/// symbol slot's trailing edge at 35 pt, and the name at 43 pt.
public enum SidebarThumbnailLayout {
    /// The screenshot's size.
    public static let size = CGSize(width: 24, height: 15)
    /// How far it moves from the symbol slot's trailing edge toward its name.
    public static let nudge: CGFloat = 2

    static let selectionEdge: CGFloat = 10
    static let slotTrailing: CGFloat = 35
    static let nameLeading: CGFloat = 43

    /// From the selection's edge to the screenshot.
    public static var insetFromSelection: CGFloat {
        slotTrailing + nudge - size.width - selectionEdge
    }

    /// From the screenshot to the item's name.
    public static var gapToName: CGFloat {
        nameLeading - (slotTrailing + nudge)
    }
}
