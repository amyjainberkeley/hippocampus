// PrimaryHotkeySlide.swift — cycle 8.48, Raycast/Cotypist peer-study
// P0 pattern #1 "Progressive-disclosure onboarding with a single
// primary-hotkey moment."
//
// Placement: immediately after `PermissionsSlide`. Accessibility TCC
// is already granted at this point, but we DON'T need it — the slide
// listens for ⌃⇧Space via `NSEvent.addLocalMonitorForEvents`, which
// only sees events routed to the onboarding app itself (i.e. while
// the onboarding window is frontmost). That's the exact scope we
// want for a live-try:
//
//   - This is local practice, not proof that the parent application's
//     GlobalHotkeyManager successfully registered the chord.
//   - No new TCC prompt fires.
//   - No Carbon RegisterEventHotKey / process-wide side-effects to
//     clean up if the user quits mid-slide.
//
// The Skip button is REQUIRED: another app can own the chord at the OS
// level, so onboarding must not depend on successful registration.

import SwiftUI
import AppKit
import OnboardingKit

struct PrimaryHotkeySlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var monitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SlideContainer {
            VStack(spacing: 28) {
                VStack(spacing: OnboardingDesign.Space.sm) {
                    OnboardingDesign.TypeRamp.hero("Recall anything, from anywhere.")
                        .multilineTextAlignment(.center)
                    OnboardingDesign.TypeRamp.body("Try it now — press ⌃⇧Space.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                keyboardVisual

                if flowVM.hotkeyPracticed {
                    successBadge
                } else if flowVM.hotkeySkipped {
                    Label("Skipped. You can open Recall from the menu bar.", systemImage: "menubar.arrow.up.rectangle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Press the combo while this window is focused. We'll unlock Continue as soon as we see it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)

                    Button("Skip — the combo is already taken on my Mac") {
                        flowVM.skipHotkeyPractice()
                    }
                    .onboardingText()
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
            keyCap("⌃", label: "Control")
            plus
            keyCap("⇧", label: "Shift")
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
                    RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control)
                        .fill(highlighted
                            ? OnboardingDesign.Palette.accent.opacity(0.18)
                            : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control)
                        .stroke(highlighted
                            ? OnboardingDesign.Palette.accent
                            : Color.secondary.opacity(0.35),
                            lineWidth: highlighted ? 1.5 : 1)
                )
                .animation(
                    OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.quick, reduceMotion: reduceMotion),
                    value: highlighted
                )
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
                .foregroundStyle(OnboardingDesign.Palette.accent)
                .font(.system(size: 18))
            Text("Shortcut detected here. Try it from another app after setup.")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            OnboardingDesign.Palette.accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control)
        )
        .transition(
            reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
        )
    }

    // MARK: - Hotkey monitor

    /// Install an `NSEvent` local monitor scoped to this slide. Fires
    /// when the user presses ⌃⇧Space while the onboarding window is
    /// key. Returning `nil` from the handler swallows the event so
    /// the space char doesn't leak into any focused text field.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // keyCode 49 == kVK_Space. Match ⌃⇧Space exactly.
            // Reject extra Command/Option modifiers so Whisper's chord
            // cannot count as practicing Recall.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wantsControlShift: NSEvent.ModifierFlags = [.control, .shift]
            if event.keyCode == 49 && flags == wantsControlShift {
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
