// SPDX-License-Identifier: Apache-2.0
//
// CalendarPreferencesSection.swift — the calendar in Preferences
// (SPEC-DELTA 5).

import HippocampusKit
import SwiftUI

/// Preferences' switch for showing the calendar on Today: read-only, on
/// this Mac only, offered once on Today and here (SPEC-DELTA 5). Turning it
/// on asks macOS for Calendars access; when macOS denies it or takes it back
/// later, this says how to turn it on again. Attendee lists are never read.
///
/// A seam for now: it shows nothing. Preferences › General shows it under
/// the Ask key; its switch and words land with the calendar.
struct CalendarPreferencesSection: View {
    var body: some View {
        EmptyView()
    }
}
