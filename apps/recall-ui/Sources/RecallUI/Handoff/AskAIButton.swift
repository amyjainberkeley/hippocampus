import AppKit
import RecallUIKit
import SwiftUI

/// The one button that hands what a person picked to their AI (SPEC 5.3):
/// on Today's card and a session, in History's detail, on a Working On page
/// and under an answer.
///
/// A seam for now: it is today's Copy for your AI, which copies Markdown for
/// its source: a session's own moments, the cited packet for a question, or
/// the moments picked. The Ask {Tool} split button, its menu, the first-use
/// sheet and each tool's link land with the handoff. A Working On item has
/// nothing to copy until then, so it shows no button: there is never a
/// button that does nothing.
struct AskAIButton: View {
    let source: AskAISource
    let reader: BrainReader
    /// The bordered-prominent look of a card's main button.
    var prominent = false
    /// What a question's copy holds: the cited context packet
    /// (`mci-agent context`), focused on the question.
    var contextExporter: @Sendable (String) async throws -> String = {
        try await ContextHandoffExporter.export(focus: $0)
    }

    var body: some View {
        switch source {
        case let .session(title, range):
            CopyMarkdownButton(prominent: prominent) {
                try await SessionCopy.markdown(title: title, range: range, reader: reader)
            }
        case let .moments(ids):
            CopyMarkdownButton(prominent: prominent) {
                try await Self.markdown(moments: ids, reader: reader)
            }
        case let .question(question, _):
            CopyQuestionButton(question: question, contextExporter: contextExporter)
        case .item:
            EmptyView()
        }
    }

    /// The picked moments as Markdown, oldest first, each with its whole
    /// reading, under the newest one's caption.
    nonisolated static func markdown(moments ids: [UInt64], reader: BrainReader) async throws -> String {
        let hits = try await reader.fetchEventsByIds(ids).sorted { $0.tsUs < $1.tsUs }
        var readings: [UInt64: EventReading] = [:]
        for hit in hits {
            if let reading = try? await reader.eventReading(eventId: hit.id), reading.matches(hit) {
                readings[hit.id] = reading
            }
        }
        let newest = hits.last
        let title = newest.flatMap { $0.caption ?? readings[$0.id]?.caption }
            ?? Formatters.appDisplayName(newest?.appBundleId)
        return SessionCopy.markdown(title: title, moments: hits, readings: readings)
    }
}

/// "Copy for your AI" that copies `markdown()`, says "Copied" for two
/// seconds, and says when it couldn't (RULINGS I13).
private struct CopyMarkdownButton: View {
    var prominent = false
    let markdown: @Sendable () async throws -> String

    private enum Phase { case idle, copying, copied, failed }
    @State private var phase: Phase = .idle

    var body: some View {
        HStack(spacing: 8) {
            let button = Button {
                Task { await copy() }
            } label: {
                Text(phase == .copied ? UserFacingCopy.Overview.copied : UserFacingCopy.copyForYourAI)
            }
            .disabled(phase == .copying)
            if prominent {
                button.buttonStyle(.borderedProminent).tint(DayStripPalette.color(DayStripPalette.accent))
            } else {
                button.buttonStyle(.bordered)
            }
            if phase == .failed {
                Text(UserFacingCopy.Overview.couldNotCopy)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.error)
            }
        }
    }

    @MainActor
    private func copy() async {
        phase = .copying
        do {
            let text = try await markdown()
            let board = NSPasteboard.general
            board.clearContents()
            guard board.setString(text, forType: .string) else {
                phase = .failed
                return
            }
            phase = .copied
            try? await Task.sleep(for: .seconds(2))
            if phase == .copied { phase = .idle }
        } catch {
            phase = .failed
        }
    }
}

/// An answer's "Copy for your AI": the cited packet for its question, with
/// a note when it is copied and an alert when it can't be.
private struct CopyQuestionButton: View {
    let question: String
    let contextExporter: @Sendable (String) async throws -> String

    @State private var isCopying = false
    @State private var copyFailed = false

    var body: some View {
        Button(UserFacingCopy.copyForYourAI) { copy() }
            .buttonStyle(.bordered)
            .disabled(isCopying)
            .help(UserFacingCopy.copyForYourAIHelp)
            .alert(UserFacingCopy.copyFailedTitle, isPresented: $copyFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(UserFacingCopy.copyFailedBody)
            }
    }

    private func copy() {
        guard !isCopying else { return }
        isCopying = true
        Task {
            defer { isCopying = false }
            do {
                let packet = try await contextExporter(question)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(packet, forType: .string) else {
                    copyFailed = true
                    return
                }
                ToastNotifier.shared.notify(UserFacingCopy.copiedToast)
            } catch {
                copyFailed = true
            }
        }
    }
}
