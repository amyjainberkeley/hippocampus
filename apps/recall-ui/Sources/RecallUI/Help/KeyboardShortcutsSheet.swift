// KeyboardShortcutsSheet.swift — the ⌘/ help sheet.
//
// Cycle 8.51 PR #74 follow-up: PR #74 registered a "Show Help /
// Keyboard Shortcuts" command in the ⌘K Action Panel but firing it
// only fired a `hippocampus://help` URL that nothing handles. This
// sheet ships the actual UI.
//
// # Single Source of Truth
//
// Content is enumerated from `ActionPanelRegistry.shared.commands` —
// never hardcoded. When a new command is registered anywhere in the
// app the sheet picks it up on the next present. Rows are grouped by
// `ActionPanelCommand.Category` (Search / Hit / App / Debug) so the
// user's mental model matches the ⌘K palette's own labeling.
//
// # Dismiss triggers
//
// - Esc key           → `.onKeyPress(.escape)` calls `registry.hideHelp()`.
// - Click "Close"     → the button binding.
// - ⌘W                → SwiftUI's default sheet close binding via keyboardShortcut.
// - Click outside     → SwiftUI sheets auto-dismiss on background tap.

import RecallUIKit
import SwiftUI

/// Standalone sheet content. Presented via
/// `RootView`'s `.sheet(isPresented: $registry.isHelpVisible)` binding.
///
/// Every key the window knows (`WindowKeys`, SPEC 2.10 with SPEC-DELTA 1:
/// ⌘1 Today to ⌘9 AI Tools), under the ⌘K groups' headings: Go To,
/// Moments, Actions and Help.
struct KeyboardShortcutsSheet: View {
    @ObservedObject var registry: ActionPanelRegistry
    /// Where the list opens: the top, or (for a picture of the last
    /// groups) the bottom.
    var opensAt: UnitPoint = .top

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(MCI.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                    ForEach(WindowKeys.grouped, id: \.group) { section in
                        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
                            Text(section.group.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MCI.Color.foreground)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.keys) { key in
                                row(key)
                            }
                        }
                    }
                }
                .padding(MCI.Spacing.l)
            }
            .defaultScrollAnchor(opensAt)
            Divider().background(MCI.Color.border)
            footer
        }
        .frame(width: 620, height: 560)
        .background(MCI.Color.surface)
        .onKeyPress(.escape, phases: .down) { _ in
            registry.hideHelp()
            return .handled
        }
        .accessibilityLabel(UserFacingCopy.shortcutsSheetLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(UserFacingCopy.commandShortcuts)
                .mciFont(.title2)
                .foregroundStyle(MCI.Color.foreground)
            Spacer()
            Button(UserFacingCopy.closeAction) { registry.hideHelp() }
                .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }

    private func row(_ key: WindowKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(key.keys.enumerated()), id: \.offset) { index, chip in
                    if key.isRange, index > 0 {
                        Text(verbatim: "\u{2013}")
                            .font(.system(size: 12))
                            .foregroundStyle(MCI.Color.foregroundMuted)
                    }
                    KeyChip(text: chip)
                }
            }
            .frame(width: 150, alignment: .leading)
            Text(verbatim: key.does)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key.does), \(key.keys.joined(separator: key.isRange ? " to " : " and "))")
    }

    private var footer: some View {
        HStack {
            Text(UserFacingCopy.askKeyHelp(AskShortcutLabel.current().phrase))
                .mciFont(.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
            Spacer()
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }
}

/// A key, drawn as a small chip.
private struct KeyChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(MCI.Color.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MCI.Color.hover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(MCI.Color.border, lineWidth: 0.5)
            )
    }
}
