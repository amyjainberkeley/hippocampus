import SwiftUI

/// A calm window plane for the V1 light appearance. Native material adds
/// depth without decorative gradients or glows.
struct OnboardingMaterialBackdrop: View {
    var intensity: Double = 1.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if !reduceTransparency {
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
