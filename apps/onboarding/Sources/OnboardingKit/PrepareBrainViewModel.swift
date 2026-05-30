import Foundation

@MainActor
public final class PrepareBrainViewModel: ObservableObject {
    public enum KeyState: Sendable, Equatable {
        case checking
        case generating
        case ready
        case failed(String)
    }

    @Published public private(set) var keyState: KeyState = .checking
    @Published public private(set) var downloadState: ModelDownloadState = .notStarted
    @Published public private(set) var downloadProgress: Double = 0

    private let keyGenerator: any KeyGenerator
    private let modelDownloader: any ModelDownloader
    private var downloadTask: Task<Void, Never>?

    public init(keyGenerator: any KeyGenerator, modelDownloader: any ModelDownloader) {
        self.keyGenerator = keyGenerator
        self.modelDownloader = modelDownloader
    }

    public var modelDownloaded: Bool {
        downloadState == .ready
    }

    public var modelDisplayName: String {
        modelDownloader.displayName
    }

    public var modelSizeDescription: String {
        modelDownloader.sizeDescription
    }

    public func generateKey() async {
        keyState = .generating
        try? await Task.sleep(for: .milliseconds(600))
        do {
            let exists = await keyGenerator.keyExists()
            if !exists {
                try await keyGenerator.generateKey()
            }
            keyState = .ready
        } catch {
            keyState = .failed(error.localizedDescription)
        }
    }

    /// Re-probe the on-disk truth of "is the model installed?". Called
    /// on slide-appear (`.task` in PrepareBrainSlide) so the slide
    /// reflects the filesystem, not stale in-memory state. Mirrors the
    /// RealBrowserDetector pattern used by the browser-extension slide.
    ///
    /// Only mutates state from the "no in-flight user intent" buckets
    /// (`.notStarted` and `.ready`). An active download, a user skip,
    /// or a surfaced failure all reflect intent the user gave on THIS
    /// session — we don't overwrite that just because the FS probe
    /// disagrees right now.
    public func checkModelAvailability() async {
        let available = await modelDownloader.isAvailable()
        switch downloadState {
        case .notStarted:
            if available { downloadState = .ready }
        case .ready:
            // Catch: model directory was deleted between slide appears
            // (e.g. user wiped Models/ via the menu-bar Delete action).
            // Without this branch a stale `.ready` would lie forever.
            if !available { downloadState = .notStarted }
        case .downloading, .verifying, .failed, .skipped:
            break
        }
    }

    public func startDownload() {
        downloadState = .downloading(progress: 0)
        downloadProgress = 0

        downloadTask = Task {
            do {
                try await modelDownloader.download { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                        self?.downloadState = .downloading(progress: progress)
                    }
                }
                downloadState = .ready
            } catch is CancellationError {
                downloadState = .notStarted
            } catch {
                downloadState = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        Task { await modelDownloader.cancel() }
        downloadState = .notStarted
    }

    public func skipDownload() {
        cancelDownload()
        downloadState = .skipped
    }
}
