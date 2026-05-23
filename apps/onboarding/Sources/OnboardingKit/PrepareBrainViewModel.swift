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

    public func checkModelAvailability() async {
        let available = await modelDownloader.isAvailable()
        if available {
            downloadState = .ready
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
