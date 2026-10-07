import RecallUIKit
import SwiftUI

struct ScreenshotRereadSection: View {
    let hit: Hit
    let reader: any BrainReader
    @ObservedObject var model: ScreenshotRereadViewModel
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Read the saved image again", systemImage: "text.viewfinder")
                .font(.headline)
            Text("Runs on your Mac. The original text and search record stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            switch model.state(for: hit) {
            case .idle:
                rereadButton
            case .reading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading screenshot…").font(.callout)
                    Spacer()
                    Button("Cancel") { model.clear() }
                }
            case let .finished(outcome):
                result(outcome)
                rereadButton
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var rereadButton: some View {
        Button("Re-read screenshot", systemImage: "arrow.clockwise") { model.start(hit: hit, reader: reader) }
            .disabled(hit.thumbnailURL == nil)
    }

    @ViewBuilder
    private func result(_ outcome: ScreenshotRereadOutcome) -> some View {
        switch outcome {
        case let .text(text, omittedLines):
            Text("New reading").font(.subheadline.bold())
            Text(text).textSelection(.enabled)
            if omittedLines > 0 {
                Text("\(omittedLines) uncertain readings omitted. Check the image for missing words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("OCR can still misread small or covered text.").font(.caption).foregroundStyle(.secondary)
            Button("Copy new reading", systemImage: "doc.on.doc") {
                Task {
                    if let text = await model.copyText(for: hit, reader: reader), !Task.isCancelled { copy(text) }
                }
            }
        case .unreadable:
            message("No reliable text could be read. Older screenshots may be too small, blurred, or covered up.")
        case .timedOut:
            message("Reading took too long. Try again when your Mac is less busy.")
        case .blocked:
            message("The new reading was withheld by the privacy filter.")
        case .unavailable:
            message("The saved image or local OCR worker is unavailable. No text was changed.")
        }
    }

    private func message(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
    }
}
