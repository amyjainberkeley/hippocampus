import OnboardingKit
import SwiftUI

/// The app icon, drawn: the hi mark on its tile in the Lab colours, at the
/// top of Welcome. Built from the icon's own geometry (`OnboardingHiMark`),
/// so it is the icon in the Dock at any size.
///
/// The tile's white-to-grey fall is the icon's own "lab" gradient
/// (assets/branding/AppIcon.svg). It is the only gradient setup draws:
/// every backdrop stays the native material, and
/// scripts/test-product-visual-assets.sh allows a gradient in this file only.
struct HiMarkTile: View {
    var side: CGFloat = 56

    var body: some View {
        ZStack {
            TileShape()
                .fill(.linearGradient(
                    colors: [HiMarkGlyph.color(OnboardingHiMark.tileTopRGB),
                             HiMarkGlyph.color(OnboardingHiMark.tileBottomRGB)],
                    startPoint: .top, endPoint: .bottom
                ))
            TileShape()
                .stroke(Color.black.opacity(0.1), lineWidth: max(0.5, side / 210))
            TileMarkShape(part: .letters).fill(HiMarkGlyph.navy)
            TileMarkShape(part: .dot).fill(HiMarkGlyph.blue)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.12), radius: side * 0.09, y: side * 0.05)
        .accessibilityHidden(true)
    }

    /// The squircle, from Apple's 1024 grid to the frame.
    private struct TileShape: Shape {
        func path(in rect: CGRect) -> Path {
            let tile = OnboardingHiMark.iconTileRect
            var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / tile.width, y: rect.height / tile.height)
                .translatedBy(x: -tile.minX, y: -tile.minY)
            let path = OnboardingHiMark.tile()
            return Path(path.copy(using: &transform) ?? path)
        }
    }

    /// The letters or the dot where the icon puts them on the tile.
    private struct TileMarkShape: Shape {
        let part: HiMarkPartShape.Part

        func path(in rect: CGRect) -> Path {
            let place = OnboardingHiMark.markInTile
            var transform = CGAffineTransform(
                translationX: rect.minX + place.origin.x * rect.width,
                y: rect.minY + place.origin.y * rect.height
            ).scaledBy(x: place.scale * rect.width, y: place.scale * rect.height)
            let path = part == .letters ? OnboardingHiMark.letters() : OnboardingHiMark.dot()
            return Path(path.copy(using: &transform) ?? path)
        }
    }
}
