import SwiftUI

/// A calm, appearance-adaptive backdrop — a soft accent glow that fades to
/// the window background. On dark appearance it reads as a Raycast-style
/// hero glow; on light it's a whisper. Opacity is capped low (≤ 0.14) so it
/// never competes with content. Static (no animation) by design.
struct GradientBackdrop: View {
    /// 0…1 multiplier. Hero slides (`Welcome`, hotkey moment) use ~1.0;
    /// the always-on flow chrome uses ~0.45 for a barely-there wash.
    var intensity: Double = 1.0

    var body: some View {
        ZStack {
            Rectangle().fill(.background)

            RadialGradient(
                gradient: Gradient(colors: [
                    OnboardingDesign.Palette.accentBright.opacity(0.14 * intensity),
                    OnboardingDesign.Palette.accent.opacity(0.05 * intensity),
                    .clear,
                ]),
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 680
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Places a `GradientBackdrop` behind the view.
    func onboardingBackdrop(intensity: Double = 0.45) -> some View {
        background(GradientBackdrop(intensity: intensity))
    }
}
