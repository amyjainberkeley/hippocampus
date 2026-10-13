// SoloKeyMonitor.swift — feeds modifier changes to SoloKeyDetector and
// opens Ask on a clean tap of the chosen key (Shift twice unless the person
// chose another). Watches `.flagsChanged` only: no typed key ever reaches
// this code. A monitor needs Accessibility; until it is allowed, AskKeyWatch
// keeps the choice and tries again, and ⌃⇧Space works meanwhile.

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
            }
        ),
        defaults: .standard
    )

    private var detector = SoloKeyDetector(key: .off)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTap: (() -> Void)?
    private var accessibilityObserver: NSObjectProtocol?
    private var recheckSoon: DispatchWorkItem?

    /// Listen for `key`, replacing any earlier choice.
    func start(key: SoloKey, onTap: @escaping () -> Void) {
        self.onTap = onTap
        observeAccessibilityChanges()
        watch.start(key: key)
    }

    func stop() {
        watch.stop()
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
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

    private func handle(_ event: NSEvent) {
        let fired = detector.modifiersChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags.rawValue,
            activity: Self.activityCount(),
            atMs: UInt64(max(0, event.timestamp) * 1_000)
        )
        if fired { onTap?() }
    }

    /// How many keys were pressed and buttons clicked since login, as the
    /// system counts them. A count only; no permission is needed for it.
    private static func activityCount() -> UInt64 {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(UInt64(0)) { $0 &+ UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)) }
    }
}
