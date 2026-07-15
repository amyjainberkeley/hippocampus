import SwiftUI

/// The one canonical icon + text row — replaces the three near-identical
/// `bulletPoint` / `featureRow` / `trustPoint` helpers that each slide
/// re-rolled. Monochrome accent glyph in a fixed gutter, a title, and an
/// optional secondary line. Top-aligned so multi-line text reads cleanly.
struct IconTextRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var iconColor: Color = OnboardingDesign.Palette.accent

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
