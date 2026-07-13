// GlobalRecallPopupPanel.swift — the NSPanel that hosts the Spotlight-
// like recall popup. NSPanel (not NSWindow) is required for the
// borderless / always-on-top / non-activating behavior — no SwiftUI
// `Scene` combination achieves this on macOS 14.
//
// # Lifecycle
//
// One `GlobalRecallPopupController` singleton owns the panel and the
// view model. `toggle()` shows or hides the panel; `show()` /
// `hide()` are idempotent. The panel is created lazily on first
// `show()` so a launch that never triggers the hotkey pays zero
// AppKit cost.
//
// # Dismiss triggers
//
// - Esc key           → SwiftUI `.onKeyPress(.escape)` in
//                       GlobalRecallPopupView calls `onDismiss`.
// - Click-outside     → NSPanel's `resignKey` notification bridged
//                       via `panelDidResignKey`.
// - Repeat hotkey     → GlobalHotkeyManager's fire callback calls
//                       `toggle()`.
// - Result invoked    → `onInvoke` calls `hide()` before dispatch.
//
// The panel does NOT dismiss on `resignMain` — Cotypist's peer-app
// study §5 showed that ties the popup to activation policy and
// causes flicker when a background helper triggers the toggle.

import AppKit
import RecallUIKit
import SwiftUI

/// Singleton controller owning the panel + view model. Access via
/// `.shared`; the app calls `.toggle()` from the hotkey callback.
@MainActor
final class GlobalRecallPopupController: NSObject, NSWindowDelegate {
    static let shared = GlobalRecallPopupController()

    private var panel: FloatingPanel?
    private var viewModel: GlobalRecallPopupViewModel?
    /// Injected on first `show()` so we can lazily bind the reader
    /// without holding a strong ref before the MCIRecallApp startup
    /// completes.
    private var reader: BrainReader?

    private override init() {}

    /// Called from `MCIRecallApp` at launch to hand us the reader.
    func configure(reader: BrainReader) {
        self.reader = reader
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let reader else {
            // Configure hasn't happened yet — no reader, no popup.
            // Log via stderr; this is a programmer error, not a
            // user-facing failure.
            NSSound.beep()
            return
        }
        let vm = viewModel ?? GlobalRecallPopupViewModel(reader: reader)
        vm.reset()
        viewModel = vm

        let panel = self.panel ?? makePanel(viewModel: vm)
        self.panel = panel
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        viewModel?.reset()
    }

    private func makePanel(viewModel: GlobalRecallPopupViewModel) -> FloatingPanel {
        let panel = FloatingPanel()
        let hosting = NSHostingController(
            rootView: GlobalRecallPopupView(
                viewModel: viewModel,
                onInvoke: { [weak self] action in
                    self?.dispatch(action)
                },
                onDismiss: { [weak self] in
                    self?.hide()
                }
            )
        )
        panel.contentViewController = hosting
        panel.delegate = self
        return panel
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = NSSize(width: 640, height: 480)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            // Placed ~⅓ down from the top like Spotlight, not center.
            y: frame.maxY - size.height - (frame.height * 0.25)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func dispatch(_ action: PopupHitAction) {
        hide()
        switch action {
        case .openExternal(let url):
            NSWorkspace.shared.open(url)
        case .openInRecallUI(let eventId):
            // Route through the hippocampus:// URL scheme so the
            // main recall UI tab / DetailPane focus is centralized
            // (same pattern as BriefNotificationController).
            if let url = URL(string: "hippocampus://recall?tab=search&focus=\(eventId)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: NSWindowDelegate — click-outside dismiss

    func windowDidResignKey(_ notification: Notification) {
        // Panel lost focus (user clicked outside). Dismiss.
        hide()
    }
}

/// NSPanel subclass tuned for Spotlight-like behavior:
/// - `canBecomeKey` = true so the text field accepts input.
/// - `nonactivatingPanel` so activating our app doesn't yank focus
///   from the user's frontmost workflow app more than necessary.
/// - Borderless + shadow + high-window-level so it floats above
///   everything (including fullscreen apps via `.stationary`
///   collection behavior).
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
