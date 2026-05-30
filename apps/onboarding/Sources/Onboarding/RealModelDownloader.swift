import Foundation
import OnboardingKit
import CryptoKit
import os

actor RealModelDownloader: ModelDownloader {
    nonisolated let modelID = "qwen3-1.7b-fp16"
    nonisolated let displayName = "Qwen3 1.7B"
    nonisolated let sizeDescription = "~2.5 GB"

    /// The model artifact directory `tar xzf` writes inside `modelDir`
    /// when extracting the HF tarball. Presence of this child dir is
    /// the canonical "the model is actually installed" signal —
    /// versus the previous shallow "any directory at modelDir.path"
    /// probe, which lied about a `mkdir`'d empty dir or a partial
    /// extract. Keep in sync with the tarball layout published to HF
    /// (per the PR #220 commit body: `Qwen3-1.7B-FP16.mlmodelc/` at
    /// the archive root).
    private static let expectedArtifactName = "Qwen3-1.7B-FP16.mlmodelc"

    private var cancelled = false
    private var activeTask: URLSessionDownloadTask?

    private let logger = Logger(
        subsystem: "ai.hippocampus.onboarding",
        category: "model-download"
    )

    private var modelsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/Models")
    }

    private var modelDir: URL {
        modelsDir.appendingPathComponent(modelID)
    }

    private var artifactPath: URL {
        modelDir.appendingPathComponent(Self.expectedArtifactName)
    }

    /// "Is the Qwen3 model installed?" — true iff both `modelDir`
    /// AND the expected `.mlmodelc/` artifact inside it exist. A bare
    /// `modelDir` (left from an interrupted extract or a manual
    /// `mkdir`) returns false so the slide keeps offering Install
    /// instead of mis-reporting "Model ready".
    func isAvailable() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelDir.path) else { return false }
        return fm.fileExists(atPath: artifactPath.path)
    }

    func download(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        cancelled = false

        // The previous "no manifest → fake progress for 4.5 s, return
        // success" fallback silently lied to the user under `swift run`
        // (the Onboarding SwiftPM target has no resources:, so
        // Bundle.main.url returns nil there) and was a load-bearing
        // observability hole when the .app's Contents/Resources/
        // models.json ever drifted. Explicit throws + stderr logging
        // from here on (see docs/research/onboarding-wiring-audit-2026-
        // 05-30.md §3).
        guard let manifest = loadManifest() else {
            logger.error("manifest missing — Bundle.main lookup for models.json returned nil")
            throw ModelDownloadError.manifestMissing
        }
        guard let entry = manifest.models.first(where: { $0.modelID == modelID }) else {
            logger.error("manifest has no entry for modelID '\(self.modelID, privacy: .public)'")
            throw ModelDownloadError.manifestMissing
        }
        guard let urlStr = entry.downloadURL, let url = URL(string: urlStr) else {
            logger.error("manifest entry for '\(self.modelID, privacy: .public)' has no downloadURL")
            throw ModelDownloadError.manifestMissing
        }

        logger.info("starting download for '\(self.modelID, privacy: .public)' from \(urlStr, privacy: .public)")

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
                logger.error("sha256 mismatch: expected \(expectedHash, privacy: .public), got \(fileHash, privacy: .public). The bundled manifest is stale or HF re-uploaded the tarball — check scripts/verify-models.sh.")
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
                logger.error("tar xzf failed with exit code \(proc.terminationStatus)")
                throw ModelDownloadError.extractionFailed
            }
        } else {
            let dest = modelDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: tempURL, to: dest)
        }

        // Defense in depth: refuse to declare success if `tar` exited 0
        // but never produced the artifact dir. Saves the user from a
        // "Model ready" green check that doesn't survive Continue +
        // Brief Author backend init.
        guard FileManager.default.fileExists(atPath: artifactPath.path) else {
            logger.error("post-extract artifact missing at \(self.artifactPath.path, privacy: .public)")
            throw ModelDownloadError.extractionFailed
        }

        UserDefaults.standard.set(true, forKey: "MCIBriefModelDownloaded")
        logger.info("model '\(self.modelID, privacy: .public)' ready at \(self.artifactPath.path, privacy: .public)")
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
}

enum ModelDownloadError: LocalizedError {
    case manifestMissing
    case checksumMismatch
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "Model manifest is missing — reinstall the app."
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
