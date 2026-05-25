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
        VStack(spacing: 16) {
            Text("Download AI Model")
                .font(.headline)

            Text("Daily briefs summarize your day using an on-device AI model.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label("Download size: ~2.5 GB", systemImage: "arrow.down.circle")
                Label("Runs entirely on your Mac", systemImage: "desktopcomputer")
                Label("No data leaves your device", systemImage: "lock.shield")
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
                    .keyboardShortcut(.defaultAction)
                case .downloading:
                    Button("Cancel Download") {
                        cancelDownload()
                    }
                case .failed:
                    Button("Retry") {
                        startDownload()
                    }
                    .keyboardShortcut(.defaultAction)
                case .verifying:
                    EmptyView()
                case .ready:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
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
