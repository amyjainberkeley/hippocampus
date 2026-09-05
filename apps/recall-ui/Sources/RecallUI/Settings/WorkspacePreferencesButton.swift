import AppKit
import RecallUIKit
import SwiftUI

struct WorkspacePreferencesButton: View {
    let title: String
    let systemImage: String
    let destination: WorkspacePreferencesDestination
    @State private var openFailed = false
    @State private var opening = false

    var body: some View {
        Button {
            opening = true
            Task { @MainActor in
                openFailed = !(await WorkspacePreferencesRouter.shared.open(
                    destination, bundleURL: Bundle.main.bundleURL))
                opening = false
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(opening)
        .alert("Preferences could not open", isPresented: $openFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open the installed Hippocampus app and try again.")
        }
    }
}

struct WorkspaceSettingsView: View {
    @State private var customNamesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsRow("General", detail: "Startup and default view", image: "gearshape", destination: .general)
                Divider()
                settingsRow("Screen capture", detail: "Capture state and app access", image: "display", destination: .capture)
                Divider()
                settingsRow("AI context", detail: "Claude Code and Codex", image: "point.3.connected.trianglepath.dotted", destination: .sources)
                Divider()
                settingsRow("Privacy", detail: "Exclusions and retention", image: "hand.raised", destination: .privacy)
                Divider()
                DisclosureGroup("Custom names", isExpanded: $customNamesExpanded) {
                    UserDictionaryEditor().frame(height: 340)
                }
                Divider()
                HStack {
                    WorkspacePreferencesButton(title: "Advanced", systemImage: "slider.horizontal.3", destination: .advanced)
                    Spacer()
                    WorkspacePreferencesButton(title: "About Hippocampus", systemImage: "info.circle", destination: .about)
                }
                .buttonStyle(.borderless)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsRow(_ title: String, detail: String, image: String,
                             destination: WorkspacePreferencesDestination) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            WorkspacePreferencesButton(title: title, systemImage: image, destination: destination)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Open \(title)")
                .font(.title3)
                .frame(width: 32, height: 32)
        }
    }
}
