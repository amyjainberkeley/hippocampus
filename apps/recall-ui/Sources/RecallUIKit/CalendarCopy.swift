import Foundation

/// The window's words for the calendar (SPEC-DELTA 5). Today's one-time
/// offer ("Show your calendar on Today.", Show Calendar) and the day strip's
/// bars are Today's own words (`OverviewCopy`); these are the note after Show
/// Calendar when the calendar can't be shown. When macOS takes access back
/// later, the window says nothing: Today drops its bars, and Preferences says
/// how to turn it back on. Every string passes `CopyStyleValidator` and
/// `scripts/check-launch-copy.sh`.
public enum CalendarCopy {
    /// After Show Calendar, when macOS says no, or said no before and won't
    /// ask again.
    public static let notAllowed = "macOS isn’t letting Hippocampus read your calendar."
    /// That note's button: System Settings › Privacy & Security › Calendars.
    public static let openSystemSettings = "Open System Settings…"
    /// After Show Calendar, when macOS couldn't be asked.
    public static let couldNotAsk = "Couldn’t ask macOS about your calendar. Try again in Preferences."

    /// The note after Show Calendar, from what `SystemCalendar.turnOn()`
    /// returned; nil once the calendar shows.
    public static func note(after access: CalendarAccess) -> String? {
        switch access {
        case .allowed: nil
        case .denied: notAllowed
        case .notAsked: couldNotAsk
        }
    }

    /// Every string above, for the copy checks.
    public static let all: [String] = [notAllowed, openSystemSettings, couldNotAsk]
}
