import SwiftUI
import OnboardingKit

/// Screen 1. The hi mark on its tile, the headline, and a live demo of the
/// product: three moments from the app's own surfaces, played from made-up
/// data (`WelcomeDemoScript`). Under it, one sentence teaches the key that
/// opens Ask, with its keycaps in the line; they press as Ask opens in the
/// demo, twice for Shift twice and once for any other key. Under Reduce
/// Motion nothing moves: each moment shows whole and the next crossfades in
/// every 6 seconds.
///
/// The demo plays only while it can be watched (`WelcomeDemoPlayback`):
/// it holds still while the pointer is over it, so it can be read, and
/// while setup's window is not the key window. When the person moves past
/// Welcome the screen goes, and its task with it. Paused, no task runs.
struct WelcomeSlide: View {
    /// The key the person chose, read at render time (RULINGS X2).
    var key: AskKeyHint = .current()
    /// The renderer draws one still frame.
    var animates = true
    /// The frame the renderer draws; nil plays the demo.
    var demoFrame: DemoFrame?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var frame = WelcomeDemoScript.finalFrame(.ask)
    @State private var pressed = false
    @State private var playback = WelcomeDemoPlayback()

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
                    .arrivalFocus()
                    .padding(.bottom, OnboardingDesign.Space.lg + 4)

                VStack(spacing: 0) {
                    WelcomeDemo(frame: demoFrame ?? frame, still: reduceMotion)
                        .onHover { playback.hovering = $0 }
                        .padding(.bottom, OnboardingDesign.Space.lg + 2)

                    sentence
                }
                .arrivesAfterTitle()
            }
        }
        .onAppear { playback.windowIsKey = activeState == .key }
        .onChange(of: activeState) { _, state in playback.windowIsKey = state == .key }
        .onDisappear { playback.onWelcome = false }
        // Starts over when the key or Reduce Motion changes, and stops
        // whenever the demo is paused: nothing runs while it holds still.
        .task(id: DemoTaskID(key: key, reduceMotion: reduceMotion, playing: playback.isPlaying)) { await play() }
    }

    private struct DemoTaskID: Equatable {
        let key: AskKeyHint
        let reduceMotion: Bool
        let playing: Bool
    }

    private var sentence: some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            Text(key.verb)
            KeycapRow(keycaps: key.keycaps, pressed: pressed || (demoFrame?.keyDown ?? false), size: 14)
            Text(OnboardingCopy.welcomeBodyAfterKeys)
        }
        .font(.system(size: 15))
        .foregroundStyle(OnboardingDesign.Palette.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.welcomeBodySpoken(key))
    }

    /// Keep the demo's time while it plays. The keycaps press when the
    /// script says the key is down, as many times as the key is pressed
    /// (`key.pulseTimes`). Under Reduce Motion each moment shows whole and
    /// the next crossfades in; the keycaps never press.
    private func play() async {
        guard animates, demoFrame == nil else { return }
        guard playback.isPlaying else {
            if pressed { pressed = false }
            return
        }
        let presses = key.pulseTimes.count
        var last = Date()
        while !Task.isCancelled {
            let now = Date()
            playback.advance(by: now.timeIntervalSince(last))
            last = now
            let next = playback.frame(presses: presses, reduceMotion: reduceMotion)
            if next != frame {
                if reduceMotion {
                    withAnimation(.easeInOut(duration: 0.3)) { frame = next }
                } else {
                    frame = next
                }
            }
            let down = !reduceMotion && next.keyDown
            if down != pressed {
                withAnimation(.easeOut(duration: down ? 0.08 : 0.16)) { pressed = down }
            }
            // Under Reduce Motion only a crossfade every 6 seconds is due.
            try? await Task.sleep(for: reduceMotion ? .milliseconds(250) : .milliseconds(40))
        }
    }
}
