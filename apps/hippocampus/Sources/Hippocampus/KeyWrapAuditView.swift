// SPDX-License-Identifier: TBD-private
import SwiftUI
import AppKit
import HippocampusKit

/// SwiftUI panel for the read-only "Inspect Key Wrap" surface.
///
/// Renders a `KeyWrapAuditReport` and lets the user (a) re-verify the
/// wrap by re-running the inspector and (b) jump to Finder or
/// Keychain Access for an OS-level second opinion. Content-free —
/// the panel never displays key bytes, store contents, or any brain
/// data. (DOGFOOD_V1 #28.)
struct KeyWrapAuditView: View {
    @State private var report: KeyWrapAuditReport
    @State private var lastVerified: Date

    let reverify: () -> KeyWrapAuditReport
    let onClose: () -> Void

    init(
        initialReport: KeyWrapAuditReport,
        reverify: @escaping () -> KeyWrapAuditReport,
        onClose: @escaping () -> Void
    ) {
        self._report = State(initialValue: initialReport)
        self._lastVerified = State(initialValue: initialReport.generatedAt)
        self.reverify = reverify
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if report.severity == .devOnly {
                devOnlyBanner
            }

            metadataGrid

            if !report.notes.isEmpty {
                notesSection
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: severityIcon)
                    .foregroundStyle(severityColor)
                    .font(.title3)
                Text("Key Wrap Audit")
                    .font(.title2.bold())
                Spacer()
                severityBadge
            }

            Text("Content-free — this panel only shows how your brain key is sealed. It never shows the key bytes, your brain contents, or anything captured from your screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var severityBadge: some View {
        Text(severityLabel)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(severityColor.opacity(0.15), in: Capsule())
            .foregroundStyle(severityColor)
    }

    private var devOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("DEV-ONLY WRAP IN USE")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This wrap provides NO at-rest confidentiality. A shipped build should never reach this code path. Please report.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
    }

    private var metadataGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            row("Implementation", report.implementationName)
            row("Sealed on this Mac", report.sealed ? "Yes" : "No")
            row("Access control", report.aclDescription)
            row("Identifier", report.identifier, monospaced: true)
            row("Last verified", verifiedTimestamp)
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(minWidth: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(report.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: runReverify) {
                Label("Re-verify wrap", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("KeyWrapAuditReverifyButton")

            if let revealLabel = revealButtonLabel {
                Button(action: runReveal) {
                    Label(revealLabel, systemImage: revealIcon)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("KeyWrapAuditRevealButton")
            }

            Spacer()

            Button("Done") { onClose() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func runReverify() {
        report = reverify()
        lastVerified = report.generatedAt
    }

    private func runReveal() {
        switch report.reveal {
        case .showInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .showInKeychainAccess:
            let keychain = URL(fileURLWithPath: "/Applications/Utilities/Keychain Access.app")
            NSWorkspace.shared.open(keychain)
        case .none:
            break
        }
    }

    // MARK: - Computed

    private var severityIcon: String {
        switch report.severity {
        case .production: "lock.shield.fill"
        case .interim: "lock.fill"
        case .devOnly: "exclamationmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch report.severity {
        case .production: .green
        case .interim: .blue
        case .devOnly: .red
        }
    }

    private var severityLabel: String {
        switch report.severity {
        case .production: "Production"
        case .interim: "Interim"
        case .devOnly: "DEV ONLY"
        }
    }

    private var revealButtonLabel: String? {
        switch report.reveal {
        case .showInFinder: "Show in Finder"
        case .showInKeychainAccess: "Show me in Keychain Access"
        case .none: nil
        }
    }

    private var revealIcon: String {
        switch report.reveal {
        case .showInFinder: "folder"
        case .showInKeychainAccess: "key.viewfinder"
        case .none: "questionmark"
        }
    }

    private var verifiedTimestamp: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        return fmt.string(from: lastVerified)
    }
}
