// SPDX-License-Identifier: TBD-private
import SwiftUI
import AppKit
import HippocampusKit

/// SwiftUI panel for the read-only "Inspect Key Wrap" surface.
///
/// Renders a `KeyWrapAuditReport` and lets the user (a) check
/// readability again and (b) jump to Keychain Access
/// for an OS-level second opinion. Content-free —
/// the panel never displays key bytes, store contents, or any brain
/// data. (DOGFOOD_V1 #28.)
struct KeyWrapAuditView: View {
    @StateObject private var model: KeyWrapAuditViewModel

    let onClose: () -> Void

    init(
        store: KeychainKeyStore,
        onClose: @escaping () -> Void
    ) {
        self._model = StateObject(wrappedValue: KeyWrapAuditViewModel(store: store))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            switch model.state {
            case .loading:
                loadingState
            case .failed(let message):
                errorState(message)
            case .loaded(let report):
                if report.severity == .devOnly {
                    devOnlyBanner
                }
                metadataGrid(report)
                if !report.notes.isEmpty {
                    notesSection(report)
                }
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.refresh() }
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

            Text("Content-free - this panel checks whether Hippocampus can read the brain key. Access-control inspection is reported separately and never inferred from a successful read.")
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

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking Keychain readability...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Audit failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    }

    private func metadataGrid(_ report: KeyWrapAuditReport) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            row("Implementation", report.implementationName)
            row("Key readability", report.keyReadable ? "Readable" : "Unavailable")
            row("Access control", report.accessControlDescription)
            row("Identifier", report.identifier, monospaced: true)
            row("Last read attempt", verifiedTimestamp(report.generatedAt))
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

    private func notesSection(_ report: KeyWrapAuditReport) -> some View {
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
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Check readability again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("KeyWrapAuditReverifyButton")
            .disabled(model.state == .loading)

            if let report = loadedReport,
               let revealLabel = revealButtonLabel(report) {
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

    private func runReveal() {
        guard let report = loadedReport else { return }
        switch report.reveal {
        case .showInKeychainAccess:
            let keychain = URL(fileURLWithPath: "/Applications/Utilities/Keychain Access.app")
            NSWorkspace.shared.open(keychain)
        case .none:
            break
        }
    }

    // MARK: - Computed

    private var severityIcon: String {
        switch model.state {
        case .loading: "arrow.clockwise"
        case .failed: "exclamationmark.triangle.fill"
        case .loaded(let report):
            switch report.severity {
            case .production: "key.fill"
            case .devOnly: "exclamationmark.octagon.fill"
            }
        }
    }

    private var severityColor: Color {
        switch model.state {
        case .loading: .secondary
        case .failed: .red
        case .loaded(let report):
            switch report.severity {
            case .production: .blue
            case .devOnly: .red
            }
        }
    }

    private var severityLabel: String {
        switch model.state {
        case .loading: "Checking"
        case .failed: "Error"
        case .loaded(let report):
            switch report.severity {
            case .production: "File Keychain"
            case .devOnly: "DEV ONLY"
            }
        }
    }

    private func revealButtonLabel(_ report: KeyWrapAuditReport) -> String? {
        switch report.reveal {
        case .showInKeychainAccess: "Show me in Keychain Access"
        case .none: nil
        }
    }

    private var revealIcon: String {
        "key.viewfinder"
    }

    private func verifiedTimestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        return fmt.string(from: date)
    }

    private var loadedReport: KeyWrapAuditReport? {
        guard case .loaded(let report) = model.state else { return nil }
        return report
    }
}
