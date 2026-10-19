import OnboardingKit
import SwiftUI

/// One part of the hi mark, with the mark's ink box fitted into the frame
/// and centred, as the app draws it, so the letters never move when the
/// dot comes and goes.
struct HiMarkPartShape: Shape {
    enum Part { case letters, dot }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let box = OnboardingHiMark.inkBounds
        let scale = min(rect.width / box.width, rect.height / box.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - box.midX * scale,
            y: rect.midY - box.midY * scale
        ).scaledBy(x: scale, y: scale)
        let source = part == .letters ? OnboardingHiMark.letters() : OnboardingHiMark.dot()
        return Path(source.copy(using: &transform) ?? source)
    }
}

/// The hi mark: navy letters, and the blue dot while Hippocampus is
/// remembering. Without the dot, and dimmed, it is the menu bar's picture
/// for paused or off (RULINGS B1, B3).
struct HiMarkGlyph: View {
    var remembering = true
    var letters: Color = HiMarkGlyph.navy
    /// The menu bar draws the mark in one colour, as a template image, so
    /// its picture here takes the letters' colour for the dot too.
    var monochrome = false

    static let navy = color(OnboardingHiMark.lettersRGB)
    static let blue = color(OnboardingHiMark.dotRGB)

    static func color(_ rgb: UInt32) -> Color {
        let c = OnboardingHiMark.components(rgb)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    var body: some View {
        ZStack {
            HiMarkPartShape(part: .letters)
                .fill(letters.opacity(remembering ? 1 : 0.45))
            if remembering {
                HiMarkPartShape(part: .dot).fill(monochrome ? letters : Self.blue)
            }
        }
        .aspectRatio(OnboardingHiMark.inkBounds.width / OnboardingHiMark.inkBounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
