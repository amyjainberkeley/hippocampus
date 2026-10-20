import RecallUIKit
import SwiftUI

/// A note at the bottom of the window: "Forgot 1 moment." with Undo, or
/// "Opened in Claude. You send it from there." with Copy Instead (SPEC 2.13,
/// 3.11 and 5.3.8). One at a time: a new note takes the old one's place.
struct BottomNote: Identifiable {
    /// The note's one button.
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    let text: String
    /// A quieter line under it, such as the first forget's.
    var detail: String?
    let action: Action?
}

/// Where every place puts a note: `BottomNotes.show(_:action:)`. The window
/// draws the newest one at the bottom of the page for six seconds, or as long
/// as its button works (an Undo note: `ForgetCoordinator.undoWindow`), and
/// VoiceOver reads it out.
@MainActor
final class BottomNotes: ObservableObject {
    static let shared = BottomNotes()
    /// How long a note stays.
    static let shownFor: Duration = .seconds(6)

    @Published private(set) var current: BottomNote?
    private var hiding: Task<Void, Never>?

    /// Shows `text`, with a button when `action` is given, in place of any
    /// note showing now, for `duration`.
    @discardableResult
    static func show(_ text: String, detail: String? = nil, action: BottomNote.Action? = nil,
                     for duration: Duration = shownFor) -> UUID {
        shared.show(text, detail: detail, action: action, for: duration)
    }

    /// Shows the note for `duration`: six seconds, or exactly as long as its
    /// button works. Its id, to take it away early.
    @discardableResult
    func show(_ text: String, detail: String? = nil, action: BottomNote.Action? = nil,
              for duration: Duration = shownFor) -> UUID {
        let note = BottomNote(text: text, detail: detail, action: action)
        current = note
        AccessibilityNotification.Announcement(text).post()
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.current?.id == note.id else { return }
            self.current = nil
        }
        return note.id
    }

    /// Takes the note away now, as its button does once it has acted.
    func dismiss() {
        hiding?.cancel()
        current = nil
    }

    /// Takes `id`'s note away if it still shows: an Undo note once Undo no
    /// longer works. A newer note stays.
    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }
}

/// The window's place for the newest note: nothing at all while there is
/// none. A note rises 8 pt as it fades in, or only fades with Reduce Motion.
struct BottomNoteHost: View {
    @ObservedObject var notes: BottomNotes = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let note = notes.current {
                BottomNoteView(note: note) { notes.dismiss() }
                    .padding(.bottom, MCI.Spacing.l)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(MCI.Motion.standard, value: notes.current?.id)
    }
}

private struct BottomNoteView: View {
    let note: BottomNote
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: MCI.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: note.text)
                    .mciFont(.body)
                    .foregroundStyle(MCI.Color.foreground)
                if let detail = note.detail {
                    Text(verbatim: detail)
                        .mciFont(.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: note.detail == nil ? nil : 380, alignment: .leading)
            if let action = note.action {
                Button(action.title) {
                    action.perform()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
        .background(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous).fill(MCI.Color.surface))
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous)
                .strokeBorder(MCI.Color.border, lineWidth: 1)
        )
        .mciShadow(.card)
        .accessibilityElement(children: .contain)
    }
}
