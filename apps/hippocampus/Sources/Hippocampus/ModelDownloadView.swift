// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct ModelDownloadView: View {
    let modelID: String
    let onDismiss: () -> Void
    let onComplete: () -> Void

    @State private var downloadState: ModelDownloadManager.DownloadState = .notStarted
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var downloadTask: Task<Void, Never>?

    private let manager: ModelDownloadManager

    init(modelID: String = "qwen3-1.7b-fp16",
         manager: ModelDownloadManager? = nil,
         onDismiss: @escaping () -> Void,
         onComplete: @escaping () -> Void) {
        self.modelID = modelID
        self.onDismiss = onDismiss
        self.onComplete = onComplete
        self.manager = manager ?? ModelDownloadManager()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Briefs")
                        .font(.title3.weight(.semibold))
                    Text("On-device model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Download the local model that turns your captured day into a private brief.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label("About 2.5 GB", systemImage: "arrow.down.circle")
                Label("Runs entirely on your Mac", systemImage: "desktopcomputer")
                Label("Brief generation does not upload your memory", systemImage: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            switch downloadState {
            case .notStarted:
                EmptyView()
            case .downloading:
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .verifying:
                ProgressView()
                    .controlSize(.small)
                Text("Verifying integrity…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                if let msg = errorMessage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Button("Cancel") {
                    cancelAndDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                switch downloadState {
                case .notStarted:
                    Button("Download") {
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .downloading:
                    Button("Cancel Download") {
                        cancelDownload()
                    }
                case .failed:
                    Button("Retry") {
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .verifying:
                    EmptyView()
                case .ready:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.light)
    }

    private func startDownload() {
        errorMessage = nil
        downloadState = .downloading(progress: 0)
        progress = 0

        downloadTask = Task {
            do {
                try await manager.downloadModel(modelID: modelID) { p in
                    Task { @MainActor in
                        progress = p
                        downloadState = .downloading(progress: p)
                    }
                }
                downloadState = .ready
                UserDefaults.standard.set(true, forKey: "MCIBriefsEnabled")
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
            } catch is CancellationError {
                downloadState = .notStarted
            } catch {
                errorMessage = error.localizedDescription
                downloadState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        Task { await manager.cancelDownload(modelID: modelID) }
        downloadState = .notStarted
    }

    private func cancelAndDismiss() {
        cancelDownload()
        onDismiss()
    }
}
