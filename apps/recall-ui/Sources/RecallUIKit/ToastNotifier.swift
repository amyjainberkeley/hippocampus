// ToastNotifier.swift — reusable, app-wide toast notification system.
//
// Cycle 8.51 PR #74 follow-up: several ⌘K Action Panel commands
// (⌘R Refresh Brain, in particular) were registered without any visible
// feedback when fired. This module ships the missing feedback surface.
//
// # Design
//
// One `@MainActor` singleton owns a lazily-created `NSPanel` (borderless,
// non-activating, floating) that hosts a `SwiftUI` toast card. Callers
// enqueue by string; toasts render one-at-a-time so a rapid burst never
// stacks. Each toast fades in (150ms), holds (2s by default), fades out
// (150ms), then the queue drains. Non-interactive by construction — the
// panel `ignoresMouseEvents`, matching the Cotypist / Raycast baseline.
//
// # Why NSPanel + NSHostingView (not `.sheet` / `.alert`)
//
// A sheet is modal to a window; the recall UI has multiple windows and
// the Global Recall popup runs off its own NSPanel — a sheet would only
// attach to whichever window sent the event. NSPanel with a floating
// level sits above every app window at once (same pattern as
// `GlobalRecallPopupPanel.swift`, PR #79), so a ⌘R fired from the
// popup, the search view, or the timeline all present in the same
// place.
//
// # Position
//
// Bottom-center of the active screen, ~48pt above the dock. Fixed
// 340pt width. Matches macOS system-toast placement (AirDrop finish,
// Volume overlay) — familiar without being a copy.

import AppKit
import Combine
import SwiftUI

/// Public entry point. All state lives on the singleton; call
/// `ToastNotifier.notify("message")` from anywhere on the main actor.
@MainActor
public final class ToastNotifier: ObservableObject {
    public static let shared = ToastNotifier()

    /// The message currently rendered in the toast panel. `nil` means
    /// the panel is hidden.
    @Published public private(set) var currentMessage: String?

    /// Queued messages waiting for their turn. Head is next-to-show.
    private var queue: [Message] = []
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ToastCard>?
    private var dismissTask: Task<Void, Never>?

    /// Test hook — set to a non-nil value in tests to skip the AppKit
    /// panel path entirely (unit-tests run headless and AppKit refuses
    /// to render off-screen NSPanels without a full run loop).
    public var testMode: Bool = false

    public init() {}

    // MARK: - Public API

    /// Enqueue a toast. `hold` controls how long the message stays
    /// on screen before fading out; defaults to 2 seconds. Safe to
    /// call in a tight loop — burst enqueues serialize.
    public func notify(_ text: String, hold: TimeInterval = 2.0) {
        queue.append(Message(text: text, hold: hold))
        pumpIfIdle()
    }

    /// Immediately clear the current toast and drop any queued
    /// messages. Test-only + programmatic-dismiss escape hatch.
    public func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        queue.removeAll()
        currentMessage = nil
        hidePanel()
    }

    // MARK: - Queue pump

    private func pumpIfIdle() {
        guard currentMessage == nil, let next = queue.first else { return }
        queue.removeFirst()
        currentMessage = next.text
        showPanel(text: next.text)
        // Schedule fade-out.
        let hold = next.hold
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishCurrent()
            }
        }
    }

    private func finishCurrent() {
        currentMessage = nil
        hidePanel()
        dismissTask = nil
        // Drain next queued message.
        pumpIfIdle()
    }

    // MARK: - AppKit panel

    private func showPanel(text: String) {
        guard !testMode else { return }
        let card = ToastCard(text: text)
        let panel = self.panel ?? makePanel()
        let hosting: NSHostingView<ToastCard>
        if let existing = hostingView {
            existing.rootView = card
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: card)
            panel.contentView = hosting
            hostingView = hosting
        }
        self.panel = panel
        centerBottom(panel)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private func centerBottom(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = NSSize(width: 340, height: 56)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 48
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Types

    private struct Message {
        let text: String
        let hold: TimeInterval
    }
}

/// SwiftUI card that renders inside the toast NSPanel. Uses
/// `MCIDesignSystem` tokens throughout so the toast reads as part of
/// the same visual language as the ⌘K panel and the Global Recall popup.
private struct ToastCard: View {
    let text: String

    var body: some View {
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MCI.Color.accent)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .mciFont(.body)
                .foregroundStyle(MCI.Color.foreground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
        .frame(width: 340, height: 56, alignment: .leading)
        .background(MCI.Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.l))
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.l)
                .strokeBorder(MCI.Color.border, lineWidth: 1)
        )
        .mciShadow(.modal)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
