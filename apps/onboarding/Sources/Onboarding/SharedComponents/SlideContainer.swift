import SwiftUI

struct SlideContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                content
                    .frame(maxWidth: OnboardingTheme.contentMaxWidth)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OnboardingTheme.slidePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
