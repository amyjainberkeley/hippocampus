import SwiftUI
import OnboardingKit

/// Cotypist-style wayfinding — a row of thin segments where the current step
/// is an elongated accent capsule, completed steps are a faint accent, and
/// upcoming steps are hairline. Replaces the 4pt loading bar's "how much is
/// left" read with a calmer "where am I" read. Single source of truth is
/// `OnboardingStep.rawValue` / `allCases`, so it can never drift from the flow.
///
/// The dots are decorative; the whole row exposes one VoiceOver label
/// (`"3 of 13"`), children hidden.
struct ProgressDots: View {
    private let total: Int
    private let current: Int
    private let a11yLabel: String

    /// Drive directly from the flow step.
    init(currentStep: OnboardingStep) {
        self.total = OnboardingStep.allCases.count
        self.current = currentStep.rawValue
        self.a11yLabel = currentStep.stepLabel
    }

    /// Drive an arbitrary sub-sequence (e.g. the permission choreography).
    init(count: Int, index: Int) {
        self.total = max(count, 1)
        self.current = min(max(index, 0), max(count - 1, 0))
        self.a11yLabel = "Step \(min(index + 1, count)) of \(count)"
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: OnboardingDesign.Space.xs + 2) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(fill(for: i))
                    .frame(width: i == current ? 20 : 6, height: 6)
            }
        }
        .animation(OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.standard, reduceMotion: reduceMotion),
                   value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
    }

    private func fill(for index: Int) -> Color {
        if index == current { return OnboardingDesign.Palette.accent }
        if index < current { return OnboardingDesign.Palette.accent.opacity(0.4) }
        return OnboardingDesign.Palette.hairline
    }
}
