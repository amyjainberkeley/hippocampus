import SwiftUI
import OnboardingKit

/// Screen 1. The title names the product, so there is no icon. The one
/// sentence teaches the key that opens Ask, with its keycaps in the line;
/// they pulse twice for Shift twice and once for any other key, and stay
/// still under Reduce Motion. The clip of the real Ask panel comes later
/// (RULINGS O7); without it the screen is the title and that sentence.
struct WelcomeSlide: View {
    /// The key the person chose, read at render time (RULINGS X2).
    var key: AskKeyHint = .current()
    /// The renderer draws the keycaps still.
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        SlideContainer(alignment: .center) {
            VStack(spacing: OnboardingDesign.Space.xl) {
                OnboardingDesign.TypeRamp.display(OnboardingCopy.welcomeTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // Two even lines, "Hippocampus remembers / what you
                    // see.", rather than one word left over.
                    .frame(maxWidth: 500)
                    .accessibilityAddTraits(.isHeader)

                sentence
            }
            // Sit a little above the middle, where the eye expects it.
            .padding(.bottom, OnboardingDesign.Space.xxl)
        }
        .task(id: key) { await pulse() }
    }

    private var sentence: some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            Text(key.verb)
            KeycapRow(keycaps: key.keycaps, pressed: pressed)
            Text(OnboardingCopy.welcomeBodyAfterKeys)
        }
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.welcomeBodySpoken(key))
    }

    /// Press the keycaps the way the key is pressed, then rest, on a loop.
    private func pulse() async {
        guard animates, !reduceMotion else { return }
        while !Task.isCancelled {
            var elapsed: TimeInterval = 0
            for time in key.pulseTimes {
                try? await Task.sleep(for: .seconds(time - elapsed))
                withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                try? await Task.sleep(for: .seconds(0.12))
                withAnimation(.easeOut(duration: 0.16)) { pressed = false }
                elapsed = time + 0.12
            }
            try? await Task.sleep(for: .seconds(AskKeyHint.pulseCycle - elapsed))
        }
    }
}
