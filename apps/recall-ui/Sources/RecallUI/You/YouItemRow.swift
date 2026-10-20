import RecallUIKit
import SwiftUI

/// One thing Hippocampus understands about the person, in the exact words an
/// AI is given (RULINGS I7, I8): its basis, "Right" and "Forget", and "Why"
/// with the model's reasoning and one dated row per session it was learned in.
struct YouItemRow: View {
    let row: ModelItemRow
    @ObservedObject var model: UserModelViewModel
    let open: (RecallRoute) -> Void
    var whyOpen = false
    /// The Working On item the line names, linked after it.
    var item: WorkItem? = nil

    @State private var isWhyOpen = false
    @State private var didSetWhy = false
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        switch row {
        case let .item(item):
            itemView(item)
        case let .forgotten(item):
            HStack(spacing: 8) {
                Text(UserFacingCopy.You.forgotten)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                if model.canUndo(item) {
                    Button(UserFacingCopy.You.undo) { model.undo(item) }
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
    }

    private func itemView(_ item: ModelItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundStyle(MCI.Color.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let named = self.item {
                    LinkButton(title: named.name) { open(RecallRoute(workItem: named.id)) }
                }
            }
            HStack(spacing: 12) {
                Text(UserFacingCopy.You.basis(item.basis, daysSeen: item.daysSeen))
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                if !item.reasoning.isEmpty || !item.evidenceSessions.isEmpty {
                    Button {
                        isWhyOpen.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Text(UserFacingCopy.You.why)
                            Image(systemName: isWhyOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(UserFacingCopy.You.why)
                    .accessibilityAddTraits(isWhyOpen ? .isSelected : [])
                }
                Spacer(minLength: 8)
                if item.basis != .confirmed {
                    Button(UserFacingCopy.You.right) { model.confirm(item) }
                        .help(UserFacingCopy.You.rightHelp)
                        .buttonStyle(.bordered)
                }
                Button(UserFacingCopy.You.forget) { model.forget(item) }
                    .help(UserFacingCopy.You.forgetHelp)
                    .buttonStyle(.bordered)
            }
            if isWhyOpen {
                why(item)
            }
        }
        .padding(.vertical, 10)
        .onAppear {
            guard !didSetWhy else { return }
            didSetWhy = true
            isWhyOpen = whyOpen
        }
    }

    private func why(_ item: ModelItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UserFacingCopy.You.reasoningCaption)
                        .font(MCI.Font.footnote)
                        .foregroundStyle(MCI.Color.foregroundMuted)
                    Text(item.reasoning)
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !item.evidenceSessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.evidenceSessions.enumerated()), id: \.offset) { _, session in
                        Button {
                            open(.overview(showing: session.startUs...max(session.startUs, session.endUs)))
                        } label: {
                            HStack(spacing: 8) {
                                Text(SessionDetail.dayAndTime(startUs: session.startUs, endUs: session.endUs,
                                                              locale: locale, timeZone: timeZone))
                                    .font(MCI.Font.caption)
                                    .foregroundStyle(MCI.Color.accent)
                                Text(place(session))
                                    .font(MCI.Font.caption)
                                    .foregroundStyle(MCI.Color.foregroundSecondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func place(_ session: EvidenceSession) -> String {
        [session.appName, session.windowTitle ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }
}
