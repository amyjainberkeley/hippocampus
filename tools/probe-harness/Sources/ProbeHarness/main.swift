// SPDX-License-Identifier: TBD-private
//
// MCI probe-harness — STEP-2-FINDING-001 isolation surface.
//
// One `NSWindow`, one `NSSecureTextField`. **No** explicit call to
// `EnableSecureEventInput()` anywhere in this binary — that's the
// whole point. See `README.md` for the full rationale, especially the
// note about NSSecureTextField's own internal Carbon behavior on
// macOS 26 (which the harness uses to triage suspect-#5 cascade
// short-circuit vs. suspect-#1 SwiftUI/Catalyst AX-bridge regression).
//
// This is dev-tooling, not shipping code. Built locally via
// `swift build` from `tools/probe-harness/`; not signed, not
// notarized, not distributed.

import AppKit

final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 180)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MCI Probe Harness — STEP-2-FINDING-001 §4 isolation"
        window.center()

        guard let contentView = window.contentView else { return }

        let label = NSTextField(labelWithString:
            "Click the secure field below. The MCI helper running with "
            + "`--capture --probe-debug` should log one stderr line per "
            + "frame with subrole=AXSecureTextField. See README.")
        label.frame = NSRect(x: 16, y: 96, width: 388, height: 60)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        contentView.addSubview(label)

        let secureField = NSSecureTextField(
            frame: NSRect(x: 16, y: 48, width: 388, height: 28))
        secureField.placeholderString =
            "secure field — focus here (no EnableSecureEventInput call in this binary)"
        // Identifier helps disambiguate this widget in --probe-debug
        // stderr lines from any other focused element on the host.
        secureField.setAccessibilityIdentifier("mci-probe-harness-secure-field")
        contentView.addSubview(secureField)

        let plainField = NSTextField(
            frame: NSRect(x: 16, y: 12, width: 388, height: 28))
        plainField.placeholderString =
            "plain text field — focus here to compare (subrole should be absent or non-secure)"
        plainField.setAccessibilityIdentifier("mci-probe-harness-plain-field")
        contentView.addSubview(plainField)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(secureField)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { true }
}

let app = NSApplication.shared
let delegate = HarnessAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
