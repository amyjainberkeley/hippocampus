// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The menu-bar app's words for the calendar (SPEC-DELTA 5): Preferences'
/// calendar switch, how to turn access back on when macOS takes it away, and
/// Ask's answer to "When did I last meet with …?". Every string passes
/// `MenuBarCopyStyleTests`' rules (`CalendarCopyTests`) and
/// `scripts/check-launch-copy.sh`.
public enum CalendarCopy {
    // MARK: Preferences › General

    /// The switch.
    public static let toggle = "Show my calendar on Today"
    /// Under the switch, on or off: what it does and what is read.
    public static let about = "Your meetings show above your day, and calls are named after them. Hippocampus reads only each event’s title, time, calendar and place. It stays on this Mac."
    /// Under the switch when macOS said no, took access back, or allows
    /// adding events only.
    public static let notAllowed = "macOS isn’t letting Hippocampus read your calendar. To show it, allow Hippocampus full access in System Settings › Privacy & Security › Calendars."
    /// Under the switch when this Mac doesn't let apps read calendars.
    public static let restricted = "This Mac doesn’t let apps read calendars, so Today can’t show yours."
    /// Under the switch when macOS couldn't be asked.
    public static let couldNotAsk = "Couldn’t ask macOS about your calendar. Try again."
    /// The button under `notAllowed`.
    public static let openSystemSettings = "Open System Settings…"

    // MARK: Ask

    /// "Your calendar shows you last met with Mira on Tuesday, October 13,
    /// 2:00 – 2:30 PM, in “Pricing review”." `about` is "with Mira" or "about
    /// pricing"; `when` is from `today`, `yesterday` or `onDay`.
    public static func lastMeeting(_ about: String, when: String, title: String) -> String {
        "Your calendar shows you last met \(about) \(when), in “\(title)”."
    }

    public static func today(_ hours: String) -> String { "today, \(hours)" }
    public static func yesterday(_ hours: String) -> String { "yesterday, \(hours)" }
    public static func onDay(_ day: String, _ hours: String) -> String { "on \(day), \(hours)" }

    /// Every fixed string above, for the copy checks.
    public static let all: [String] = [toggle, about, notAllowed, restricted, couldNotAsk, openSystemSettings]
}
