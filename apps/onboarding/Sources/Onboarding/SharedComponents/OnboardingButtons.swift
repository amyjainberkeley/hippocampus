import SwiftUI

/// The Hippocampus onboarding button ladder — filled pill (primary),
/// ghost (secondary), text-only (tertiary). One filled CTA per screen,
/// everything else steps down the ladder (Stripe "pill / ghost / text"
/// convention from the peer study). Press feedback is a calm scale +
/// opacity dip, collapsed to nothing under Reduce Motion. The ghost
/// border is Increase-Contrast aware (mirrors GlassCard).

// MARK: - Primary (filled accent pill)

struct PrimaryCTAStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        CTABody(configuration: configuration, fullWidth: fullWidth) { label, pressed, _ in
            label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, OnboardingDesign.Space.xl)
                .padding(.vertical, OnboardingDesign.Space.md)
                .background(
                    Capsule().fill(OnboardingDesign.Palette.accent)
                )
                .opacity(pressed ? 0.85 : 1)
        }
    }
}

// MARK: - Secondary (ghost / hairline-bordered pill)

struct SecondaryCTAStyle: ButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        CTABody(configuration: configuration, fullWidth: fullWidth) { label, pressed, hairline in
            label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, OnboardingDesign.Space.xl)
                .padding(.vertical, OnboardingDesign.Space.md)
                .background(
                    Capsule().fill(OnboardingDesign.Palette.cardFill)
                )
                .overlay(
                    Capsule().stroke(hairline.color, lineWidth: hairline.width)
                )
                .opacity(pressed ? 0.7 : 1)
        }
    }
}

// MARK: - Tertiary (text only)

struct TextCTAStyle: ButtonStyle {
    var color: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        CTABody(configuration: configuration, fullWidth: false) { label, pressed, _ in
            label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(color)
                .opacity(pressed ? 0.6 : 1)
        }
    }
}

// MARK: - Shared body (Reduce-Motion + Increase-Contrast aware)

/// A hairline spec resolved from the current contrast setting — the ghost
/// border color/width, bumped so it stays visible under Increase Contrast.
struct HairlineSpec {
    let color: Color
    let width: CGFloat
}

/// Wraps a button style's label so the tiny press-scale honors Reduce
/// Motion and the ghost border honors Increase Contrast (a ButtonStyle's
/// `makeBody` can't read `@Environment` directly, so the lookups live in
/// this nested view and are handed to the style closure).
private struct CTABody<Style: View>: View {
    let configuration: ButtonStyleConfiguration
    let fullWidth: Bool
    @ViewBuilder let style: (ButtonStyleConfiguration.Label, Bool, HairlineSpec) -> Style

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var hairline: HairlineSpec {
        contrast == .increased
            ? HairlineSpec(color: Color.primary.opacity(0.3), width: 1.5)
            : HairlineSpec(color: OnboardingDesign.Palette.hairline, width: 1)
    }

    var body: some View {
        style(configuration.label, configuration.isPressed, hairline)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(
                OnboardingDesign.Motion.resolve(.easeOut(duration: 0.12),
                                                reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

// MARK: - Ergonomic call-site sugar

extension View {
    /// Filled accent pill — the one primary action on a screen.
    func onboardingPrimary(fullWidth: Bool = false) -> some View {
        buttonStyle(PrimaryCTAStyle(fullWidth: fullWidth))
    }

    /// Ghost pill — secondary actions ("Skip for now", "I'll do it later").
    func onboardingSecondary(fullWidth: Bool = false) -> some View {
        buttonStyle(SecondaryCTAStyle(fullWidth: fullWidth))
    }

    /// Text-only — tertiary / escape-hatch actions.
    func onboardingText(color: Color = .secondary) -> some View {
        buttonStyle(TextCTAStyle(color: color))
    }
}
