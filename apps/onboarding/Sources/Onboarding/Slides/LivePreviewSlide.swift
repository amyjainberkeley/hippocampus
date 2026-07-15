import SwiftUI
import OnboardingKit

struct LivePreviewSlide: View {
    @State private var visibleCount = 0
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let events = LivePreviewEvents.demo

    private var capturedCount: Int {
        events.prefix(visibleCount).filter { !$0.isBlocked }.count
    }

    private var blockedCount: Int {
        events.prefix(visibleCount).filter { $0.isBlocked }.count
    }

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                VStack(spacing: OnboardingDesign.Space.md) {
                    SectionChip(text: "Live Preview")
                    OnboardingDesign.TypeRamp.title("What Hippocampus captures")
                        .multilineTextAlignment(.center)

                    OnboardingDesign.TypeRamp.body(
                        "A live preview of the capture pipeline. Sensitive apps are blocked automatically."
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                }

                eventStream

                counterBar
            }
        }
        .onAppear { startAnimation() }
        .onDisappear { animationTask?.cancel() }
    }

    private var eventStream: some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                if event.id < visibleCount {
                    eventRow(event)
                        .transition(OnboardingDesign.Motion.entrance(reduceMotion: reduceMotion))
                }
            }
        }
        .glassCard(padding: OnboardingDesign.Space.md)
        .frame(maxWidth: 500)
        .animation(
            OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.gentle, reduceMotion: reduceMotion),
            value: visibleCount
        )
    }

    private func eventRow(_ event: LivePreviewEvent) -> some View {
        HStack(spacing: OnboardingDesign.Space.sm + 2) {
            OnboardingDesign.TypeRamp.mono(event.time)
                .foregroundStyle(.tertiary)
                .frame(width: 65, alignment: .leading)

            Image(systemName: event.systemIcon)
                .frame(width: 18)
                .foregroundStyle(event.isBlocked
                                 ? OnboardingDesign.Palette.excluded
                                 : OnboardingDesign.Palette.accent)

            Text(event.appName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 80, alignment: .leading)

            Text(event.isBlocked ? "Blocked: \(event.detail)" : event.detail)
                .font(.system(size: 12))
                .foregroundStyle(event.isBlocked ? OnboardingDesign.Palette.excluded : .secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: event.isBlocked ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(event.isBlocked
                                 ? OnboardingDesign.Palette.excluded
                                 : OnboardingDesign.Palette.success)
                .font(.system(size: 14))
        }
        .padding(.vertical, OnboardingDesign.Space.xs + 2)
    }

    private var counterBar: some View {
        HStack(spacing: OnboardingDesign.Space.lg) {
            Label("\(capturedCount) captured", systemImage: "checkmark.circle.fill")
                .foregroundStyle(OnboardingDesign.Palette.success)
            Label("\(blockedCount) blocked", systemImage: "xmark.circle.fill")
                .foregroundStyle(OnboardingDesign.Palette.excluded)
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func startAnimation() {
        visibleCount = 0
        animationTask = Task {
            for i in 1...events.count {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                visibleCount = i
            }
        }
    }
}
