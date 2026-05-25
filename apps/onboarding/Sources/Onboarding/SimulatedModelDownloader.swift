import Foundation
import OnboardingKit

actor SimulatedModelDownloader: ModelDownloader {
    nonisolated let modelID = "qwen3-1.7b-fp16"
    nonisolated let displayName = "Qwen3 1.7B"
    nonisolated let sizeDescription = "~2.5 GB"
    private var cancelled = false

    private var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/Models/qwen3-1.7b-fp16")
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelDir.path)
    }

    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        cancelled = false
        let steps = 30
        for i in 0...steps {
            if cancelled { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(150))
            progressHandler(Double(i) / Double(steps))
        }
    }

    func cancel() {
        cancelled = true
    }
}
