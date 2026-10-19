// SPDX-License-Identifier: Apache-2.0
//
// StatusMenuView.swift — the menu-bar icon and its short menu, owned in
// AppKit (spec-shell S2). Every word comes from `StatusMenuModel.items(`, so
// tests pin them. The icon is the status's picture (RULINGS B1), with
// "Hippocampus, {line 1}" as its accessibility label and tooltip (RULINGS
// B2). The menu is rebuilt each time it opens, from a fresh status read.

import AppKit
import Combine
import HippocampusKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        /// The status row's button.
        let perform: (CaptureStatusAction) -> Void
        let ask: () -> Void
        let openWindow: () -> Void
        /// "Connect AI Tools…", or "AI Tools…" once a tool is connected.
        let aiTools: (_ connected: Bool) -> Void
        let preferences: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let supervisor: ProcessSupervisor
    private let modelProvisioner: BriefModelProvisioner
    private let askKey: AskKeyWatch
    private let actions: Actions
    private var statusWatch: AnyCancellable?
    private var shown: (picture: HiMark.State, label: String)?
    private var items: [StatusMenuModel.Item] = []
    /// Whether a tool has Hippocampus in its settings. Read off the main
    /// thread when the menu opens, for the next time it does.
    private var aiToolsConnected = false
    /// While Hippocampus quits nothing in the menu acts (RULINGS S7).
    private var quitting = false

    init(
        supervisor: ProcessSupervisor,
        modelProvisioner: BriefModelProvisioner,
        askKey: AskKeyWatch,
        actions: Actions
    ) {
        self.supervisor = supervisor
        self.modelProvisioner = modelProvisioner
        self.askKey = askKey
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        // Keeps its place in the menu bar. Removing it never quits the app.
        statusItem.autosaveName = "ai.hippocampus.status"
        // The icon is this menu-bar-only app's only control surface, so it is
        // always shown: a stale "hidden" visibility (from a crash or a
        // background launch) must never leave the app running with no way to
        // open or quit it.
        statusItem.isVisible = true
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // The icon follows the supervisor, a turn after it announces a change.
        statusWatch = supervisor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateIcon() } }
        refreshAITools()
    }

    /// After Connect AI Tools… connected a tool.
    func noteAIToolsConnected() {
        aiToolsConnected = true
    }

    /// From Quit until Hippocampus has stopped, the menu still opens but
    /// nothing in it acts; a failed restart turns it back on. The icon keeps
    /// following the supervisor, so it shows Off once the stop is done.
    func setQuitting(_ quitting: Bool) {
        self.quitting = quitting
        if quitting {
            for item in menu.items { item.isEnabled = false }
        }
    }

    private func updateIcon() {
        let status = supervisor.menuBarStatus
        let label = StatusMenuModel.accessibilityLabel(supervisor.statusRow())
        guard shown?.picture != status.markState || shown?.label != label else { return }
        shown = (status.markState, label)
        guard let button = statusItem.button else { return }
        button.image = MenuBarStatusIcon.image(for: status)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The status is polled every 5 s; read it now.
        supervisor.refreshCaptureStatus()
        modelProvisioner.refreshIfMissing()
        askKey.recheck()
        // A permission may have been turned back on in System Settings. Look
        // first, so the menu shows what the look started, as the icon does.
        supervisor.retryIfPermissionMayBeBack()
        let setupFinished = OnboardingSentinel.isComplete
        items = StatusMenuModel.items(
            row: supervisor.statusRow(setupFinished: setupFinished),
            setupComplete: supervisor.setup(finished: setupFinished) == .complete,
            askLabel: askKey.label,
            aiToolsConnected: aiToolsConnected
        )
        menu.removeAllItems()
        for (index, item) in items.enumerated() {
            menu.addItem(menuItem(item, index: index))
        }
        updateIcon()
        refreshAITools()
    }

    private func menuItem(_ item: StatusMenuModel.Item, index: Int) -> NSMenuItem {
        guard item.role != .separator else { return .separator() }
        let acts = item.isEnabled && !quitting
        let menuItem = NSMenuItem(
            title: item.title,
            action: acts ? #selector(choose(_:)) : nil,
            keyEquivalent: item.key?.key ?? ""
        )
        menuItem.target = self
        menuItem.tag = index
        menuItem.isEnabled = acts
        if let key = item.key {
            var modifiers: NSEvent.ModifierFlags = []
            if key.command { modifiers.insert(.command) }
            if key.shift { modifiers.insert(.shift) }
            if key.control { modifiers.insert(.control) }
            menuItem.keyEquivalentModifierMask = modifiers
        }
        if let badge = item.badge {
            menuItem.badge = NSMenuItemBadge(string: badge)
        }
        switch item.role {
        case .status:
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.menuFont(ofSize: 13).withWeight(.semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        case .detail:
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        default:
            break
        }
        return menuItem
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard !quitting, items.indices.contains(sender.tag) else { return }
        switch items[sender.tag].role {
        case .action(let action): actions.perform(action)
        case .ask: actions.ask()
        case .openWindow: actions.openWindow()
        case .aiTools: actions.aiTools(aiToolsConnected)
        case .preferences: actions.preferences()
        case .quit: actions.quit()
        case .status, .detail, .separator: break
        }
    }

    private func refreshAITools() {
        let environment = ProcessInfo.processInfo.environment
        Task.detached(priority: .utility) { [weak self] in
            let connected = !AIToolRegistrations.connected(environment: environment).isEmpty
            await self?.setAIToolsConnected(connected)
        }
    }

    private func setAIToolsConnected(_ connected: Bool) {
        aiToolsConnected = connected
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
