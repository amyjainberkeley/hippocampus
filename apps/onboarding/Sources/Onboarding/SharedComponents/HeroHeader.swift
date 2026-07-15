import SwiftUI

/// How large the hero title reads. `.display` is the 52pt celebratory
/// bookend reserved for Welcome and Done; `.hero` is the 44pt sub-hero.
enum HeroTitleStyle {
    case display
    case hero
}

/// The oversized first-run hero — a glyph, a display title, and an optional
/// subtitle, with a calm fade-and-rise entrance (opacity + transform only,
/// Reduce-Motion aware). Used on the Welcome and primary-hotkey moments —
/// the two screens that must feel like "your Mac, but better."
struct HeroHeader<Icon: View>: View {
    private let icon: Icon
    private let title: String
    private let subtitle: String?
    private let titleStyle: HeroTitleStyle

    init(title: String,
         subtitle: String? = nil,
         titleStyle: HeroTitleStyle = .hero,
         @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.subtitle = subtitle
        self.titleStyle = titleStyle
        self.icon = icon()
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var titleText: Text {
        switch titleStyle {
        case .display: OnboardingDesign.TypeRamp.display(title)
        case .hero: OnboardingDesign.TypeRamp.hero(title)
        }
    }

    var body: some View {
        VStack(spacing: OnboardingDesign.Space.lg) {
            icon
                .scaleEffect(appeared || reduceMotion ? 1 : 0.9)

            VStack(spacing: OnboardingDesign.Space.sm) {
                titleText
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    OnboardingDesign.TypeRamp.body(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(OnboardingDesign.Motion.gentle) { appeared = true }
        }
    }
}
