import RecallUIKit
import SwiftUI

/// Resume: what was open in a Working On item's last session, with a
/// checkbox each (SPEC-DELTA 3): the code folder in its editor and a
/// terminal, documents through their links or their apps, web pages in the
/// browser they were read in (the newest ten ticked), other apps. A row
/// that can't open says why. Nothing opens until the click; ⌘↩ is the
/// default button. Resume sends nothing anywhere: it asks macOS to open
/// things, and the note after says what opened, with no Undo.
struct ResumeSheet: View {
    let itemId: String
    /// Services in place of the window's; the window's are the agent and
    /// macOS in the app, and nothing in the synthetic preview.
    var services: ResumeServices?
    /// Where the note after goes; the window's by default.
    var notes: BottomNotes = .shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.resumeServices) private var environmentServices
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview
    @Environment(\.workNow) private var now
    @Environment(\.workDisplayCalendar) private var calendar

    var body: some View {
        let resolved = services ?? (isSyntheticPreview ? .none : environmentServices ?? .system)
        ResumeSheetContent(model: ResumeSheetModel(itemId: itemId, planner: resolved.planner,
                                                   workspace: resolved.workspace, tabs: resolved.tabs,
                                                   rules: resolved.rules(), asked: resolved.asked),
                           notes: notes, now: now(), calendar: calendar) { dismiss() }
    }
}

/// The sheet over a model: drawn the same in the app and in renders.
struct ResumeSheetContent: View {
    @StateObject var model: ResumeSheetModel
    let notes: BottomNotes
    let now: Date
    let calendar: Calendar
    let close: () -> Void
    /// Renders draw a loaded sheet without its task.
    var loads = true

    init(model: ResumeSheetModel, notes: BottomNotes, now: Date, calendar: Calendar, loads: Bool = true,
         close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.notes = notes
        self.now = now
        self.calendar = calendar
        self.loads = loads
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(WorkCopy.loadFailed)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    Button(WorkCopy.tryAgain) { Task { await model.load() } }
                        .buttonStyle(WorkButtonStyle(small: true))
                }
            case .ready:
                if model.isEmpty {
                    Text(WorkCopy.resumeNothing)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .padding(.vertical, 8)
                } else {
                    list
                }
            }
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 540, alignment: .leading)
        .task {
            guard loads else { return }
            await model.load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let kind = model.plan?.item.flatMap({ WorkItem.Kind(rawValue: $0.kind) }) {
                WorkKindTile(kind: kind, side: 36)
            } else {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkCopy.resumeTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MCI.Color.foreground)
                    .accessibilityAddTraits(.isHeader)
                if let item = model.plan?.item, let session = model.plan?.session {
                    Text(WorkCopy.resumeLead(name: item.name,
                                             when: WorkFormat.when(us: session.endUs, now: now, calendar: calendar)))
                        .font(.system(size: 12.5))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ResumeRow.Group.allCases, id: \.self) { group in
                    let rows = model.rows(in: group)
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MCI.Color.foregroundMuted)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 0)
                                // Said where the ticks start, so it is seen
                                // before the list scrolls.
                                if group == .pages, model.pagesBeyondTheCap {
                                    Text(WorkCopy.resumeNewestTicked(ResumeSheetModel.pagesTicked))
                                        .font(.system(size: 11))
                                        .foregroundStyle(MCI.Color.foregroundSecondary)
                                }
                            }
                            .padding(.bottom, 4)
                            ForEach(rows) { row in
                                ResumeRowView(row: row) { model.toggle(row.id) }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MCI.Color.background))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MCI.Color.border, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            let counts = model.willOpen
            Text(model.state == .ready && !model.isEmpty ? WorkCopy.resumeWillOpen(tabs: counts.tabs, apps: counts.apps) : "")
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Spacer(minLength: 0)
            Button(WorkCopy.cancel, action: close)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(WorkButtonStyle())
            Button(WorkCopy.resume) {
                Task {
                    let note = await model.resume()
                    notes.show(note)
                    close()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(WorkButtonStyle(prominent: true))
            .disabled(!model.canResume)
            .opacity(model.canResume ? 1 : 0.5)
            .help("\(WorkCopy.resume)  \u{2318}\u{21A9}")
        }
    }
}

/// One row of the sheet: its checkbox, its app's icon, what it is and the
/// line under it. A row that can't open has no tick and says why.
struct ResumeRowView: View {
    let row: ResumeRow
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: Binding(get: { row.ticked }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!row.available)
            .accessibilityLabel(row.target.title)
            if let app = row.target.app {
                AppIcon(bundleId: app)
                    .frame(width: 18, height: 18)
                    .opacity(row.available ? 1 : 0.5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.target.title)
                    .font(.system(size: 13))
                    .foregroundStyle(row.available ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if row.available { toggle() } }
        .help(row.detail ?? row.target.title)
    }
}

/// Resume, the primary button on a Working On page, Today's card and an
/// answer about an item: it opens the sheet, which opens nothing by itself.
struct ResumeButton: View {
    let itemId: String
    let open: (RecallRoute) -> Void

    var body: some View {
        Button(WorkCopy.resume) { open(.resume(item: itemId)) }
            .buttonStyle(WorkButtonStyle(prominent: true))
    }
}

/// Which item's Resume sheet is open: what the window presents the sheet
/// with when a route asks for it (`RecallRoute.resume(item:)`).
struct ResumeSheetItem: Identifiable, Equatable {
    /// The item's id.
    let id: String
}
