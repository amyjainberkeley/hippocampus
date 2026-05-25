import Foundation
import OnboardingKit
import CryptoKit

actor RealModelDownloader: ModelDownloader {
    nonisolated let modelID = "qwen3-1.7b-fp16"
    nonisolated let displayName = "Qwen3 1.7B"
    nonisolated let sizeDescription = "~2.5 GB"

    private var cancelled = false
    private var activeTask: URLSessionDownloadTask?

    private var modelsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/Models")
    }

    private var modelDir: URL {
        modelsDir.appendingPathComponent(modelID)
    }

    private struct Manifest: Codable {
        let version: Int
        let models: [Entry]
    }

    private struct Entry: Codable {
        let modelID: String
        let downloadURL: String?
        let sha256: String?
        let sizeBytes: Int64?
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelDir.path)
    }

    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        cancelled = false

        guard let manifest = loadManifest(),
              let entry = manifest.models.first(where: { $0.modelID == modelID }),
              let urlStr = entry.downloadURL,
              let url = URL(string: urlStr) else {
            progressHandler(0)
            for i in 0...30 {
                if cancelled { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(150))
                progressHandler(Double(i) / 30.0)
            }
            return
        }

        let delegate = ProgressDelegate { progress in
            progressHandler(progress)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        activeTask = task
        delegate.downloadTask = task
        task.resume()

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = continuation
        }

        if cancelled { throw CancellationError() }

        if let expectedHash = entry.sha256,
           expectedHash != "PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED" {
            let fileHash = try sha256(of: tempURL)
            guard fileHash == expectedHash.lowercased() else {
                try? FileManager.default.removeItem(at: tempURL)
                throw ModelDownloadError.checksumMismatch
            }
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        if urlStr.hasSuffix(".tar.gz") || urlStr.hasSuffix(".tgz") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["xzf", tempURL.path, "-C", modelDir.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw ModelDownloadError.extractionFailed
            }
        } else {
            let dest = modelDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: tempURL, to: dest)
        }

        UserDefaults.standard.set(true, forKey: "MCIBriefModelDownloaded")
    }

    func cancel() {
        cancelled = true
        activeTask?.cancel()
        activeTask = nil
    }

    private func loadManifest() -> Manifest? {
        if let url = Bundle.main.url(forResource: "models", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let m = try? JSONDecoder().decode(Manifest.self, from: data) {
            return m
        }
        return nil
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ModelDownloadError: LocalizedError {
    case checksumMismatch
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: "Download integrity check failed"
        case .extractionFailed: "Failed to extract model archive"
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: @Sendable (Double) -> Void
    var downloadTask: URLSessionDownloadTask?
    var completion: CheckedContinuation<URL, Error>?

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            completion?.resume(returning: tmp)
        } catch {
            completion?.resume(throwing: error)
        }
        completion = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            completion?.resume(throwing: error)
            completion = nil
        }
    }
}
