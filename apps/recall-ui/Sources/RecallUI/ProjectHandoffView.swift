import AppKit
import RecallUIKit
import SwiftUI

struct ProjectHandoffView: View {
    @StateObject private var model: ProjectHandoffModel
    @Environment(\.dismiss) private var dismiss
    /// The synthetic preview never runs Hippocampus on a real folder.
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview
    @State private var copied = false
    @State private var refreshRevision = 0

    /// `folder`: where the sheet starts, a Working On item's folder (SPEC
    /// 3.2). Nil starts it empty, as ⌘J does.
    init(startingIn folder: URL? = nil) {
        _model = StateObject(wrappedValue: ProjectHandoffModel(startingIn: folder))
    }

    /// The sheet for a Working On item: in its folder when its guess names a
    /// folder on this Mac.
    init(folderGuess: String?) {
        self.init(startingIn: ProjectHandoffModel.startingFolder(folderGuess))
    }

    private struct Request: Hashable {
        let project: URL?
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(UserFacingCopy.folderTitle).font(.title2.weight(.semibold))
                    Text(UserFacingCopy.folderSubtitle)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(UserFacingCopy.closeAction)
            }.padding(24)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project?.lastPathComponent ?? UserFacingCopy.folderChoose).font(.headline)
                    if let path = model.project?.path {
                        Text(verbatim: path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button(model.project == nil ? UserFacingCopy.folderChooseAction : UserFacingCopy.folderChangeAction) { chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(isSyntheticPreview)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            Text(UserFacingCopy.folderScope)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            Group {
                if model.isLoading {
                    ProgressView(UserFacingCopy.folderLoading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errorMessage {
                    VStack(spacing: 14) {
                        ContentUnavailableView(UserFacingCopy.folderFailed, systemImage: "exclamationmark.circle", description: Text(error))
                        Button(UserFacingCopy.tryAgainAction) { refreshRevision += 1 }
                    }.padding(24)
                } else if let packet = model.packet {
                    ScrollView {
                        // Literal selectable source text: no clickable links or embedded instructions.
                        Text(verbatim: packet).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }
                } else {
                    ContentUnavailableView(UserFacingCopy.folderEmptyTitle, systemImage: "arrow.turn.down.right",
                        description: Text(UserFacingCopy.folderEmptyBody))
                        .padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UserFacingCopy.folderNothingSent).font(.caption)
                    if let date = model.preparedAt {
                        Text(UserFacingCopy.folderWrittenAt(date.formatted(date: .omitted, time: .shortened)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh") { copied = false; refreshRevision += 1 }
                    .disabled(model.project == nil || model.isLoading)
                Button(copied ? UserFacingCopy.copiedToast : UserFacingCopy.folderCopy) {
                    guard let packet = model.packet else { return }
                    // For an AI tool: this Mac only, out of clipboard
                    // history, cleared after 2 minutes (SPEC 5.3.6).
                    copied = ClipboardHygiene.copy(packet)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.packet == nil || model.isLoading)
            }.padding(20)
        }
        .frame(width: 680, height: 560)
        .task(id: Request(project: model.project, revision: refreshRevision)) {
            guard !isSyntheticPreview else { return }
            await model.refresh()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = UserFacingCopy.folderPanelTitle
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        copied = false
        model.selectProject(directory)
    }
}

/// Context for This Folder… from a Working On item, its page's ⋯ or its row
/// in the sidebar: the sheet, in the item's folder when there is one.
struct FolderSheet: Identifiable {
    let id = UUID()
    /// The item's folder guess ("~/dev/trailhead-shop").
    let guess: String?
}
