import SwiftUI

/// A small accent label chip — Raycast's "Core" / "Try AI" section tag.
/// Sets the editorial rhythm of a slide's left column: chip → big title →
/// one sentence.
struct SectionChip: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(OnboardingDesign.Palette.accent)
            .padding(.horizontal, OnboardingDesign.Space.md)
            .padding(.vertical, OnboardingDesign.Space.xs + 1)
            .background(
                Capsule().fill(OnboardingDesign.Palette.accentSoft)
            )
            .accessibilityAddTraits(.isHeader)
    }
}
