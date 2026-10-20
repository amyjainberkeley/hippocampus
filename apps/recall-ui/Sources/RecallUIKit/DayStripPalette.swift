import SwiftUI

/// The colour of each kind of work on Today's day strip, its legend and a
/// session's card (SPEC 2.14).
///
/// Six kinds, named with the sidebar's words: Code, Documents,
/// Conversations, Web Pages, Calls and Other (`StripKind`). The agent's ten
/// kinds of work fold into them, so writing, design and planning are all
/// Documents and share its orange. The six hues come from the set already
/// checked for the usual colour-vision differences on both window
/// backgrounds; amber, the planning red (too close to the error red) and
/// design's green are gone, and nothing on the strip is yellow. A kind keeps
/// its colour on every day, and its name is always written beside it
/// (legend, hover, card), so colour is never the only way to tell kinds apart.
public enum DayStripPalette {
    public struct Swatch: Equatable, Sendable {
        public let light: UInt32
        public let dark: UInt32
    }

    /// Selection and focus in the window (RULINGS B4).
    public static let accent = Swatch(light: 0x2F6BFF, dark: 0x2F6BFF)

    public static func swatch(for kind: StripKind) -> Swatch {
        switch kind {
        case .code: Swatch(light: 0x2A78D6, dark: 0x3987E5)
        case .documents: Swatch(light: 0xEB6834, dark: 0xD95926)
        case .conversations: Swatch(light: 0x1BAF7A, dark: 0x199E70)
        case .webPages: Swatch(light: 0x6250D6, dark: 0x9085E9)
        case .calls: Swatch(light: 0xE87BA4, dark: 0xD55181)
        case .other: Swatch(light: 0xA1A5AC, dark: 0x6B7078)
        }
    }

    /// The agent's kind of work, by the strip kind it folds into.
    public static func swatch(for kind: WorkKind) -> Swatch {
        swatch(for: StripKind(kind))
    }

    public static func color(for kind: StripKind) -> Color {
        color(swatch(for: kind))
    }

    public static func color(for kind: WorkKind) -> Color {
        color(swatch(for: kind))
    }

    public static func color(_ swatch: Swatch) -> Color {
        MCI.Color.hex(light: swatch.light, dark: swatch.dark)
    }
}
