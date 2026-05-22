// SPDX-License-Identifier: TBD-private
import Foundation
import CryptoKit
import os

public actor ModelDownloadManager {
    public enum DownloadState: Sendable, Equatable {
        case notStarted
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(String)

        public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.verifying, .verifying): return true
            case (.ready, .ready): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    public struct ModelManifest: Codable, Sendable {
        public let version: Int
        public let models: [ModelEntry]
    }

    public struct ModelEntry: Codable, Sendable {
        public let modelID: String
        public let displayName: String
        public let bundled: Bool
        public let note: String?
        public let downloadURL: String?
        public let sha256: String?
        public let sizeBytes: Int64?
        public let requiredDiskSpace: Int64?
    }

    private let modelsDir: URL
    private let manifest: ModelManifest
    private let logger = Logger(subsystem: "ai.hippocampus", category: "model-download")
    private var states: [String: DownloadState] = [:]
    private var activeTasks: [String: Task<Void, Error>] = [:]

    private static let diskBufferBytes: Int64 = 500_000_000 // 500 MB

    public init(modelsDir: URL? = nil, manifestData: Data? = nil) {
        self.modelsDir = modelsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/Models")

        if let data = manifestData, let m = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            self.manifest = m
        } else if let bundledURL = Bundle.module.url(forResource: "models", withExtension: "json"),
                  let data = try? Data(contentsOf: bundledURL),
                  let m = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            self.manifest = m
        } else if let mainURL = Bundle.main.url(forResource: "models", withExtension: "json"),
                  let data = try? Data(contentsOf: mainURL),
                  let m = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            self.manifest = m
        } else {
            self.manifest = ModelManifest(version: 1, models: [])
        }

        for entry in self.manifest.models {
            if entry.bundled {
                states[entry.modelID] = .ready
            }
        }
    }

    public func isModelAvailable(modelID: String) -> Bool {
        let dir = modelsDir.appendingPathComponent(modelID)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    public func state(for modelID: String) -> DownloadState {
        if let s = states[modelID] { return s }
        if isModelAvailable(modelID: modelID) {
            return .ready
        }
        return .notStarted
    }

    public func entry(for modelID: String) -> ModelEntry? {
        manifest.models.first { $0.modelID == modelID }
    }

    public var allModels: [ModelEntry] {
        manifest.models
    }

    public func downloadModel(
        modelID: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let entry = entry(for: modelID) else {
            throw ModelDownloadError.unknownModel(modelID)
        }
        guard !entry.bundled else { return }
        guard let urlStr = entry.downloadURL, let url = URL(string: urlStr) else {
            throw ModelDownloadError.invalidURL
        }

        try checkDiskSpace(required: entry.requiredDiskSpace ?? entry.sizeBytes ?? 0)

        states[modelID] = .downloading(progress: 0)
        progressHandler(0)

        let task = Task<Void, Error> {
            let delegate = DownloadProgressDelegate(progressHandler: progressHandler, actor: self, modelID: modelID)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask
            downloadTask.resume()

            let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
                delegate.completion = continuation
            }

            try Task.checkCancellation()

            await self.setState(modelID: modelID, state: .verifying)

            if let expectedHash = entry.sha256, expectedHash != "PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED" {
                let fileHash = try Self.sha256Hash(of: tempURL)
                guard fileHash == expectedHash.lowercased() else {
                    throw ModelDownloadError.checksumMismatch(expected: expectedHash, got: fileHash)
                }
            }

            try Task.checkCancellation()

            let destDir = self.modelsDir.appendingPathComponent(modelID)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            if urlStr.hasSuffix(".tar.gz") || urlStr.hasSuffix(".tgz") {
                try Self.extractTarGz(tempURL, to: destDir)
            } else if urlStr.hasSuffix(".zip") {
                try Self.extractZip(tempURL, to: destDir)
            } else {
                let destFile = destDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: tempURL, to: destFile)
            }

            await self.setState(modelID: modelID, state: .ready)
            UserDefaults.standard.set(true, forKey: "MCIBriefModelDownloaded")
            self.logger.info("model-download: \(modelID) ready")
        }

        activeTasks[modelID] = task

        do {
            try await task.value
        } catch {
            if !(error is CancellationError) {
                states[modelID] = .failed(error.localizedDescription)
                logger.error("model-download: \(modelID) failed: \(error.localizedDescription)")
            }
            activeTasks[modelID] = nil
            throw error
        }
        activeTasks[modelID] = nil
    }

    public func cancelDownload(modelID: String) {
        activeTasks[modelID]?.cancel()
        activeTasks[modelID] = nil
        states[modelID] = .notStarted
    }

    public func deleteModel(modelID: String) throws {
        let dir = modelsDir.appendingPathComponent(modelID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        states[modelID] = .notStarted
        if modelID == "qwen3-1.7b-int4" {
            UserDefaults.standard.set(false, forKey: "MCIBriefModelDownloaded")
        }
        logger.info("model-download: deleted \(modelID)")
    }

    // MARK: - Internal

    func setState(modelID: String, state: DownloadState) {
        states[modelID] = state
    }

    private func checkDiskSpace(required: Int64) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let freeSpace = attrs[.systemFreeSize] as? Int64 else {
            throw ModelDownloadError.cannotCheckDiskSpace
        }
        let needed = required + Self.diskBufferBytes
        if freeSpace < needed {
            let freeGB = String(format: "%.1f", Double(freeSpace) / 1_073_741_824)
            let neededGB = String(format: "%.1f", Double(needed) / 1_073_741_824)
            throw ModelDownloadError.insufficientDiskSpace(freeGB: freeGB, neededGB: neededGB)
        }
    }

    static func sha256Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1_048_576) // 1 MB chunks
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func extractTarGz(_ archive: URL, to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["xzf", archive.path, "-C", dest.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ModelDownloadError.extractionFailed("tar exit code \(proc.terminationStatus)")
        }
    }

    static func extractZip(_ archive: URL, to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", archive.path, "-d", dest.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ModelDownloadError.extractionFailed("unzip exit code \(proc.terminationStatus)")
        }
    }
}

