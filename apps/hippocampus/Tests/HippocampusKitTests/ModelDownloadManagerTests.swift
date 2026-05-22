// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit
import CryptoKit

final class ModelDownloadManagerTests: XCTestCase {

    private let testManifest = """
    {
      "version": 1,
      "models": [
        {
          "modelID": "bundled-model",
          "displayName": "Bundled Test",
          "bundled": true
        },
        {
          "modelID": "downloadable-model",
          "displayName": "Downloadable Test",
          "bundled": false,
          "downloadURL": "https://example.com/model.tar.gz",
          "sha256": "abc123",
          "sizeBytes": 100000,
          "requiredDiskSpace": 200000
        }
      ]
    }
    """.data(using: .utf8)!

    private func makeManager(modelsDir: URL? = nil) -> ModelDownloadManager {
        let dir = modelsDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-models-\(UUID().uuidString)")
        return ModelDownloadManager(modelsDir: dir, manifestData: testManifest)
    }

    func testManifestParsing() async {
        let mgr = makeManager()
        let models = await mgr.allModels
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].modelID, "bundled-model")
        XCTAssertTrue(models[0].bundled)
        XCTAssertEqual(models[1].modelID, "downloadable-model")
        XCTAssertFalse(models[1].bundled)
        XCTAssertEqual(models[1].sizeBytes, 100000)
    }

    func testBundledModelIsReady() async {
        let mgr = makeManager()
        let state = await mgr.state(for: "bundled-model")
        XCTAssertEqual(state, .ready)
    }

    func testNotStartedForUnknownModel() async {
        let mgr = makeManager()
        let state = await mgr.state(for: "nonexistent")
        XCTAssertEqual(state, .notStarted)
    }

    func testIsModelAvailableReturnsFalseWhenDirMissing() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-\(UUID().uuidString)")
        let mgr = ModelDownloadManager(modelsDir: tempDir, manifestData: testManifest)
        let available = await mgr.isModelAvailable(modelID: "downloadable-model")
        XCTAssertFalse(available)
    }

    func testIsModelAvailableReturnsTrueWhenDirExists() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-\(UUID().uuidString)")
        let modelDir = tempDir.appendingPathComponent("downloadable-model")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mgr = ModelDownloadManager(modelsDir: tempDir, manifestData: testManifest)
        let available = await mgr.isModelAvailable(modelID: "downloadable-model")
        XCTAssertTrue(available)
    }

    func testDeleteModel() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-\(UUID().uuidString)")
        let modelDir = tempDir.appendingPathComponent("downloadable-model")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try "test".write(to: modelDir.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mgr = ModelDownloadManager(modelsDir: tempDir, manifestData: testManifest)
        try await mgr.deleteModel(modelID: "downloadable-model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        let state = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(state, .notStarted)
    }

    func testSHA256Verification() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha256-test-\(UUID().uuidString)")
        let content = "hello world test content for sha256"
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let hash = try ModelDownloadManager.sha256Hash(of: tempFile)

        let expected = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
    }

    func testUnknownModelThrows() async {
        let mgr = makeManager()
        do {
            try await mgr.downloadModel(modelID: "no-such-model") { _ in }
            XCTFail("Expected error")
        } catch let error as ModelDownloadError {
            if case .unknownModel(let id) = error {
                XCTAssertEqual(id, "no-such-model")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEntryLookup() async {
        let mgr = makeManager()
        let entry = await mgr.entry(for: "downloadable-model")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.displayName, "Downloadable Test")
        XCTAssertEqual(entry?.sha256, "abc123")
    }

    func testStateTransitions() async {
        let mgr = makeManager()
        let initial = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(initial, .notStarted)

        await mgr.setState(modelID: "downloadable-model", state: .downloading(progress: 0.5))
        let downloading = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(downloading, .downloading(progress: 0.5))

        await mgr.setState(modelID: "downloadable-model", state: .verifying)
        let verifying = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(verifying, .verifying)

        await mgr.setState(modelID: "downloadable-model", state: .ready)
        let ready = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(ready, .ready)
    }

    func testCancellation() async {
        let mgr = makeManager()
        await mgr.cancelDownload(modelID: "downloadable-model")
        let state = await mgr.state(for: "downloadable-model")
        XCTAssertEqual(state, .notStarted)
    }
}
