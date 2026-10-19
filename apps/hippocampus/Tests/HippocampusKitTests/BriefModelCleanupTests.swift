import Foundation
import XCTest

@testable import HippocampusKit

/// The unused Qwen3 copy an earlier version downloaded is removed once, and
/// nothing else is touched. Every folder here is a throwaway one.
final class BriefModelCleanupTests: XCTestCase {
    private var root: URL!
    private var models: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-cleanup-\(UUID().uuidString)", isDirectory: true)
        models = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        suite = "brief-cleanup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The layout an earlier version's download left: the compiled model and
    /// its tokenizer under the model's id.
    private func downloadedCopy() throws -> URL {
        let directory = models.appendingPathComponent(BriefModelPresence.qwen3ModelID, isDirectory: true)
        let model = directory.appendingPathComponent(BriefModelPresence.qwen3Basename, isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: model.appendingPathComponent("weight.bin"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        return directory
    }

    private func neighbour() throws -> URL {
        let other = models.appendingPathComponent("arctic-embed-s-fp16", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: other.appendingPathComponent("model.bin"))
        return other
    }

    func testTheDownloadedCopyGoesOnceAndNothingElseIsTouched() throws {
        let copy = try downloadedCopy()
        let other = try neighbour()
        XCTAssertTrue(BriefModelPresence.isQwen3Installed(modelsDir: models))
        let outcome = BriefModelPresence.removeUnusedQwen3IfNeeded(
            modelsDir: models, bundledModel: nil, defaults: defaults)
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(BriefModelPresence.isQwen3Installed(modelsDir: models))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("model.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: models.path), "the Models folder stays")
        // Once: a copy put back afterwards on purpose is left alone.
        _ = try downloadedCopy()
        XCTAssertEqual(
            BriefModelPresence.removeUnusedQwen3IfNeeded(modelsDir: models, bundledModel: nil, defaults: defaults),
            .alreadyDone)
        XCTAssertTrue(BriefModelPresence.isQwen3Installed(modelsDir: models))
    }

    func testWithNothingThereNothingHappensAndItIsNotAskedAgain() throws {
        XCTAssertEqual(
            BriefModelPresence.removeUnusedQwen3IfNeeded(modelsDir: models, bundledModel: nil, defaults: defaults),
            .nothingThere)
        XCTAssertTrue(defaults.bool(forKey: BriefModelPresence.cleanupDoneKey))
    }

    func testABuildThatIncludesTheModelKeepsItsCopy() throws {
        let copy = try downloadedCopy()
        let bundled = root.appendingPathComponent("Bundle/Models/qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc")
        XCTAssertEqual(
            BriefModelPresence.removeUnusedQwen3IfNeeded(modelsDir: models, bundledModel: bundled, defaults: defaults),
            .keptForBundledModel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(defaults.bool(forKey: BriefModelPresence.cleanupDoneKey),
                       "a later standard build still looks")
    }

    func testALinkInThePlaceOfTheCopyIsNeverFollowed() throws {
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("file.bin"))
        let link = models.appendingPathComponent(BriefModelPresence.qwen3ModelID)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        XCTAssertEqual(
            BriefModelPresence.removeUnusedQwen3IfNeeded(modelsDir: models, bundledModel: nil, defaults: defaults),
            .leftAlone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("file.bin").path))
    }
}
