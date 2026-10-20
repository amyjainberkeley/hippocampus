import SwiftUI

/// A calm window plane for the V1 light appearance. Native material adds
/// depth without decorative gradients or glows.
struct OnboardingMaterialBackdrop: View {
    var intensity: Double = 1.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.onboardingSolidFills) private var solidFills

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if solidFills {
                Rectangle().fill(OnboardingDesign.Palette.windowSolid)
            } else if !reduceTransparency {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.72 + (0.08 * intensity))
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Places the native material backdrop behind the view.
    func onboardingBackdrop(intensity: Double = 0.45) -> some View {
        background(OnboardingMaterialBackdrop(intensity: intensity))
    }
}

private struct SolidFillsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Solid colours where a material would be. The preview renderer draws
    /// off screen, where materials come out blank.
    var onboardingSolidFills: Bool {
        get { self[SolidFillsKey.self] }
        set { self[SolidFillsKey.self] = newValue }
    }
}

private struct IncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draws Increase Contrast's look whatever the Mac's setting: the
    /// renderer's pictures of it (SPEC 7.7). On screen it stays false and
    /// macOS's own setting decides.
    var onboardingIncreasedContrast: Bool {
        get { self[IncreasedContrastKey.self] }
        set { self[IncreasedContrastKey.self] = newValue }
    }
}
