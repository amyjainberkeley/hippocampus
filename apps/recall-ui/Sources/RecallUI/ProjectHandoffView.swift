import AppKit
import RecallUIKit
import SwiftUI

struct ProjectHandoffView: View {
    @StateObject private var model = ProjectHandoffModel()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var refreshRevision = 0

    private struct Request: Hashable {
        let project: URL?
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick up where you left off").font(.title2.weight(.semibold))
                    Text("Your last decisions, next steps, and their sources.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close project handoff")
            }.padding(24)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project?.lastPathComponent ?? "Choose a project").font(.headline)
                    Text(model.project?.path ?? "Select the project you want to continue.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(model.project == nil ? "Choose folder…" : "Change…") { chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            Text("For Git projects, context uses the whole repository, including related worktrees. It can include screen observations from the same work session. Review the sources before copying.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            Group {
                if model.isLoading {
                    ProgressView("Preparing local context…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errorMessage {
                    VStack(spacing: 14) {
                        ContentUnavailableView("Context unavailable", systemImage: "exclamationmark.circle", description: Text(error))
                        Button("Try again") { refreshRevision += 1 }
                    }.padding(24)
                } else if let packet = model.packet {
                    ScrollView {
                        // Literal selectable source text: no clickable links or embedded instructions.
                        Text(verbatim: packet).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }
                } else {
                    ContentUnavailableView("Continue a project", systemImage: "arrow.turn.down.right",
                        description: Text("Choose the folder you worked in. Hippocampus prepares a short handoff from saved sessions and evidence so you can review it before sharing."))
                        .padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing is sent to an AI tool here.").font(.caption)
                    if let date = model.preparedAt {
                        Text("Prepared \(date, style: .time). Check source dates for freshness.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh") { copied = false; refreshRevision += 1 }
                    .disabled(model.project == nil || model.isLoading)
                Button(copied ? "Copied" : "Copy handoff") {
                    guard let packet = model.packet else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(packet, forType: .string)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.packet == nil || model.isLoading)
            }.padding(20)
        }
        .frame(width: 680, height: 560)
        .task(id: Request(project: model.project, revision: refreshRevision)) { await model.refresh() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for your handoff"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        copied = false
        model.selectProject(directory)
    }
}
