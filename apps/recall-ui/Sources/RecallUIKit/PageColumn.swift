import SwiftUI

/// The column a page's content sits in: About You, AI Tools, Privacy, Show
/// All and a Working On page. 940 pt at most with its margins inside,
/// centred in what the window gives the page, so moving from one page to the
/// next never moves the content sideways.
public enum PageColumn {
    /// The column's widest, its margins included.
    public static let maxWidth: CGFloat = 940
    /// The margin on either side of the content.
    public static let margin: CGFloat = 32

    /// Where the content starts in a page `width` wide.
    public static func contentStart(inPageWidth width: CGFloat) -> CGFloat {
        max(0, (width - maxWidth) / 2) + margin
    }
}

public extension View {
    /// This content in the page column (`PageColumn`), 24 pt from the top
    /// and 48 pt above the bottom.
    func pageColumn() -> some View {
        padding(.horizontal, PageColumn.margin)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: PageColumn.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}
