import SwiftUI

/// One key, drawn as a keycap: "⇧", "right ⌘", "Space". When `pressed`,
/// it dips and takes the accent, which is how Welcome shows the press.
/// Opacity and transform only, so Reduce Motion can switch it off.
struct Keycap: View {
    let label: String
    var pressed = false
    var size: CGFloat = 15

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(OnboardingDesign.Palette.ink)
            .padding(.horizontal, label.count > 1 ? size * 0.6 : 0)
            .frame(minWidth: size * 2, minHeight: size * 1.85)
            .background(
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .fill(OnboardingDesign.Palette.accent)
                    .opacity(pressed ? 0.16 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                // The key's lower edge.
                RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 2)
                    .padding(.horizontal, size * 0.3)
                    .opacity(pressed ? 0 : 1)
            }
            .scaleEffect(pressed ? 0.9 : 1)
            .fixedSize()
    }
}

/// A key the person presses, as a row of keycaps: "⇧ ⇧", "⌃ ⇧ Space".
struct KeycapRow: View {
    let keycaps: [String]
    var pressed = false
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Keycap(label: cap, pressed: pressed, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}
