import SwiftUI
import OnboardingKit

struct LivePreviewSlide: View {
    @State private var visibleCount = 0
    @State private var animationTask: Task<Void, Never>?

    private let events = LivePreviewEvents.demo

    private var capturedCount: Int {
        events.prefix(visibleCount).filter { !$0.isBlocked }.count
    }

    private var blockedCount: Int {
        events.prefix(visibleCount).filter { $0.isBlocked }.count
    }

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                OnboardingTheme.title("What Hippocampus captures")

                Text("A live preview of the capture pipeline. Sensitive apps are blocked automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

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
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 500)
        .animation(.easeInOut(duration: 0.4), value: visibleCount)
    }

    private func eventRow(_ event: LivePreviewEvent) -> some View {
        HStack(spacing: 10) {
            Text(event.time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 65, alignment: .leading)

            Image(systemName: event.systemIcon)
                .frame(width: 18)
                .foregroundStyle(event.isBlocked ? .red : OnboardingTheme.accentBlue)

            Text(event.appName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 80, alignment: .leading)

            Text(event.isBlocked ? "Blocked: \(event.detail)" : event.detail)
                .font(.system(size: 12))
                .foregroundStyle(event.isBlocked ? .red : .secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: event.isBlocked ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(event.isBlocked ? .red : .green)
                .font(.system(size: 14))
        }
        .padding(.vertical, 6)
    }

    private var counterBar: some View {
        HStack(spacing: 16) {
            Label("\(capturedCount) captured", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Label("\(blockedCount) blocked", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
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
