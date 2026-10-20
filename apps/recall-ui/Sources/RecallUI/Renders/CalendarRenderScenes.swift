#if DEBUG
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// The note after Today's Show Calendar when the calendar can't be shown
    /// (`calendar-note-*`), light and dark, each from its own notes: nothing
    /// asks macOS or reads a calendar. Today's offer and bars and an item
    /// page's meetings are drawn by their own pages' scenes, from a fake
    /// calendar.
    static var calendarScenes: [Scene] {
        [false, true].flatMap { dark -> [Scene] in
            let suffix = dark ? "-dark" : ""
            return [
                .picture("calendar-note-not-allowed\(suffix)", size: CGSize(width: 900, height: 220), dark: dark) {
                    AnyView(calendarNote(CalendarCopy.notAllowed, action: CalendarCopy.openSystemSettings))
                },
                .picture("calendar-note-could-not-ask\(suffix)", size: CGSize(width: 900, height: 220), dark: dark) {
                    AnyView(calendarNote(CalendarCopy.couldNotAsk, action: nil))
                },
            ]
        }
    }

    /// A note at the bottom of the window, from its own notes.
    @MainActor
    private static func calendarNote(_ text: String, action: String?) -> some View {
        let notes = BottomNotes()
        notes.show(text, action: action.map { BottomNote.Action(title: $0) {} })
        return ZStack(alignment: .bottom) {
            MCI.Color.background
            BottomNoteHost(notes: notes)
        }
    }
}
#endif
