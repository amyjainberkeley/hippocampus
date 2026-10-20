// SPDX-License-Identifier: Apache-2.0
//
// CalendarPreferenceModel.swift — Preferences' calendar switch (SPEC-DELTA 5):
// what it shows, and what turning it on and off does.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Preferences › General's "Show my calendar on Today". Turning it on keeps
/// the person's choice and asks macOS for full access to events, only if
/// macOS never has; turning it off stops every read. When macOS says no or
/// takes access back later, the switch keeps the person's choice and says
/// why nothing shows, with Open System Settings… where they can allow it,
/// and turning it off clears that. When this Mac doesn't let apps read
/// calendars, the switch is off and can't change. Nothing here asks macOS
/// except `setOn(true)`.
@MainActor
public final class CalendarPreferenceModel: ObservableObject {
    public enum State: Equatable, Sendable {
        /// Not chosen, turned off, or chosen before macOS was asked.
        case off
        /// macOS is asking the person.
        case asking
        /// Chosen, and macOS allows it: Today shows the calendar.
        case on
        /// Chosen, but macOS said no, took it back, or allows adding events
        /// only. Preferences says how to allow it in System Settings.
        case denied
        /// This Mac doesn't let apps read calendars. Nothing to turn on.
        case restricted
    }

    /// The person's own calendar, as the app's Preferences show it.
    public static let shared = CalendarPreferenceModel()

    @Published public private(set) var state: State
    /// macOS couldn't be asked; cleared by the next change.
    @Published public private(set) var couldNotAsk = false

    private let store: any CalendarAccessStore
    private let setting: CalendarSetting
    private let openURL: @MainActor (URL) -> Void

    /// `store` is EventKit and `setting` the app's own defaults, unless a
    /// test or a picture passes fakes; `openURL` opens System Settings.
    public init(
        store: any CalendarAccessStore = EventKitCalendarAccess.shared,
        setting: CalendarSetting = CalendarSetting(),
        openURL: @escaping @MainActor (URL) -> Void = CalendarPreferenceModel.openInWorkspace
    ) {
        self.store = store
        self.setting = setting
        self.openURL = openURL
        state = Self.state(choice: setting.choice, permission: store.permission())
    }

    /// What the switch shows for the person's choice and what macOS allows.
    public static func state(choice: Bool?, permission: CalendarPermission) -> State {
        if permission == .restricted { return .restricted }
        guard choice == true else { return .off }
        switch permission {
        case .fullAccess: return .on
        case .notDetermined: return .off
        case .addOnly, .denied, .restricted: return .denied
        }
    }

    /// The switch shows the person's choice: on while the calendar shows,
    /// while macOS is asking, and while macOS doesn't allow it, which the
    /// caption explains. Turning it off then clears the explanation.
    public var isOn: Bool { state == .on || state == .asking || state == .denied }

    /// Whether the switch can be changed now.
    public var canChange: Bool { state != .asking && state != .restricted }

    /// Whether Open System Settings… shows: when the person can allow it there.
    public var offersSystemSettings: Bool { state == .denied }

    /// The words under the switch.
    public var caption: String {
        switch state {
        case .off, .on, .asking: couldNotAsk ? CalendarCopy.couldNotAsk : CalendarCopy.about
        case .denied: CalendarCopy.notAllowed
        case .restricted: CalendarCopy.restricted
        }
    }

    /// Reads the choice and what macOS allows again, as when Preferences
    /// shows or the person comes back from System Settings. Never asks.
    public func recheck() {
        guard state != .asking else { return }
        state = Self.state(choice: setting.choice, permission: store.permission())
    }

    /// Turns the calendar on or off. On asks macOS only if it never has; if
    /// it said no before, it won't ask again, and the switch says how to allow
    /// it in System Settings.
    public func setOn(_ on: Bool) async {
        guard state != .asking else { return }
        couldNotAsk = false
        setting.set(on)
        guard on, store.permission() == .notDetermined else {
            recheck()
            return
        }
        state = .asking
        do {
            _ = try await store.requestFullAccess()
        } catch {
            couldNotAsk = true
        }
        let permission = store.permission()
        if permission == .notDetermined {
            // Nothing was decided: the choice goes back, so the switch and
            // the window agree it is off, and the switch says macOS couldn't
            // be asked.
            setting.set(false)
            couldNotAsk = true
        }
        state = Self.state(choice: setting.choice, permission: permission)
    }

    /// Opens System Settings › Privacy & Security › Calendars.
    public func openSystemSettings() {
        openURL(Self.settingsURL)
    }

    /// Where the person allows Hippocampus to read calendars.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!

    public static func openInWorkspace(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
