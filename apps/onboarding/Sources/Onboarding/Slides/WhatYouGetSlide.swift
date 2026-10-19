import SwiftUI
import OnboardingKit

/// Screen 2. What Hippocampus does for the person, before it asks for
/// anything: three cards, each topped by a small render of the surface that
/// does it, drawn from the same made-up data as Welcome's demo. The title
/// sits where the next screens put theirs, so it stays put as the person
/// moves on.
struct WhatYouGetSlide: View {
    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
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
        }
    }
}

/// One thing Hippocampus does: its render across the top of the card, then
/// a headline and one line. Every headline keeps room for two lines, so the
/// three lines under them start level.
private struct BenefitCard<Preview: View>: View {
    let title: String
    let line: String
    @ViewBuilder let preview: Preview

    static var previewHeight: CGFloat { 164 }
    static var height: CGFloat { 292 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: Self.previewHeight)
                .background(MiniPalette.desktop)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(OnboardingDesign.Palette.hairline).frame(height: 1)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, OnboardingDesign.Space.md + 2)
            .padding(.top, OnboardingDesign.Space.md + 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card, style: .continuous))
        .glassCard(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

/// Ask with its answer and the answer's source, as it drops in.
private struct FindPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                HiMarkGlyph().frame(height: 9)
                Text(OnboardingCopy.Demo.askQuestion)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MiniPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 5) {
                Text(OnboardingCopy.Demo.askAnswer)
                    .font(.system(size: 9.5))
                    .foregroundStyle(MiniPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(OnboardingCopy.Demo.sourcesLabel)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(MiniPalette.secondary)
                    .padding(.top, 1)
                HStack(spacing: 5) {
                    AppIconImage(bundleId: "com.apple.Safari", side: 12)
                    Text(OnboardingCopy.Demo.source)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(MiniPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(9)
        }
        .background(MiniPalette.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
    }
}

/// An AI tool starting a session with what Hippocampus shares.
private struct AIPreview: View {
    var body: some View {
        MiniWindow(title: OnboardingCopy.Demo.aiWindowTitle, titleBar: 16) {
            VStack(alignment: .leading, spacing: 8) {
                MiniContextBlock(linesShown: OnboardingCopy.Demo.aiContextLines.count, size: 8)
                HStack(spacing: 5) {
                    Text("›").foregroundStyle(MiniPalette.secondary)
                    Text(OnboardingCopy.Demo.aiPrompt).foregroundStyle(MiniPalette.ink)
                }
                .font(.system(size: 8.5, design: .monospaced))
            }
            .padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
    }
}
