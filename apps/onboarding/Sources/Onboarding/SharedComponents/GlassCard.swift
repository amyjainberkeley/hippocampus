import SwiftUI

/// The default onboarding container — a thin-border card, no drop shadow,
/// generous inner padding (Stripe "1px border, no shadow, 24–32px padding").
/// Replaces the ad-hoc `Color.secondary.opacity(0.06)` blocks the slides
/// reached for, giving every surface one consistent, calm card treatment.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = OnboardingDesign.Space.lg
    var emphasized: Bool = false
    @ViewBuilder let content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    /// The border color, bumped to a visible weight when the viewer has
    /// asked for Increase Contrast (the default 0.10 hairline can vanish).
    private var borderColor: Color {
        if emphasized { return OnboardingDesign.Palette.accentHairline }
        return contrast == .increased
            ? Color.primary.opacity(0.3)
            : OnboardingDesign.Palette.hairline
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card, style: .continuous)
                    .fill(emphasized
                          ? OnboardingDesign.Palette.accentSoft
                          : OnboardingDesign.Palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card, style: .continuous)
                    .stroke(borderColor, lineWidth: contrast == .increased ? 1.5 : 1)
            )
    }
}

extension View {
    /// Wrap the view in the standard onboarding card.
    func glassCard(padding: CGFloat = OnboardingDesign.Space.lg,
                   emphasized: Bool = false) -> some View {
        GlassCard(padding: padding, emphasized: emphasized) { self }
    }
}
