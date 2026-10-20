import OnboardingKit
import SwiftUI

// How a screen arrives (SPEC 7.1): its title first and its content 60 ms
// later, VoiceOver on the new title. The screen as a whole fades and
// drifts in through `OnboardingDesign.Motion.screen`; these add the
// stagger inside it and the focus.

/// The arriving content under a screen's title: it starts 60 ms after the
/// title and ends with the screen's own fade. Together under Reduce Motion.
private struct ArrivesAfterTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A fixed share for the renderer's pictures; nil animates.
    @Environment(\.onboardingContentArrival) private var drawnArrival
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(drawnArrival ?? (arrived || reduceMotion ? 1 : 0))
            .onAppear {
                guard !arrived else { return }
                let transition = ScreenTransition(move: .forward, reduceMotion: reduceMotion)
                withAnimation(.easeOut(duration: transition.contentDuration).delay(transition.contentDelay)) {
                    arrived = true
                }
            }
    }
}

/// VoiceOver moves to the title when a screen arrives, once the move has
/// ended, so the new screen is read from its top.
private struct ArrivalFocus: ViewModifier {
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($focused)
            .task {
                try? await Task.sleep(for: .seconds(ScreenTransition.standardDuration))
                focused = true
            }
    }
}

extension View {
    /// The content under a screen's title: it arrives 60 ms after it.
    func arrivesAfterTitle() -> some View {
        modifier(ArrivesAfterTitle())
    }

    /// A screen's title: VoiceOver moves here when the screen arrives.
    func arrivalFocus() -> some View {
        modifier(ArrivalFocus())
    }
}

private struct ContentArrivalKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// The renderer's fixed share of a screen's content arrival, 0 to 1. Nil
    /// on screen, where the content animates in.
    var onboardingContentArrival: Double? {
        get { self[ContentArrivalKey.self] }
        set { self[ContentArrivalKey.self] = newValue }
    }
}
