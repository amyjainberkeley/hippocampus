import SwiftUI

/// One screen's content: a column clear of the window's buttons, filling
/// the space above the bottom bar. It scrolls only when the text is too
/// big to fit (a large text size, a long translation).
struct SlideContainer<Content: View>: View {
    var alignment: Alignment = .top
    let content: Content

    init(alignment: Alignment = .top, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: OnboardingTheme.contentMaxWidth)
                    .padding(.horizontal, OnboardingTheme.slidePadding)
                    .padding(.top, OnboardingTheme.titleBarInset + OnboardingDesign.Space.lg)
                    .padding(.bottom, OnboardingDesign.Space.xl)
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height, alignment: alignment)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
