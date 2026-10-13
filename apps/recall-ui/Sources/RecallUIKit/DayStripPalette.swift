import SwiftUI

/// The colour of each kind of work on Overview's day strip, its legend and a
/// session's detail.
///
/// The eight hues are a categorical set checked for the usual colour-vision
/// differences on both window backgrounds (light and dark steps of the same
/// hues, adjacent pairs at least ΔE 8 apart under simulation). A ninth hue
/// would not stay apart from the rest, so media and other share one grey. A
/// kind keeps its colour on every day, whatever else the day holds, and its
/// name is always written beside it (legend, hover, detail), so colour is
/// never the only way to tell kinds apart.
public enum DayStripPalette {
    public struct Swatch: Equatable, Sendable {
        public let light: UInt32
        public let dark: UInt32
    }

    /// Selection and focus in the window (RULINGS B4).
    public static let accent = Swatch(light: 0x2F6BFF, dark: 0x2F6BFF)

    public static func swatch(for kind: WorkKind) -> Swatch {
        switch kind {
        case .code: Swatch(light: 0x2A78D6, dark: 0x3987E5)
        case .writing: Swatch(light: 0xEB6834, dark: 0xD95926)
        case .communication: Swatch(light: 0x1BAF7A, dark: 0x199E70)
        case .research: Swatch(light: 0xEDA100, dark: 0xC98500)
        case .meetings: Swatch(light: 0xE87BA4, dark: 0xD55181)
        case .design: Swatch(light: 0x008300, dark: 0x008300)
        case .ai: Swatch(light: 0x6250D6, dark: 0x9085E9)
        case .planning: Swatch(light: 0xE34948, dark: 0xE66767)
        case .media, .other: Swatch(light: 0xA1A5AC, dark: 0x6B7078)
        }
    }

    public static func color(for kind: WorkKind) -> Color {
        color(swatch(for: kind))
    }

    public static func color(_ swatch: Swatch) -> Color {
        MCI.Color.hex(light: swatch.light, dark: swatch.dark)
    }
}
