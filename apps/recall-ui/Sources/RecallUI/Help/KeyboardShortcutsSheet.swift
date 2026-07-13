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
struct KeyboardShortcutsSheet: View {
    @ObservedObject var registry: ActionPanelRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(MCI.Color.border)
            ScrollView {
                VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                    ForEach(groupedCommands, id: \.category) { group in
                        section(category: group.category, commands: group.commands)
                    }
                }
                .padding(MCI.Spacing.l)
            }
            Divider().background(MCI.Color.border)
            footer
        }
        .frame(width: 560, height: 520)
        .background(MCI.Color.surface)
        .onKeyPress(.escape, phases: .down) { _ in
            registry.hideHelp()
            return .handled
        }
        .accessibilityLabel("Keyboard shortcuts help")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                Text("Keyboard Shortcuts")
                    .mciFont(.title2)
                    .foregroundStyle(MCI.Color.foreground)
                Text("\(registry.commands.count) commands available")
                    .mciFont(.caption)
                    .foregroundStyle(MCI.Color.foregroundMuted)
            }
            Spacer()
            Button("Close") { registry.hideHelp() }
                .keyboardShortcut("w", modifiers: .command)
                .buttonStyle(.plain)
                .foregroundStyle(MCI.Color.accent)
                .mciFont(.bodyStrong)
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }

    private func section(
        category: ActionPanelCommand.Category,
        commands: [ActionPanelCommand]
    ) -> some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            Text(category.rawValue.uppercased())
                .mciFont(.footnote)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .tracking(0.5)
            VStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                    row(cmd: cmd)
                    if idx < commands.count - 1 {
                        Divider().background(MCI.Color.border.opacity(0.5))
                    }
                }
            }
            .background(MCI.Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .strokeBorder(MCI.Color.border, lineWidth: 1)
            )
        }
    }

    private func row(cmd: ActionPanelCommand) -> some View {
        HStack(spacing: MCI.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.title)
                    .mciFont(.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
                Text(cmd.description.isEmpty ? "—" : cmd.description)
                    .mciFont(.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(cmd.shortcut.isEmpty ? "—" : cmd.shortcut)
                .font(MCI.Font.mono)
                .foregroundStyle(MCI.Color.foregroundMuted)
                .padding(.horizontal, MCI.Spacing.s)
                .padding(.vertical, 2)
                .background(MCI.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.xs))
        }
        .padding(.horizontal, MCI.Spacing.m)
        .padding(.vertical, MCI.Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cmd.title), \(cmd.description), shortcut \(cmd.shortcut.isEmpty ? "none" : cmd.shortcut)")
    }

    private var footer: some View {
        HStack {
            Text("Press ⇧⌘Space anywhere to open recall from any app.")
                .mciFont(.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
            Spacer()
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }

    // MARK: - Grouping

    /// Grouped-by-category snapshot of the live registry. Delegates to
    /// `ActionPanelRegistry.groupedByCategory()` (the Single Source of
    /// Truth) so headless tests can pin ordering without importing SwiftUI.
    private var groupedCommands: [(category: ActionPanelCommand.Category, commands: [ActionPanelCommand])] {
        registry.groupedByCategory()
    }
}
