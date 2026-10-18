import SwiftUI
import OnboardingKit

/// Screen 2. What Hippocampus does for the person, before it asks for
/// anything: three cards, each with a small render of the surface that
/// does it, drawn from the same made-up data as Welcome's demo.
struct WhatYouGetSlide: View {
    var body: some View {
        SlideContainer(alignment: .center) {
            VStack(spacing: OnboardingDesign.Space.xl + 4) {
                ScreenHeader(title: OnboardingCopy.whatYouGetTitle)

                HStack(alignment: .top, spacing: OnboardingDesign.Space.lg) {
                    BenefitCard(title: OnboardingCopy.findTitle, line: OnboardingCopy.findLine) {
                        FindPreview()
                    }
                    BenefitCard(title: OnboardingCopy.dayTitle, line: OnboardingCopy.dayLine) {
                        DayPreview()
                    }
                    BenefitCard(title: OnboardingCopy.aiTitle, line: OnboardingCopy.aiLine) {
                        AIPreview()
                    }
                }
            }
            .padding(.bottom, OnboardingDesign.Space.md)
        }
    }
}

/// One thing Hippocampus does: its render, a headline and one line.
private struct BenefitCard<Preview: View>: View {
    let title: String
    let line: String
    @ViewBuilder let preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .background(MiniPalette.desktop)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, OnboardingDesign.Space.lg)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingDesign.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, OnboardingDesign.Space.xs + 2)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(OnboardingDesign.Space.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 268, alignment: .top)
        .glassCard(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

/// Ask with its answer's source, as it drops in.
private struct FindPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                HiMarkGlyph().frame(height: 9)
                Text(OnboardingCopy.Demo.askQuestion)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MiniPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 5) {
                Text(OnboardingCopy.Demo.sourcesLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MiniPalette.secondary)
                HStack(spacing: 5) {
                    AppIconImage(bundleId: "com.apple.Safari", side: 13)
                    Text(OnboardingCopy.Demo.source)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MiniPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(8)
        }
        .background(MiniPalette.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .padding(.horizontal, 9)
    }
}

/// The day on its strip, and the session it ends on.
private struct DayPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(OnboardingCopy.Demo.today)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MiniPalette.ink)
            MiniDayStrip(sessionsShown: WelcomeDemoScript.day.count, highlightsLast: true, height: 14, showsHours: false)
            MiniSessionCard(compact: true)
        }
        .padding(10)
        .background(MiniPalette.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .padding(.horizontal, 9)
    }
}

/// What an AI tool starts a session with.
private struct AIPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MiniContextBlock(linesShown: OnboardingCopy.Demo.aiContextLines.count, size: 8.5, oneLineEach: true)
            HStack(spacing: 4) {
                Text("›").foregroundStyle(OnboardingDesign.Palette.accent)
                Text(OnboardingCopy.Demo.aiPrompt).foregroundStyle(MiniPalette.ink)
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(8)
        .background(MiniPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
        .padding(.horizontal, 9)
    }
}
