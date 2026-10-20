// SPDX-License-Identifier: Apache-2.0
//
// CalendarPreferencesSection.swift — the calendar in Preferences
// (SPEC-DELTA 5).

import HippocampusKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Preferences' switch for showing the calendar on Today: read-only, on
/// this Mac only, offered once on Today and here (SPEC-DELTA 5). Turning it
/// on asks macOS for Calendars access; when macOS denies it or takes it back
/// later, the switch keeps the person's choice and says how to allow it
/// again in System Settings, with Open System Settings…. Only each event's
/// title, time, calendar and place are read; attendee lists never are.
///
/// Preferences › General shows it under the Ask key. It reads the person's
/// own calendar choice, or a model made from fakes for pictures
/// (`calendarPreferencePreview`).
struct CalendarPreferencesSection: View {
    @Environment(\.calendarPreferencePreview) private var preview

    var body: some View {
        CalendarPreferencesRows(model: preview ?? Self.ownModel)
    }

    /// The person's own calendar choice. In pictures of Preferences that
    /// don't pass a model, a switch that is off, made from fakes: no picture
    /// reads this Mac's calendar permission.
    @MainActor private static var ownModel: CalendarPreferenceModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HIPPOCAMPUS_RENDER_BAR"] != nil { return pictureModel }
        #endif
        return .shared
    }

    #if DEBUG
    @MainActor private static let pictureModel = CalendarPreferenceModel(
        store: FixedCalendarAccess(.notDetermined), setting: .inMemory(), openURL: { _ in }
    )
    #endif
}

private struct CalendarPreferencesRows: View {
    @ObservedObject var model: CalendarPreferenceModel

    /// The caption and button line up with the switch's label.
    private static let labelIndent: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            Divider()
            VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
                Toggle(CalendarCopy.toggle, isOn: Binding(
                    get: { model.isOn },
                    set: { on in Task { await model.setOn(on) } }
                ))
                .disabled(!model.canChange)
                VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
                    Text(model.caption)
                        .font(PreferencesStyle.captionFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.offersSystemSettings {
                        Button(CalendarCopy.openSystemSettings) { model.openSystemSettings() }
                    }
                }
                .padding(.leading, Self.labelIndent)
            }
            .accessibilityElement(children: .contain)
        }
        // macOS may have changed its answer since Preferences last looked: on
        // showing, and on coming back from System Settings. Neither asks.
        .onAppear { model.recheck() }
        #if canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheck()
        }
        #endif
    }
}

private struct CalendarPreferencePreviewKey: EnvironmentKey {
    static let defaultValue: CalendarPreferenceModel? = nil
}

extension EnvironmentValues {
    /// A calendar switch made from fakes, shown instead of the person's own,
    /// for pictures.
    var calendarPreferencePreview: CalendarPreferenceModel? {
        get { self[CalendarPreferencePreviewKey.self] }
        set { self[CalendarPreferencePreviewKey.self] = newValue }
    }
}
