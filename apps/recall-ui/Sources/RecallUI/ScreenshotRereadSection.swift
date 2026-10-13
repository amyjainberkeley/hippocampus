import RecallUIKit
import SwiftUI

struct ScreenshotRereadSection: View {
    let hit: Hit
    let reader: any BrainReader
    @ObservedObject var model: ScreenshotRereadViewModel
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state(for: hit) {
            case .idle:
                rereadButton
            case .reading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(UserFacingCopy.readingAgain).font(.callout)
                    Spacer()
                    Button("Cancel") { model.clear() }
                }
            case let .finished(outcome):
                result(outcome)
                rereadButton
            }
            Text(UserFacingCopy.readAgainCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.brandAccentFill.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rereadButton: some View {
        Button(UserFacingCopy.readAgainAction, systemImage: "arrow.clockwise") { model.start(hit: hit, reader: reader) }
            .disabled(hit.thumbnailURL == nil)
    }

    @ViewBuilder
    private func result(_ outcome: ScreenshotRereadOutcome) -> some View {
        switch outcome {
        case let .text(text, _):
            Text(text).textSelection(.enabled)
            Button(UserFacingCopy.copyTextAction, systemImage: "doc.on.doc") {
                Task {
                    if let text = await model.copyText(for: hit, reader: reader), !Task.isCancelled { copy(text) }
                }
            }
        case .unreadable:
            message(UserFacingCopy.readAgainUnreadable)
        case .timedOut:
            message(UserFacingCopy.readAgainTimedOut)
        case .blocked:
            message(UserFacingCopy.readAgainBlocked)
        case .unavailable:
            message(UserFacingCopy.readAgainUnavailable)
        }
    }

    private func message(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
    }
}
