import Foundation

public enum ModelDownloadState: Sendable, Equatable {
    case notStarted
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(String)
    case skipped

    public static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.verifying, .verifying): return true
        case (.ready, .ready): return true
        case (.failed(let a), .failed(let b)): return a == b
        case (.skipped, .skipped): return true
        default: return false
        }
    }
}

public protocol ModelDownloader: Sendable {
    var modelID: String { get }
    var displayName: String { get }
    var sizeDescription: String { get }
    func isAvailable() async -> Bool
    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws
    func cancel() async
}

public actor StubModelDownloader: ModelDownloader {
    public nonisolated let modelID = "qwen3-1.7b-fp16"
    public nonisolated let displayName = "Qwen3 1.7B"
    public nonisolated let sizeDescription = "~2.5 GB"
    private var cancelled = false
    private var available: Bool

    public init(available: Bool = false) {
        self.available = available
    }

    public func isAvailable() -> Bool { available }

    public func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        cancelled = false
        for i in 0...20 {
            if cancelled { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
            progressHandler(Double(i) / 20.0)
        }
        available = true
    }

    public func cancel() {
        cancelled = true
    }
}
