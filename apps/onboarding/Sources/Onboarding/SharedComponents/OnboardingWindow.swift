import SwiftUI
import OnboardingKit

/// The window's two parts: a screen above, the bar below. The flow, the
/// panels and the preview renderer all draw through this, so a render is
/// the window as it ships.
///
/// It is 760 by 560 and never resizes between screens. On a short screen
/// it is as tall as the screen allows (`onboardingWindowHeight`, SPEC
/// 7.7): the screen above scrolls inside it and the bar stays.
struct OnboardingWindow<Content: View, Bar: View>: View {
    private let content: Content
    private let bar: Bar

    @Environment(\.onboardingWindowHeight) private var windowHeight

    init(@ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.content = content()
        self.bar = bar()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            bar
        }
        .frame(width: OnboardingTheme.windowWidth, height: min(OnboardingTheme.windowHeight, windowHeight))
        .background(OnboardingMaterialBackdrop(intensity: 0.6))
    }
}

/// The bottom bar: Back on the left, the dots in the middle, the one
/// primary button on the right. A panel has no dots and no Back.
///
/// The primary button's label crossfades in 150 ms when it changes, and
/// the button keeps the width of the widest label it can show on this
/// screen, so it never moves under the pointer. A button that becomes
/// enabled fades from 45% to full in 150 ms; instant under Reduce Motion.
/// Off, it tells VoiceOver why. Return presses it, and full keyboard
/// access lands on it when a screen arrives.
struct BottomBar: View {
    /// The screen the dots mark; nil in a panel.
    var screen: OnboardingScreen?
    /// Nil hides Back.
    var back: (() -> Void)?
    let primaryLabel: String
    /// Every label the button can show on this screen, for its width.
    var primaryLabels: [String] = []
    var primaryEnabled = true
    /// Why the button is off, for VoiceOver.
    var primaryDisabledReason: String?
    let primary: () -> Void

    /// Back and the primary button sit in equal slots, so the dots stay
    /// centred whatever the button says.
    static let sideWidth: CGFloat = 230

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.onboardingIncreasedContrast) private var forcedContrast
    /// Increase Contrast: macOS's setting, or the renderer's picture of it.
    private var increasedContrast: Bool { forcedContrast || systemContrast == .increased }
    @Environment(\.onboardingSolidFills) private var solidFills
    @FocusState private var primaryFocused: Bool

    var body: some View {
        HStack(spacing: OnboardingDesign.Space.lg) {
            ZStack(alignment: .leading) {
                if let back {
                    Button(OnboardingCopy.back, action: back)
                        .keyboardShortcut(.cancelAction)
                        .onboardingSecondary()
                }
            }
            .frame(width: Self.sideWidth, alignment: .leading)

            Spacer(minLength: 0)
            if let screen {
                ProgressDots(screen: screen)
            }
            Spacer(minLength: 0)

            Button(action: primary) { primaryTitle }
                .keyboardShortcut(.defaultAction)
                .onboardingPrimary()
                .focused($primaryFocused)
                .disabled(!primaryEnabled)
                .opacity(primaryEnabled ? 1 : PrimaryButtonMotion.disabledOpacity)
                .animation(animation(PrimaryButtonMotion.enableFade), value: primaryEnabled)
                .accessibilityLabel(primaryLabel)
                .accessibilityHint(primaryDisabledReason ?? "")
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, OnboardingDesign.Space.xl)
        .padding(.vertical, OnboardingDesign.Space.md + 2)
        .background(
            solidFills || increasedContrast
                ? AnyShapeStyle(OnboardingDesign.Palette.windowSolid)
                : reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Hairline()
        }
        // The keyboard moves with the screen (SPEC 7.1).
        .onChange(of: screen) { primaryFocused = true }
    }

    /// The label, crossfading in place, over the widest label it can be.
    private var primaryTitle: some View {
        ZStack {
            ForEach(primaryLabels.filter { $0 != primaryLabel }, id: \.self) { label in
                Text(label).hidden()
            }
            Text(primaryLabel)
                .id(primaryLabel)
                .transition(.opacity)
        }
        .animation(animation(PrimaryButtonMotion.labelCrossfade), value: primaryLabel)
    }

    private func animation(_ seconds: Double) -> Animation? {
        PrimaryButtonMotion.duration(seconds, reduceMotion: reduceMotion).map { .easeOut(duration: $0) }
    }
}

/// A screen's title and the sentence under it, centred. A heading, and
/// where VoiceOver goes when the screen arrives.
struct ScreenHeader: View {
    let title: String
    var intro: String?

    var body: some View {
        VStack(spacing: OnboardingDesign.Space.sm) {
            OnboardingDesign.TypeRamp.title(title)
                .multilineTextAlignment(.center)
            if let intro {
                Text(intro)
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .arrivalFocus()
    }
}

/// A one-point line between parts, strong under Increase Contrast (SPEC
/// 7.7).
struct Hairline: View {
    var vertical = false
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.onboardingIncreasedContrast) private var forcedContrast
    /// Increase Contrast: macOS's setting, or the renderer's picture of it.
    private var increasedContrast: Bool { forcedContrast || systemContrast == .increased }

    var body: some View {
        Rectangle()
            .fill(increasedContrast ? Color.primary.opacity(0.45) : Color.primary.opacity(0.1))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
