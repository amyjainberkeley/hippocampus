// PrimaryHotkeySlide.swift — cycle 8.48, Raycast/Cotypist peer-study
// P0 pattern #1 "Progressive-disclosure onboarding with a single
// primary-hotkey moment."
//
// Placement: immediately after `PermissionsSlide`. Accessibility TCC
// is already granted at this point, but we DON'T need it — the slide
// listens for ⇧⌘Space via `NSEvent.addLocalMonitorForEvents`, which
// only sees events routed to the onboarding app itself (i.e. while
// the onboarding window is frontmost). That's the exact scope we
// want for a live-try:
//
//   - We aren't competing with the real GlobalHotkeyManager (which
//     lives in the Recall UI process, not this onboarding process).
//   - No new TCC prompt fires.
//   - No Carbon RegisterEventHotKey / process-wide side-effects to
//     clean up if the user quits mid-slide.
//
// The Skip button is REQUIRED: some users have Alfred / SetApp /
// Raycast already grabbing ⇧⌘Space at the OS level, and blocking
// onboarding on a hotkey we can't guarantee would be a regression.

import SwiftUI
import AppKit
import OnboardingKit

struct PrimaryHotkeySlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var monitor: Any?

    var body: some View {
        SlideContainer {
            VStack(spacing: 28) {
                OnboardingTheme.title("Recall anything, from anywhere.")
                OnboardingTheme.subtitle("Try it now — press ⇧⌘Space.")

                keyboardVisual

                if flowVM.hotkeyPracticed {
                    successBadge
                } else {
                    Text("Press the combo while this window is focused. We'll unlock Continue as soon as we see it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)

                    Button("Skip — the combo is already taken on my Mac") {
                        // Live-try wasn't possible (Alfred/SetApp
                        // grabbed the combo, or user just wants to
                        // move on). Still flip the flag so Continue
                        // unlocks — accessibility is non-negotiable.
                        flowVM.markHotkeyPracticed()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                }
            }
        }
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    // MARK: - Visuals

    private var keyboardVisual: some View {
        HStack(spacing: 8) {
            keyCap("⇧", label: "Shift")
            plus
            keyCap("⌘", label: "Command")
            plus
            keyCap("Space", label: "Space", wide: true)
        }
        .padding(.vertical, 8)
    }

    private func keyCap(_ glyph: String, label: String, wide: Bool = false) -> some View {
        let highlighted = flowVM.hotkeyPracticed
        return VStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: wide ? 20 : 24, weight: .semibold, design: .rounded))
                .frame(minWidth: wide ? 96 : 56, minHeight: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(highlighted
                            ? OnboardingTheme.accentBlue.opacity(0.18)
                            : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(highlighted
                            ? OnboardingTheme.accentBlue
                            : Color.secondary.opacity(0.35),
                            lineWidth: highlighted ? 1.5 : 1)
                )
                .animation(.easeInOut(duration: 0.2), value: highlighted)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel(label)
    }

    private var plus: some View {
        Text("+")
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 14)
    }

    private var successBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(OnboardingTheme.accentBlue)
                .font(.system(size: 18))
            Text("Nice — you'll use this every day.")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            OnboardingTheme.accentBlue.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Hotkey monitor

    /// Install an `NSEvent` local monitor scoped to this slide. Fires
    /// when the user presses ⇧⌘Space while the onboarding window is
    /// key. Returning `nil` from the handler swallows the event so
    /// the space char doesn't leak into any focused text field.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // keyCode 49 == kVK_Space. Match ⇧⌘Space exactly (ignore
            // Option/Control so a chorded ⌥⇧⌘Space doesn't false-positive).
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wantsCmdShift: NSEvent.ModifierFlags = [.command, .shift]
            if event.keyCode == 49 && flags == wantsCmdShift {
                Task { @MainActor in flowVM.markHotkeyPracticed() }
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
