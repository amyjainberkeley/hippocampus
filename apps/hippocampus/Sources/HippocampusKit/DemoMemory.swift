// SPDX-License-Identifier: Apache-2.0
//
// DemoMemory.swift — Demo Memory, the made-up week the launch video and the
// screenshots are taken in (SPEC-DELTA 6).

import Foundation

/// Demo Memory: a made-up founder's week in a store of its own, made by a
/// tool from code in the repo, for the launch video and screenshots
/// (SPEC-DELTA 6). The person's own memory is never touched: while Demo
/// Memory is in use, remembering is off, and Leave Demo Memory goes back to
/// the person's own. Option-click the hi menu for Use Demo Memory…; it is
/// also in Preferences, under About.
///
/// A seam for now: Demo Memory is never in use. The app reaches it in three
/// places, each a no-op while it is off: every child's environment
/// (`ProcessSupervisorLaunchPlan.sanitizedEnvironment` calls
/// `childEnvironment`), the status menu's items (`menuItems`, appended by
/// `StatusMenuModel.items(…, extraItems:)`), and Preferences' About pane
/// (`DemoMemoryPreferencesSection`).
public enum DemoMemory {
    /// Whether Demo Memory is in use. Never, for now.
    public static var isActive: Bool { false }

    /// The demo store, in a folder of its own, while Demo Memory is in use;
    /// nil otherwise, when every child reads the person's own memory.
    public static var storeURL: URL? { nil }

    /// The window's flag, set to "1" while it reads Demo Memory so it shows
    /// its Demo tag (RecallUIKit's `DemoMemoryMode.environmentKey`; the two
    /// apps share no code).
    public static let windowEnvironmentKey = "MCI_DEMO_MEMORY"

    /// What a child the app starts sees. While Demo Memory is in use: its
    /// store, its key and the window's flag. While it is off, `environment`
    /// as it is, except that a flag a parent passed down never gets through,
    /// so nothing reads the person's memory under the Demo tag.
    public static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: windowEnvironmentKey)
        return environment
    }

    /// What the status menu adds in a group of its own above Quit: Use Demo
    /// Memory… while Option is held, and while it is in use its Demo tag and
    /// Leave Demo Memory. None, for now.
    public static func menuItems(optionHeld: Bool) -> [StatusMenuModel.Item] {
        []
    }

    /// Carries out one of those items, by the id of its `.extra` role.
    /// Nothing, for now.
    @MainActor
    public static func perform(_ id: String) {}
}
