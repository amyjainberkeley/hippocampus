import SwiftUI
import OnboardingKit

/// Screen 3. What happens to what Hippocampus reads, before anything is
/// read. Consent is the click on Start Remembering in the bar below, the
/// only thing that writes it. The open-at-login choice is made here and
/// recorded with consent. In review, consent exists and remembering has
/// started: the never-read panel's title, no body sentence, no checkbox,
/// and the button only continues.
struct PromiseSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    /// How long text and screenshots are kept, read from the retention file.
    let kept: String

    var body: some View {
        PromiseScreen(
            title: OnboardingCopy.promiseTitle(isReview: flowVM.isReview),
            intro: OnboardingCopy.promiseBody(isReview: flowVM.isReview),
            kept: kept,
            openAtLogin: flowVM.isReview ? nil : $flowVM.openAtLogin,
            keyFailed: !flowVM.isReview && prepareBrainVM.keyFailed,
            retryKey: { Task { await prepareBrainVM.generateKey() } }
        )
        // Setup may resume here without passing Permissions; the key is
        // set up once either way.
        .task {
            await prepareBrainVM.generateKey()
        }
    }
}

/// The screen as drawn: the preview renderer builds it from fixtures.
struct PromiseScreen: View {
    let title: String
    let intro: String?
    let kept: String
    /// The checkbox, on a first run only.
    let openAtLogin: Binding<Bool>?
    var keyFailed = false
    var retryKey: () -> Void = {}

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: title, intro: intro)

                PromiseLines(kept: kept)

                if keyFailed {
                    HStack(spacing: OnboardingDesign.Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(OnboardingDesign.Palette.attention)
                            .accessibilityHidden(true)
                        Text(OnboardingCopy.encryptionFailed)
                            .font(.system(size: 13))
                        Button(OnboardingCopy.tryAgain, action: retryKey)
                            .onboardingText(color: OnboardingDesign.Palette.accentText)
                    }
                }

                if let openAtLogin {
                    Toggle(OnboardingCopy.openAtLogin, isOn: openAtLogin)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                }
            }
        }
    }
}

/// The three lines of the promise, and what the menu-bar dot means. The
/// never-read panel shows the same lines.
struct PromiseLines: View {
    let kept: String

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.lg) {
            line("lock", lead: OnboardingCopy.promiseStaysLead, text: OnboardingCopy.promiseStays(kept: kept))
            line("eye.slash", lead: OnboardingCopy.promiseNeverReadLead, text: OnboardingCopy.promiseNeverRead)
            line("pause.circle", lead: OnboardingCopy.promiseStopLead, text: OnboardingCopy.promiseStop)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.md) {
                Circle()
                    .fill(OnboardingDesign.Palette.ink)
                    .frame(width: 7, height: 7)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(OnboardingCopy.dotPromise)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OnboardingDesign.Space.xl)
        .glassCard(padding: 0)
    }

    private func line(_ symbol: String, lead: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(OnboardingDesign.Palette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            (Text(lead).fontWeight(.semibold).foregroundStyle(OnboardingDesign.Palette.ink)
                + Text(" " + text).foregroundStyle(.secondary))
                .font(.system(size: 14))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
