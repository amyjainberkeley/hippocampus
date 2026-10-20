import AppKit
import OnboardingKit
import SwiftUI

/// Setup's one window on screen (SPEC 7.7): centred on the display with the
/// pointer, as tall as a short screen allows, and joining the Space the
/// person is on, over a full-screen app too, so it never pulls them to
/// another Space. Done fades it out before setup quits (SPEC 7.4).
@MainActor
enum SetupWindow {
    /// The display with the pointer, as `SetupWindowFit` sees displays.
    static func pointerDisplay() -> SetupRect? {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { (frame: rect($0.frame), visible: rect($0.visibleFrame)) }
        return SetupWindowFit.display(pointer: (pointer.x, pointer.y), screens: screens)
    }

    /// The window's height on the pointer's display: 560, or less on a
    /// short screen.
    static func fittedHeight() -> CGFloat {
        guard let visible = pointerDisplay() else { return OnboardingTheme.windowHeight }
        return CGFloat(SetupWindowFit.height(visibleHeight: visible.height))
    }

    /// Once, when the window first exists: where it goes and which Spaces
    /// it may show on.
    static func place(_ window: NSWindow) {
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        guard let visible = pointerDisplay() else { return }
        // The window's own size: SwiftUI sized it to the content.
        let size = window.frame.size
        let origin = SetupWindowFit.origin(width: size.width, height: size.height, in: visible)
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    /// Done: fade out over 200 ms, then quit. The app opens the window on
    /// Today once this process has exited.
    static func fadeOutAndQuit() {
        let windows = NSApp.windows.filter(\.isVisible)
        guard !windows.isEmpty else {
            NSApplication.shared.terminate(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SetupExitMotion.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windows { window.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }

    private static func rect(_ rect: NSRect) -> SetupRect {
        SetupRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

/// Finds the window a view is in, once, and hands it over.
struct SetupWindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var found: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let found else { return }
            self.found = nil
            MainActor.assumeIsolated { found(window) }
        }
    }
}

private struct WindowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = OnboardingTheme.windowHeight
}

extension EnvironmentValues {
    /// The window's height: 560, or less on a short screen (SPEC 7.7).
    var onboardingWindowHeight: CGFloat {
        get { self[WindowHeightKey.self] }
        set { self[WindowHeightKey.self] = newValue }
    }
}
