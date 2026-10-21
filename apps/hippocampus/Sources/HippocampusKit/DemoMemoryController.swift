// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryController.swift — switching to Demo Memory and back
// (SPEC-DELTA 6).

import Combine
import Foundation

/// Switches the app to Demo Memory and back. Using it makes a fresh
/// made-up week in its own folder with its own key, pauses remembering, and
/// opens the window on the week; from then on the window and Ask read the
/// week, and the menu shows its Demo tag. Leaving opens the window on the
/// person's own memory again, takes back the pause if Demo Memory made it,
/// and removes the week. The person's own memory is never opened or
/// written, and nothing of Demo Memory's is ever in a child that remembers.
@MainActor
public final class DemoMemoryController: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case off
        /// The week is made and remembering pauses.
        case making
        /// The window and Ask read the week.
        case on
        /// Back to the person's own memory.
        case leaving
    }

    /// The ids of its menu items (`StatusMenuModel.Item.Role.extra`).
    public enum ItemID {
        public static let use = "demo-memory.use"
        public static let making = "demo-memory.making"
        public static let leave = "demo-memory.leave"
        public static let leaving = "demo-memory.leaving"
    }

    @Published public private(set) var phase: Phase = .off {
        didSet { if phase != oldValue { phaseChanged?(phase) } }
    }

    public let folder: DemoMemoryFolder
    private let home: URL
    private let host: DemoMemoryHost
    private let maker: DemoMemoryMaking
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let refreshInterval: Duration
    /// Whether remembering was paused before Demo Memory, so leaving leaves
    /// it so.
    private var wasPaused = true
    /// When the person's own timed pause would have ended: Demo Memory's
    /// pause stands in for it while the week is in use, and leaving puts it
    /// back.
    private var pausedUntil: Date?
    private var week = DemoMemoryWeek(moments: 0, screenshots: 0)
    private var refresher: Task<Void, Never>?
    private var watch: AnyCancellable?
    private var switching: Task<Void, Never>?
    /// Set by `DemoMemory.attach`, which mirrors the phase for callers off
    /// the main thread.
    var phaseChanged: ((Phase) -> Void)?

    public init(
        host: DemoMemoryHost,
        maker: DemoMemoryMaking,
        folder: DemoMemoryFolder = .standard(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        refreshInterval: Duration = .seconds(30)
    ) {
        self.host = host
        self.maker = maker
        self.folder = folder
        self.home = home
        self.now = now
        self.timeZone = timeZone
        self.refreshInterval = refreshInterval
    }

    /// The window and Ask read Demo Memory.
    public var isActive: Bool { phase == .on }

    /// A switch is under way, from the question to its end.
    public var isSwitching: Bool { switching != nil }

    // MARK: What children see

    /// What a child the app starts sees. Demo Memory's store, key and the
    /// window's flag only while it is in use and nothing remembers: a child
    /// started while remembering starts (its helper and agent, the key
    /// check before them), or while Connect AI Tools… writes the tools'
    /// settings, gets the person's own memory, always. Remembering starting
    /// also ends Demo Memory.
    public func childEnvironment(_ environment: [String: String]) -> [String: String] {
        var own = environment
        own.removeValue(forKey: DemoMemory.windowEnvironmentKey)
        guard phase == .on else { return own }
        guard host.isQuiet else {
            rememberingChanged()
            return own
        }
        guard !host.isConnectingAITools else { return own }
        return Self.demoEnvironment(own, folder: folder)
    }

    /// The person's own environment, pointed at Demo Memory: its store, its
    /// key through the file key's path (the Keychain is never asked, and the
    /// service named instead holds no item), the window's Demo flag, and no
    /// searches kept from the made-up week. A release build's window and
    /// Ask use only the bundled agent.
    nonisolated static func demoEnvironment(
        _ own: [String: String], folder: DemoMemoryFolder
    ) -> [String: String] {
        var demo = own
        demo["MCI_DB_PATH"] = folder.database.path
        demo["MCI_DEVELOPMENT_FILE_KEY"] = "1"
        demo["MCI_DB_KEY_FILE"] = folder.keyFile.path
        demo["MCI_DB_KEYCHAIN_SERVICE"] = DemoMemory.keychainService
        demo["MCI_DB_KEYCHAIN_ACCOUNT"] = DemoMemory.keychainAccount
        demo["MCI_DB_KEYCHAIN_STORAGE_MODEL"] = KeychainKeyStore.storageModel
        demo.removeValue(forKey: "MCI_DB_KEY_HEX")
        if own["MCI_DEVELOPMENT_FILE_KEY"] != "1" {
            demo.removeValue(forKey: "MCI_AGENT_PATH")
        }
        demo[DemoMemory.windowEnvironmentKey] = "1"
        demo["MCI_EPHEMERAL_UI_STATE"] = "1"
        return demo
    }

    // MARK: The menu

    /// Use Demo Memory… while Option is held; while it is made or left, what
    /// is happening; while it is in use, Leave Demo Memory with the Demo tag.
    public func menuItems(optionHeld: Bool) -> [StatusMenuModel.Item] {
        switch phase {
        case .off:
            return optionHeld && switching == nil
                ? [StatusMenuModel.Item(role: .extra(ItemID.use), title: DemoCopy.use)] : []
        case .making:
            return [StatusMenuModel.Item(role: .extra(ItemID.making), title: DemoCopy.making, isEnabled: false)]
        case .on:
            return [StatusMenuModel.Item(role: .extra(ItemID.leave), title: DemoCopy.leave, badge: DemoCopy.tag)]
        case .leaving:
            return [StatusMenuModel.Item(role: .extra(ItemID.leaving), title: DemoCopy.leaving, isEnabled: false)]
        }
    }

    /// Carries out a menu item.
    public func perform(_ id: String) {
        switch id {
        case ItemID.use: requestUse()
        case ItemID.leave: requestLeave()
        default: break
        }
    }

    /// Use Demo Memory…: asks first, then switches.
    public func requestUse() {
        guard phase == .off, switching == nil else { return }
        switching = Task { [weak self] in
            guard let self else { return }
            if await self.host.confirmUse() {
                await self.use()
            }
            self.switching = nil
        }
    }

    /// Leave Demo Memory, from the menu bar or the window's footer. False
    /// when it isn't in use, or a switch is under way.
    @discardableResult
    public func requestLeave() -> Bool {
        requestLeave(restoringRemembering: true)
    }

    @discardableResult
    private func requestLeave(restoringRemembering: Bool) -> Bool {
        guard phase == .on, switching == nil else { return false }
        switching = Task { [weak self] in
            guard let self else { return }
            await self.leave(restoringRemembering: restoringRemembering)
            self.switching = nil
        }
        return true
    }

    // MARK: Switching

    /// Makes a fresh week, pauses remembering and opens the window on the
    /// week. Anything that fails leaves the person's memory and remembering
    /// as they were, and says so. Returns whether Demo Memory is in use.
    @discardableResult
    public func use() async -> Bool {
        guard phase == .off else { return phase == .on }
        phase = .making
        let made: DemoMemoryWeek
        do {
            try folder.prepareEmpty(home: home)
            let key = try folder.makeKey()
            made = try await maker.make(into: folder, keyHex: key, now: now(), timeZone: timeZone())
            try folder.writeCaptureStatus(now: now(), moments: made.moments, screenshots: made.screenshots)
        } catch {
            folder.remove()
            phase = .off
            host.report(Self.message(for: error))
            return false
        }
        // Read only now: the person may have paused while the week was made.
        let wasPaused = host.isPaused
        // A pause that ends on its own would turn remembering on mid-take:
        // Demo Memory's own pause takes its place until Leave.
        let pausedUntil = wasPaused ? host.pausedUntil : nil
        do {
            try folder.writeInUse(.init(enteredAt: now(), wasPaused: wasPaused, pausedUntil: pausedUntil))
            if !wasPaused || !host.isQuiet || pausedUntil != nil {
                try await host.pauseRemembering()
            }
        } catch {
            putBack(wasPaused: wasPaused, pausedUntil: pausedUntil)
            folder.remove()
            phase = .off
            host.report(DemoCopy.couldntPause)
            return false
        }
        self.wasPaused = wasPaused
        self.pausedUntil = pausedUntil
        week = made
        phase = .on
        startRefreshing()
        watch = host.watchRemembering { [weak self] in self?.rememberingChanged() }
        await host.restartReaders(openWindow: true)
        return true
    }

    /// Back to the person's own memory: the window opens on it again if it
    /// was open, remembering goes back to what it was (the pause Demo Memory
    /// made is taken back, and a timed pause of the person's comes back with
    /// its end), and the week is removed. `restoringRemembering` is false
    /// when the person turned remembering on themselves, which is what ended
    /// it.
    public func leave(restoringRemembering: Bool = true) async {
        guard phase == .on else { return }
        // From here every child reads the person's own memory.
        phase = .leaving
        refresher?.cancel()
        refresher = nil
        watch = nil
        await host.restartReaders(openWindow: false)
        if restoringRemembering {
            putBack(wasPaused: wasPaused, pausedUntil: pausedUntil)
        }
        folder.remove()
        phase = .off
    }

    /// A week a run left behind, if the app ended while Demo Memory was in
    /// use: remembering goes back to what it was before, as on Leave, and the
    /// week is removed, so a relaunch is always on the person's own memory.
    /// Called on attach.
    public func finishLeftover() {
        guard phase == .off, switching == nil else { return }
        guard FileManager.default.fileExists(atPath: folder.url.path) else { return }
        if let record = folder.readInUse() {
            putBack(wasPaused: record.wasPaused, pausedUntil: record.pausedUntil)
        }
        folder.remove()
    }

    /// Remembering as it was before Demo Memory: on again if it was on, a
    /// pause until the person resumes left as it is, and a timed pause put
    /// back with its end, or over, as it would have been, if the end came
    /// while the week was in use.
    private func putBack(wasPaused: Bool, pausedUntil: Date?) {
        guard wasPaused else {
            host.resumeRemembering()
            return
        }
        guard let pausedUntil else { return }
        if pausedUntil > now() {
            host.pauseRemembering(until: pausedUntil)
        } else {
            host.resumeRemembering()
        }
    }

    /// Remembering changed: if it is starting or running while Demo Memory
    /// is in use, the person turned it on, and Demo Memory ends.
    private func rememberingChanged() {
        guard phase == .on, !host.isQuiet else { return }
        requestLeave(restoringRemembering: false)
    }

    /// Keeps the status the window reads beside the week fresh, so Today's
    /// Now stays live while the week is in use.
    private func startRefreshing() {
        refresher?.cancel()
        let interval = refreshInterval
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.phase == .on else { return }
                try? self.folder.writeCaptureStatus(
                    now: self.now(), moments: self.week.moments, screenshots: self.week.screenshots
                )
            }
        }
    }

    static func message(for error: Error) -> String {
        if case DemoMemoryMakeError.missingTool = error { return DemoCopy.missing }
        return DemoCopy.couldntMake
    }

    #if DEBUG
    /// For pictures: a controller shown in `phase`, which changes nothing.
    public func showForPreview(_ phase: Phase) {
        self.phase = phase
    }
    #endif
}

/// The window's Leave Demo Memory, for its private pipe (SPEC 2.6.4,
/// SPEC-DELTA 6): the menu bar's own Leave, read and carried out here, so the
/// supervisor reaches Demo Memory's store only through its children's
/// environment (`ProcessSupervisorLaunchPlan.sanitizedEnvironment`).
extension ProcessSupervisor {
    /// Demo Memory is in use: the window may ask to leave it.
    var windowMayLeaveDemoMemory: Bool { DemoMemory.controller?.phase == .on }

    /// Leave Demo Memory, as the menu bar's item does. True when it began.
    func leaveDemoMemoryForWindow() -> Bool {
        DemoMemory.controller?.requestLeave() ?? false
    }
}
