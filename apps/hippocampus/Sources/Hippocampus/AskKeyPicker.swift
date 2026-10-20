// SPDX-License-Identifier: Apache-2.0
//
// AskKeyPicker.swift — Preferences' choice of the key that opens Ask, with
// the line that says how that key works on this Mac.

import HippocampusKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// "Open Ask with", in Preferences › General: the key that opens Ask and
/// what it needs, with Open System Settings… while Accessibility is off.
///
/// Fn (Globe) is a choice beside Shift twice (SPEC-DELTA 7). Picked while
/// another app or macOS uses Fn, it says so by name, with the exact step
/// for macOS's own setting and Open Keyboard Settings…, and Shift twice
/// keeps opening Ask until the person clicks Use Fn: Fn is never taken
/// silently. A keyboard without Fn falls back to Shift twice, with a note.
struct AskKeyPicker: View {
    @ObservedObject var store: PreferencesStore
    /// What opens Ask right now: the key's caption follows it.
    @ObservedObject var askKey: AskKeyWatch

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
            Picker("Open Ask with", selection: $store.askKey) {
                ForEach(SoloKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            let caption = AskKeyCaption(
                key: store.askKey,
                accessibilityGranted: askKey.accessibilityGranted,
                fallbackRegistered: askKey.fallbackRegistered,
                fnCheck: store.askKey == .fn ? askKey.currentFnCheck() : nil,
                fnAccepted: askKey.fnAccepted
            )
            if !caption.fnWarnings.isEmpty {
                FnWarnings(warnings: caption.fnWarnings, useFn: { askKey.acceptFn() })
            }
            Text(caption.text)
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let secondLine = caption.secondLine {
                Text(secondLine)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            if caption.needsAccessibility {
                Button("Open System Settings…") {
                    if let url = URL(string: TCCRevokedReason.accessibility.settingsPaneURLString) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        // Accessibility may have been allowed since the key last looked.
        .onAppear { askKey.recheck() }
        // Setup chose the key while the app ran: Preferences takes it.
        .onChange(of: askKey.chosenInSetup, initial: true) { _, chosen in
            guard let chosen else { return }
            if store.askKey != chosen { store.askKey = chosen }
            askKey.adoptedSetupChoice()
        }
        // Back from Keyboard settings: the Globe key may be free now.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            askKey.recheck()
        }
    }
}

/// What else uses Fn, before it is taken: an orange triangle beside each
/// warning, the step for macOS's own setting, then the person's choice.
struct FnWarnings: View {
    let warnings: [FnKeyNote]
    let useFn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.controlSpacing) {
            ForEach(warnings) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.text)
                            .font(PreferencesStyle.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                        if let step = warning.step {
                            Text(step)
                                .font(PreferencesStyle.captionFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: PreferencesStyle.controlSpacing) {
                if warnings.contains(where: { $0.step != nil }) {
                    Button(AskKeyCopy.openKeyboardSettings) {
                        NSWorkspace.shared.open(KeyboardSettingsLink.url)
                    }
                }
                Button(AskKeyCopy.useFn, action: useFn)
            }
            .padding(.leading, 17)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
