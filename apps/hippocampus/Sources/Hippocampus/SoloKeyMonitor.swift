// SoloKeyMonitor.swift — feeds modifier changes to SoloKeyDetector and
// opens Ask on a clean tap of the chosen key (Shift twice unless the person
// chose another). Watches `.flagsChanged` only: no typed key ever reaches
// this code, Fn's tap included. A monitor needs Accessibility; until it is
// allowed, AskKeyWatch keeps the choice and tries again, and ⌃⇧Space works
// meanwhile.
//
// Fn (Globe) listens only after its checks (`FnKeyMonitor`): what apps are
// installed, macOS's Globe key setting and whether a keyboard has Fn. The
// app list is read at most once a minute; nothing here opens a keyboard for
// input, so no Input Monitoring prompt can show. Setup can choose the key
// too: it writes the app's own preference and posts a notice, and the key
// follows it at once.

import AppKit
import ApplicationServices
import Combine
import HippocampusKit

@MainActor
final class SoloKeyMonitor {
    static let shared = SoloKeyMonitor()

    /// What opens Ask right now, for the menu and Preferences. It writes the
    /// effective label and phrase into the app's defaults (RULINGS X2).
    private(set) lazy var watch = AskKeyWatch(
        hooks: AskKeyWatch.Hooks(
            isTrusted: { AXIsProcessTrusted() },
            install: { [weak self] key in self?.install(key) ?? false },
            uninstall: { [weak self] in self?.uninstall() },
            after: { seconds, action in
                let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
                return AnyCancellable { item.cancel() }
            },
            fnCheck: { [weak self] in self?.fnChecks.check() ?? .clear }
        ),
        defaults: .standard
    )

    /// Called when setup chooses the key, so the app's own Preferences
    /// store can take it (`HippocampusApp` sets this).
    var onSetupChoice: (@MainActor (SoloKey) -> Void)?

    private var detector = SoloKeyDetector(key: .off)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTap: (() -> Void)?
    private var accessibilityObserver: NSObjectProtocol?
    private var setupObserver: NSObjectProtocol?
    private var recheckSoon: DispatchWorkItem?
    private let fnChecks = FnKeyChecker(facts: .thisMac)

    /// Listen for `key`, replacing any earlier choice.
    func start(key: SoloKey, onTap: @escaping () -> Void) {
        self.onTap = onTap
        observeAccessibilityChanges()
        followSetupChoice()
        watch.start(key: key)
    }

    func stop() {
        watch.stop()
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        if let setupObserver {
            DistributedNotificationCenter.default().removeObserver(setupObserver)
        }
        accessibilityObserver = nil
        setupObserver = nil
        recheckSoon?.cancel()
        onTap = nil
    }

    /// Look again whether Accessibility is allowed: cheap, so Ask and
    /// Preferences call it when they open.
    func recheck() {
        watch.recheck()
    }

    /// macOS posts this when the Accessibility list changes. The new value
    /// can lag the notice, so look now and again a moment later.
    private func observeAccessibilityChanges() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watch.recheck()
                self.recheckSoon?.cancel()
                let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.watch.recheck() } }
                self.recheckSoon = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            }
        }
    }

    /// Setup's key picker wrote the person's choice to this app's own
    /// preference and posted a notice carrying nothing: read the key again
    /// and listen for it. Only a key Preferences offers is taken.
    private func followSetupChoice() {
        guard setupObserver == nil else { return }
        setupObserver = DistributedNotificationCenter.default().addObserver(
            forName: FnKeyMonitor.setupChoseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stored = UserDefaults.standard.string(forKey: FnKeyMonitor.preferenceKey)
                let key = stored.flatMap(SoloKey.init(rawValue:)) ?? .shiftTwice
                self.fnChecks.forget()
                self.watch.setupChose(key)
                self.onSetupChoice?(key)
            }
        }
    }

    private func install(_ key: SoloKey) -> Bool {
        uninstall()
        detector = SoloKeyDetector(key: key)
        // AppKit calls monitor handlers on the main thread; handling in place
        // keeps key-down and key-up in order.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // While Ask itself has the keyboard, the same tap closes it.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        guard globalMonitor != nil else {
            uninstall()
            return false
        }
        return true
    }

    private func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// A modifier changed: its key code and the modifier bits held, nothing
    /// else. A `.flagsChanged` event carries no typed character.
    private func handle(_ event: NSEvent) {
        // Fn went down while Shift twice stands in for it: a keyboard here
        // has Fn after all.
        if watch.key == .fn, watch.listeningKey != .fn, FnKeyMonitor.keyCodes.contains(event.keyCode),
           event.modifierFlags.rawValue & FnKeyMonitor.functionMask != 0 {
            watch.noticedFnKey()
        }
        let fired = detector.modifiersChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags.rawValue,
            activity: Self.activityCount(),
            atMs: UInt64(max(0, event.timestamp) * 1_000)
        )
        if fired { onTap?() }
    }

    /// How many keys were pressed, buttons clicked, scrolls made and
    /// function keys' own actions sent since login, as the system counts
    /// them (`SoloKeyDetector.activityEventTypes`). A count only, never
    /// which key; no permission is needed for it.
    private static func activityCount() -> UInt64 {
        SoloKeyDetector.activityEventTypes.compactMap(CGEventType.init(rawValue:))
            .reduce(UInt64(0)) { $0 &+ UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)) }
    }
}
