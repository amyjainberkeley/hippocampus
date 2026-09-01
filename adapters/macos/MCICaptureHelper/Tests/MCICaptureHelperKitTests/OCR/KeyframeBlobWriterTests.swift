import CoreVideo
import Foundation
import XCTest

@testable import MCICaptureHelperKit
@testable import MCIKeyframeCodec

final class KeyframeBlobWriterTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))

    func testEncoderUsesSharedV2Codec() throws {
        let pixels = makePixelBuffer()
        let sealed = try XCTUnwrap(
            KeyframeBlobEncoder.encodeAndEncrypt(
                pixelBuffer: pixels,
                blobKeyMaterial: key
            )
        )

        XCTAssertEqual(sealed.bytes.prefix(KeyframeBlobCodec.saltLength).count, 16)
        XCTAssertEqual(sealed.lowercaseHexDigest, KeyframeBlobCodec.sha256Hex(of: sealed.bytes))
        let jpeg = try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: key)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
    }

    func testDurableWritePrecedesRetentionAndUnchangedFrameSkips() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = makePixelBuffer()
        let coordinator = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: key,
            policy: KeyframePolicy(materialDistance: 12, maxSilenceNanoseconds: 300)
        )
        let first = candidate(ordinal: 1)

        let retainedValue = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        let retained = try XCTUnwrap(retainedValue)
        let url = root.appendingPathComponent("\(retained.lowercaseHexDigest).bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(
            KeyframeBlobCodec.sha256Hex(of: try Data(contentsOf: url)),
            retained.lowercaseHexDigest
        )
        await coordinator.confirm(retained)

        let duplicate = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: candidate(ordinal: 2)
        )
        XCTAssertNil(duplicate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testWriteFailureDoesNotAdvancePolicyState() async throws {
        let pixels = makePixelBuffer()
        let store = ToggleStore()
        let coordinator = KeyframeRetentionCoordinator(
            policy: .default,
            keyMaterial: key,
            store: store,
            sealer: { _, key in
                try? KeyframeBlobCodec.seal(
                    plaintext: Data("jpeg".utf8),
                    keyMaterial: key
                )
            }
        )
        let first = candidate(ordinal: 1)

        let failed = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        XCTAssertNil(failed)
        store.allowWrites()
        let retried = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        XCTAssertNotNil(retried)
    }

    func testDiscardDeletesBlobAndRollsPolicyStateBack() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = makePixelBuffer()
        let coordinator = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: key
        )
        let first = candidate(ordinal: 1)
        let retainedValue = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        let retained = try XCTUnwrap(retainedValue)

        await coordinator.discard(retained)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("\(retained.lowercaseHexDigest).bin").path
            )
        )
        let retried = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        XCTAssertNotNil(retried)
    }

    func testCancelledAttemptPublishesNothing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: key
        )
        let pixels = makePixelBuffer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.retain(
                input: KeyframePixelInput(pixelBuffer: pixels),
                candidate: candidate(ordinal: 1)
            )
        }

        let retention = await task.value
        XCTAssertNil(retention)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCancellationAfterStorePublicationRollsBlobBack() async {
        let store = CancellingStore()
        let pixels = makePixelBuffer()
        let coordinator = KeyframeRetentionCoordinator(
            policy: .default,
            keyMaterial: key,
            store: store,
            sealer: { _, key in
                try? KeyframeBlobCodec.seal(
                    plaintext: Data("jpeg".utf8),
                    keyMaterial: key
                )
            }
        )

        let retention = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: candidate(ordinal: 1)
        )
        let removeCount = store.removeCount()
        let previous = await coordinator.currentPreviousRetainedForTesting()
        XCTAssertNil(retention)
        XCTAssertEqual(removeCount, 1)
        XCTAssertNil(previous)
    }

    func testPendingCommitStateIsBounded() async {
        let store = ToggleStore()
        store.allowWrites()
        let pixels = makePixelBuffer()
        let coordinator = KeyframeRetentionCoordinator(
            policy: .default,
            keyMaterial: key,
            store: store,
            sealer: { _, key in
                try? KeyframeBlobCodec.seal(
                    plaintext: Data(UUID().uuidString.utf8),
                    keyMaterial: key
                )
            }
        )

        for ordinal in 1...KeyframeRetentionCoordinator.maximumPendingCommits {
            let retained = await coordinator.retain(
                input: KeyframePixelInput(pixelBuffer: pixels),
                candidate: KeyframeEvidenceCandidate(
                    captureOrdinal: UInt64(ordinal),
                    focusedWindowId: UInt32(ordinal),
                    dhash: DHash(bits: 0),
                    monotonicNanoseconds: UInt64(ordinal)
                )
            )
            XCTAssertNotNil(retained)
        }
        let overflow = await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: KeyframeEvidenceCandidate(
                captureOrdinal: 5,
                focusedWindowId: 5,
                dhash: DHash(bits: 0),
                monotonicNanoseconds: 5
            )
        )
        XCTAssertNil(overflow)
    }

    private func candidate(ordinal: UInt64) -> KeyframeEvidenceCandidate {
        KeyframeEvidenceCandidate(
            captureOrdinal: ordinal,
            focusedWindowId: 7,
            dhash: DHash(bits: 0),
            monotonicNanoseconds: ordinal
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-keyframe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                32,
                32,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &output
            ),
            kCVReturnSuccess
        )
        return output!
    }
}

private final class ToggleStore: KeyframeBlobPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var writesAllowed = false

    func allowWrites() {
        lock.withLock { writesAllowed = true }
    }

    func persist(_: KeyframeSealedBlob) throws {
        if !lock.withLock({ writesAllowed }) {
            throw KeyframeBlobStoreError.writeFailed
        }
    }

    func remove(_: KeyframeSealedBlob) throws {}
}

private final class CancellingStore: KeyframeBlobPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var removals = 0

    func persist(_: KeyframeSealedBlob) throws {
        withUnsafeCurrentTask { $0?.cancel() }
    }

    func remove(_: KeyframeSealedBlob) throws {
        lock.withLock { removals += 1 }
    }

    func removeCount() -> Int {
        lock.withLock { removals }
    }
}
