import SwiftUI
import OnboardingKit

/// The window's two parts: a screen above, the bar below. The flow, the
/// panels and the preview renderer all draw through this, so a render is
/// the window as it ships.
struct OnboardingWindow<Content: View, Bar: View>: View {
    private let content: Content
    private let bar: Bar

    init(@ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.content = content()
        self.bar = bar()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .frame(width: OnboardingTheme.windowWidth, height: OnboardingTheme.windowHeight)
        .background(OnboardingMaterialBackdrop(intensity: 0.6))
    }
}

/// The bottom bar: Back on the left, the dots in the middle, the one
/// primary button on the right. A panel has no dots and no Back.
struct BottomBar: View {
    /// The screen the dots mark; nil in a panel.
    var screen: OnboardingScreen?
    /// Nil hides Back.
    var back: (() -> Void)?
    let primaryLabel: String
    var primaryEnabled = true
    let primary: () -> Void

    /// Back and the primary button sit in equal slots, so the dots stay
    /// centred whatever the button says.
    static let sideWidth: CGFloat = 230

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.onboardingSolidFills) private var solidFills

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

            Button(primaryLabel, action: primary)
                .keyboardShortcut(.defaultAction)
                .onboardingPrimary()
                .disabled(!primaryEnabled)
                .opacity(primaryEnabled ? 1 : 0.5)
                .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, OnboardingDesign.Space.xl)
        .padding(.vertical, OnboardingDesign.Space.md + 2)
        .background(
            solidFills
                ? AnyShapeStyle(OnboardingDesign.Palette.windowSolid)
                : reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// A screen's title and the sentence under it, centred.
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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
