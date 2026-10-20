import AppKit

/// How a note under a sidebar section wraps (SPEC 2.3, Working On's
/// footnote). A sidebar list gives each row one line unless the row says how
/// tall it is, so the note counts its own lines and is never cut off.
public enum SidebarNoteLayout {
    /// The note's type size.
    public static let fontSize: CGFloat = 11
    /// From a row's leading edge to its label: the icon's slot and the gap.
    public static let labelInset: CGFloat = 25
    /// A sidebar list's row inset on both sides, with room to spare.
    public static let listInsets: CGFloat = 40

    /// The width the words wrap to in a sidebar that wide.
    public static func textWidth(sidebarWidth: CGFloat) -> CGFloat {
        max(80, sidebarWidth - labelInset - listInsets)
    }

    /// How many lines the words take in a sidebar that wide.
    public static func lines(_ text: String, sidebarWidth: CGFloat) -> Int {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth(sidebarWidth: sidebarWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        return max(1, Int((bounds.height / lineHeight).rounded()))
    }

    /// The height every line of `text` needs in a sidebar that wide. A view
    /// sets these lines a little further apart than the font's own line
    /// height (14 points at 11), so each line is given a point more than that.
    public static func height(_ text: String, sidebarWidth: CGFloat) -> CGFloat {
        CGFloat(lines(text, sidebarWidth: sidebarWidth)) * linePitch + 2
    }

    /// The font's own line height.
    public static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return font.ascender - font.descender + font.leading
    }

    /// The room each line is given.
    public static var linePitch: CGFloat { ceil(lineHeight) + 1 }
}
