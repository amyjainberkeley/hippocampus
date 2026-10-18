import SwiftUI
import OnboardingKit

/// Screen 4. Privacy at a glance, before anything is read: three promises,
/// each a short lead with its detail under it, and what the menu-bar mark
/// shows. Consent is the click on Start Remembering in the bar below, the
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

/// The three promises, and what the menu-bar mark shows. The never-read
/// panel shows the same lines.
struct PromiseLines: View {
    let kept: String

    var body: some View {
        VStack(spacing: 0) {
            line("lock", lead: OnboardingCopy.promiseStaysLead, text: OnboardingCopy.promiseStays(kept: kept))
            Divider().padding(.leading, 62)
            line("eye.slash", lead: OnboardingCopy.promiseNeverReadLead, text: OnboardingCopy.promiseNeverRead)
            Divider().padding(.leading, 62)
            line("pause", lead: OnboardingCopy.promiseStopLead, text: OnboardingCopy.promiseStop)
            Divider()
            DotLegend()
        }
        .glassCard(padding: 0)
    }

    private func line(_ symbol: String, lead: String, text: String) -> some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.md + 2) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OnboardingDesign.Palette.accentSoft)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingDesign.Palette.accent)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, OnboardingDesign.Space.lg + 2)
        .padding(.vertical, OnboardingDesign.Space.md)
    }
}

/// What the menu-bar mark shows: the hi with its solid dot while it is
/// remembering, and without it when it is not (RULINGS B1). Drawn in one
/// colour, as the menu bar draws it; VoiceOver reads the promise whole.
struct DotLegend: View {
    var body: some View {
        HStack(spacing: OnboardingDesign.Space.xl) {
            Text(OnboardingCopy.dotLegendTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            entry(remembering: true, OnboardingCopy.dotLegendOn)
            entry(remembering: false, OnboardingCopy.dotLegendOff)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingDesign.Space.lg + 2)
        .padding(.vertical, OnboardingDesign.Space.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.dotPromise)
    }

    private func entry(remembering: Bool, _ label: String) -> some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            HiMarkGlyph(remembering: remembering, letters: OnboardingDesign.Palette.ink, monochrome: true)
                .frame(height: 13)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
