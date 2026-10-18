import SwiftUI
import OnboardingKit

/// Screen 1. The hi mark on its tile, the headline, and a live demo of the
/// product: three moments from the app's own surfaces, played from made-up
/// data (`WelcomeDemoScript`). Under it, one sentence teaches the key that
/// opens Ask, with its keycaps in the line; they press as Ask opens in the
/// demo, twice for Shift twice and once for any other key. Under Reduce
/// Motion nothing moves: each moment shows whole and the next fades in.
struct WelcomeSlide: View {
    /// The key the person chose, read at render time (RULINGS X2).
    var key: AskKeyHint = .current()
    /// The renderer draws one still frame.
    var animates = true
    /// The frame the renderer draws; nil plays the demo.
    var demoFrame: DemoFrame?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = WelcomeDemoScript.finalFrame(.ask)
    @State private var pressed = false

    var body: some View {
        SlideContainer(alignment: .center) {
            VStack(spacing: 0) {
                HiMarkTile(side: 52)
                    .padding(.bottom, OnboardingDesign.Space.md + 2)

                Text(OnboardingCopy.welcomeTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, OnboardingDesign.Space.lg + 4)

                WelcomeDemo(frame: demoFrame ?? frame, still: reduceMotion)
                    .padding(.bottom, OnboardingDesign.Space.lg + 2)

                sentence
            }
        }
        // Starts over when the key or Reduce Motion changes.
        .task(id: DemoTaskID(key: key, reduceMotion: reduceMotion)) { await play() }
    }

    private struct DemoTaskID: Equatable {
        let key: AskKeyHint
        let reduceMotion: Bool
    }

    private var sentence: some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            Text(key.verb)
            KeycapRow(keycaps: key.keycaps, pressed: pressed || (demoFrame?.keyDown ?? false), size: 14)
            Text(OnboardingCopy.welcomeBodyAfterKeys)
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.welcomeBodySpoken(key))
    }

    /// Keep the demo's time. The keycaps press when the script says the key
    /// is down, as many times as the key is pressed (`key.pulseTimes`).
    private func play() async {
        guard animates, demoFrame == nil else { return }
        guard !reduceMotion else {
            await playStill()
            return
        }
        let start = Date()
        let presses = key.pulseTimes.count
        while !Task.isCancelled {
            let next = WelcomeDemoScript.frame(at: Date().timeIntervalSince(start), presses: presses)
            if next != frame { frame = next }
            if next.keyDown != pressed {
                withAnimation(.easeOut(duration: next.keyDown ? 0.08 : 0.16)) { pressed = next.keyDown }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Reduce Motion: each moment whole, the next fading in. Nothing moves.
    private func playStill() async {
        var index = 0
        while !Task.isCancelled {
            frame = WelcomeDemoScript.finalFrame(DemoMoment.allCases[index % DemoMoment.allCases.count])
            index += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
