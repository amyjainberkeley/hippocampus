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
/// Fn (Globe) joins the choices here and in setup's picker, with its checks
/// before it is chosen (SPEC-DELTA 7, `FnKeyMonitor`).
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
                fallbackRegistered: askKey.fallbackRegistered
            )
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
    }
}
