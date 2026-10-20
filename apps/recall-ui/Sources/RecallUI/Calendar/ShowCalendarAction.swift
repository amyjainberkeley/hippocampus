import RecallUIKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Today's Show Calendar (SPEC-DELTA 5): turns the person's calendar on,
/// asking macOS only if it never has, then says what happened when the
/// calendar can't be shown (`SystemCalendar.show()`). Once it shows, the bars
/// appearing say it.
///
/// The shell sets Today's `showCalendar` to this, except in the synthetic
/// preview and while Demo Memory is in use, where nothing asks macOS for the
/// person's calendar.
@MainActor
enum ShowCalendarAction {
    static func run(
        _ calendar: SystemCalendar = .live(),
        notes: BottomNotes = .shared,
        refresh: @escaping @MainActor () async -> Void
    ) async {
        let outcome = await calendar.show()
        if let note = outcome.note {
            let settings = outcome.offersSystemSettings
                ? BottomNote.Action(title: CalendarCopy.openSystemSettings) { openSystemSettings() }
                : nil
            notes.show(note, action: settings)
        }
        await refresh()
    }

    /// System Settings › Privacy & Security › Calendars.
    static func openSystemSettings() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(SystemCalendar.settingsURL)
        #endif
    }
}
