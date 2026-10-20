// SPDX-License-Identifier: Apache-2.0
//
// DemoMemory.swift — Demo Memory, the made-up week the launch video and the
// screenshots are taken in (SPEC-DELTA 6).

import Foundation
import os

/// Demo Memory: a made-up founder's week in a store of its own, made by the
/// tools bundled beside the agent from code in the repo, for the launch
/// video and screenshots (SPEC-DELTA 6). The person's own memory is never
/// touched: while Demo Memory is in use, remembering is paused, and Leave
/// Demo Memory goes back to the person's own. Option-click the hi menu for
/// Use Demo Memory…; it is also in Preferences, under About.
///
/// The app reaches it in three places: every child's environment
/// (`ProcessSupervisorLaunchPlan.sanitizedEnvironment` calls
/// `childEnvironment`), the status menu's items (`menuItems`, appended by
/// `StatusMenuModel.items(…, extraItems:)`), and Preferences' About pane
/// (`DemoMemoryPreferencesSection`). Each changes nothing until the app
/// attaches a `DemoMemoryController` at launch (`attach`).
public enum DemoMemory {
    /// The window's flag, set to "1" while it reads Demo Memory so it shows
    /// its Demo tag (RecallUIKit's `DemoMemoryMode.environmentKey`; the two
    /// apps share no code).
    public static let windowEnvironmentKey = "MCI_DEMO_MEMORY"

    /// The Keychain service a child reading Demo Memory is told. It holds no
    /// item: Demo Memory's key is a file of its own, so a Keychain lookup
    /// from that child finds nothing and can never reach the person's key.
    public static let keychainService = "ai.hippocampus.demo-memory"
    public static let keychainAccount = "none"

    private struct Shown: Sendable {
        var active = false
        var store: URL?
    }

    /// The attached controller's phase, for callers off the main thread.
    private static let shown = OSAllocatedUnfairLock(initialState: Shown())
    @MainActor private static var attached: DemoMemoryController?

    /// Whether Demo Memory is in use.
    public static var isActive: Bool { shown.withLock { $0.active } }

    /// The demo store while Demo Memory is in use; nil otherwise.
    public static var storeURL: URL? { shown.withLock { $0.store } }

    /// The attached controller, for Preferences.
    @MainActor public static var controller: DemoMemoryController? { attached }

    /// Demo Memory for this app, once at launch, before remembering first
    /// starts: a week a run left behind is cleared first, and its pause
    /// taken back. `isConnectingAITools` says when Connect AI Tools… is
    /// writing the tools' settings, which always name the person's memory.
    @MainActor public static func attach(
        supervisor: ProcessSupervisor,
        isConnectingAITools: @escaping @MainActor () -> Bool = { false }
    ) {
        let host = SupervisorDemoMemoryHost(supervisor: supervisor, isConnectingAITools: isConnectingAITools)
        attach(DemoMemoryController(host: host, maker: BundledDemoMemoryMaker.bundled()))
    }

    /// Attaches `controller`, clearing whatever a run left behind.
    @MainActor public static func attach(_ controller: DemoMemoryController) {
        attached?.phaseChanged = nil
        attached = controller
        let database = controller.folder.database
        controller.phaseChanged = { phase in
            shown.withLock { $0 = Shown(active: phase == .on, store: phase == .on ? database : nil) }
        }
        controller.phaseChanged?(controller.phase)
        controller.finishLeftover()
    }

    /// For tests: nothing attached, as before launch.
    @MainActor static func detach() {
        attached?.phaseChanged = nil
        attached = nil
        shown.withLock { $0 = Shown() }
    }

    /// What a child the app starts sees. While Demo Memory is in use and
    /// nothing remembers: its store, its key and the window's flag. Otherwise
    /// `environment` as it is, except that a flag a parent passed down never
    /// gets through, so nothing reads the person's memory under the Demo
    /// tag. Off the main thread, always the person's own.
    public static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        var own = environment
        own.removeValue(forKey: windowEnvironmentKey)
        guard Thread.isMainThread else { return own }
        return MainActor.assumeIsolated { attached?.childEnvironment(own) ?? own }
    }

    /// What the status menu adds in a group of its own above Quit: Use Demo
    /// Memory… while Option is held, and while it is in use Leave Demo Memory
    /// with its Demo tag. None before a controller is attached.
    public static func menuItems(optionHeld: Bool) -> [StatusMenuModel.Item] {
        guard Thread.isMainThread else { return [] }
        return MainActor.assumeIsolated { attached?.menuItems(optionHeld: optionHeld) ?? [] }
    }

    /// Carries out one of those items, by the id of its `.extra` role.
    @MainActor
    public static func perform(_ id: String) {
        attached?.perform(id)
    }
}
