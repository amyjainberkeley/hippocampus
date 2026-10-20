import SwiftUI
import OnboardingKit

/// Where you are in setup: one dot per screen, the current one a longer
/// accent capsule, the ones behind a faint accent, the ones ahead a
/// hairline. Driven by `OnboardingScreen`, so it can never drift from the
/// flow. Moving on, the active dot widens from 8 to 24 pt while the old one
/// narrows, in 250 ms; at once under Reduce Motion (SPEC 7.1). The dots are
/// decorative; the row has one VoiceOver label ("Step 2 of 5").
struct ProgressDots: View {
    private let total: Int
    private let current: Int

    init(screen: OnboardingScreen) {
        total = OnboardingScreen.allCases.count
        current = screen.rawValue
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: OnboardingDesign.Space.xs + 2) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(fill(for: index))
                    .frame(
                        width: index == current ? ProgressDotsMotion.activeWidth : ProgressDotsMotion.dotWidth,
                        height: ProgressDotsMotion.height
                    )
            }
        }
        .animation(
            ProgressDotsMotion.animationDuration(reduceMotion: reduceMotion).map { .easeInOut(duration: $0) },
            value: current
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }

    private func fill(for index: Int) -> Color {
        if index == current { return OnboardingDesign.Palette.accent }
        if index < current { return OnboardingDesign.Palette.accent.opacity(0.4) }
        return OnboardingDesign.Palette.hairline
    }
}
