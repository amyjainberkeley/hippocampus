// WhatsNewModal.swift — post-update "What's new in this version"
// release-notes viewer.
//
// # Presentation
//
// Rendered as a SwiftUI sheet bound to
// `WhatsNewCoordinator.isVisible` in the recall-ui `RootView`.
// Content comes from `WhatsNewCoordinator.currentRelease` (parsed by
// `ChangelogParser` from the bundled Contents/Resources/CHANGELOG.md
// — no network).
//
// # Dismiss triggers
//
// - Esc key → `onKeyPress(.escape)` calls `coord.dismiss()`.
// - "Close" button → `coord.dismiss()`.
// - ⌘W → SwiftUI's default sheet-close binding via keyboardShortcut.
//
// # Design tokens
//
// Every visual constant reads from `MCI.*` (MCIDesignSystem — PR #84).
// No literal colors, spacings, or radii; the modal ratchets with the
// rest of the app when the design tokens shift.

import RecallUIKit
import SwiftUI

struct WhatsNewModal: View {
    @ObservedObject var coord: WhatsNewCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(MCI.Color.border)
            ScrollView {
                if let release = coord.currentRelease {
                    releaseBody(release)
                } else {
                    devBuildFallback
                }
            }
            Divider().background(MCI.Color.border)
            footer
        }
        .frame(width: 560, height: 520)
        .background(MCI.Color.surface)
        .onKeyPress(.escape, phases: .down) { _ in
            coord.dismiss()
            return .handled
        }
        .accessibilityLabel("What's new in this version")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                Text("What's new")
                    .mciFont(.title2)
                    .foregroundStyle(MCI.Color.foreground)
                Text(headerSubtitle)
                    .mciFont(.caption)
                    .foregroundStyle(MCI.Color.foregroundMuted)
            }
            Spacer()
            Button("Close") { coord.dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .buttonStyle(.plain)
                .foregroundStyle(MCI.Color.accent)
                .mciFont(.bodyStrong)
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }

    private var headerSubtitle: String {
        guard let release = coord.currentRelease else {
            return "Dev build"
        }
        if let date = release.date {
            return "Version \(release.version) · \(date)"
        }
        return "Version \(release.version)"
    }

    @ViewBuilder
    private func releaseBody(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.l) {
            if release.isEmpty {
                emptyReleaseNote
            } else {
                ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                    self.section(section: section)
                }
            }
        }
        .padding(MCI.Spacing.l)
    }

    private func section(section: ChangelogRelease.Section) -> some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            Text(section.title.uppercased())
                .mciFont(.footnote)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .tracking(0.5)
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: MCI.Spacing.s) {
                        Text("•")
                            .mciFont(.body)
                            .foregroundStyle(MCI.Color.foregroundMuted)
                        Text(item)
                            .mciFont(.body)
                            .foregroundStyle(MCI.Color.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(MCI.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MCI.Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .strokeBorder(MCI.Color.border, lineWidth: 1)
            )
        }
    }

    private var emptyReleaseNote: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            Text("No entries in this release.")
                .mciFont(.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
        }
    }

    private var devBuildFallback: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.m) {
            Text("You're on a dev build.")
                .mciFont(.bodyStrong)
                .foregroundStyle(MCI.Color.foreground)
            Text(
                "No release notes are available for this version. The next signed build will show its full CHANGELOG here."
            )
            .mciFont(.body)
            .foregroundStyle(MCI.Color.foregroundSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MCI.Spacing.l)
    }

    private var footer: some View {
        HStack {
            Text("Press ⌘⇧N anytime to reopen this window.")
                .mciFont(.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
            Spacer()
        }
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.m)
    }
}