// MARK: - Download delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: @Sendable (Double) -> Void
    let actor: ModelDownloadManager
    let modelID: String
    var downloadTask: URLSessionDownloadTask?
    var completion: CheckedContinuation<URL, Error>?

    init(progressHandler: @escaping @Sendable (Double) -> Void, actor: ModelDownloadManager, modelID: String) {
        self.progressHandler = progressHandler
        self.actor = actor
        self.modelID = modelID
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }
        progressHandler(progress)
        Task { await actor.setState(modelID: modelID, state: .downloading(progress: progress)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            completion?.resume(returning: tempFile)
        } catch {
            completion?.resume(throwing: error)
        }
        completion = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion?.resume(throwing: error)
            completion = nil
        }
    }
}

// MARK: - Errors

public enum ModelDownloadError: LocalizedError, Equatable {
    case unknownModel(String)
    case invalidURL
    case insufficientDiskSpace(freeGB: String, neededGB: String)
    case cannotCheckDiskSpace
    case checksumMismatch(expected: String, got: String)
    case extractionFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model: \(id)"
        case .invalidURL: return "Invalid download URL"
        case .insufficientDiskSpace(let free, let needed):
            return "Not enough disk space. Need \(needed) GB free, you have \(free) GB."
        case .cannotCheckDiskSpace: return "Cannot check available disk space"
        case .checksumMismatch(let expected, let got):
            return "Checksum mismatch — file corrupted. Expected \(expected.prefix(12))…, got \(got.prefix(12))…"
        case .extractionFailed(let msg): return "Extraction failed: \(msg)"
        case .networkError(let msg): return "Download failed: \(msg)"
        }
    }
}
