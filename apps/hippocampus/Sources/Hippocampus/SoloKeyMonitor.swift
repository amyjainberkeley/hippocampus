// SoloKeyMonitor.swift — feeds modifier changes to SoloKeyDetector and
// opens Ask on a clean tap. Watches `.flagsChanged` only: no typed key ever
// reaches this code. Needs the Accessibility grant onboarding already asks
// for; without it nothing is installed and ⌃⇧Space remains.

import AppKit
import ApplicationServices
import HippocampusKit

@MainActor
final class SoloKeyMonitor {
    static let shared = SoloKeyMonitor()

    private var detector = SoloKeyDetector(key: .off)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTap: (() -> Void)?

    /// Start watching for `key`, replacing any earlier choice. Returns false
    /// when the key is off or Accessibility is not granted.
    @discardableResult
    func start(key: SoloKey, onTap: @escaping () -> Void) -> Bool {
        stop()
        guard key != .off, AXIsProcessTrusted() else { return false }
        detector = SoloKeyDetector(key: key)
        self.onTap = onTap
        // AppKit calls monitor handlers on the main thread; handling in place
        // keeps key-down and key-up in order.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // While the bar itself has the keyboard, the same tap closes it.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        return true
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onTap = nil
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
