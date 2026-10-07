import AppKit
import MCIKeyframeCodec
import XCTest
@testable import RecallUIKit

final class ScreenshotKeyRecoveryTests: XCTestCase {
    func testExplicitRereadRecoversAfterKeyAccessFailureWithoutRetryingAmbientImages() async throws {
        let fixture = try ScreenshotKeyFixture()
        defer { fixture.remove() }
        let loader = ScreenshotKeyLoader(key: fixture.key, failures: 1)
        let provider = ThumbnailDataProvider(blobRoot: fixture.root) { try loader.load() }

        let first = await provider.screenshotData(for: fixture.imageURL)
        let thumbnail = await provider.thumbnailData(for: fixture.imageURL, maxPixelSize: 24)
        let repeated = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertNil(first)
        XCTAssertNil(thumbnail)
        XCTAssertNil(repeated)
        XCTAssertEqual(loader.count, 1, "Passive image loading must not repeatedly query unavailable Keychain material")

        let service = LocalScreenshotRereader(provider: provider, executableURL: fixture.workerURL)
        let result = await service.read(url: fixture.imageURL)
        XCTAssertEqual(result, .text("Seven blue notebooks.", omittedLines: 0))
        let restored = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertEqual(restored, fixture.image)
        XCTAssertEqual(loader.count, 2)

        let again = await service.read(url: fixture.imageURL)
        XCTAssertEqual(again, result)
        XCTAssertEqual(loader.count, 2, "A successful key remains cached across explicit and passive reads")
    }

    func testFailedExplicitRetryRemainsCachedForPassiveLoads() async throws {
        let fixture = try ScreenshotKeyFixture()
        defer { fixture.remove() }
        let loader = ScreenshotKeyLoader(key: fixture.key, failures: 10)
        let provider = ThumbnailDataProvider(blobRoot: fixture.root) { try loader.load() }
        let initial = await provider.screenshotData(for: fixture.imageURL)
        let retry = await provider.rereadScreenshotData(for: fixture.imageURL)
        let passive = await provider.thumbnailData(for: fixture.imageURL, maxPixelSize: 24)
        XCTAssertNil(initial)
        XCTAssertNil(retry)
        XCTAssertNil(passive)
        XCTAssertEqual(loader.count, 2, "Each explicit action permits one shared attempt, not a background retry loop")
    }

    func testCanceledAndOutsidePathRetriesDoNotRearmKeyAccess() async throws {
        let fixture = try ScreenshotKeyFixture()
        defer { fixture.remove() }
        let loader = ScreenshotKeyLoader(key: fixture.key, failures: 1)
        let provider = ThumbnailDataProvider(blobRoot: fixture.root) { try loader.load() }
        let initial = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertNil(initial)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.rereadScreenshotData(for: fixture.imageURL)
        }
        let canceledData = await canceled.value
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(fixture.imageURL.lastPathComponent)
        let outsideData = await provider.rereadScreenshotData(for: outside)
        let passive = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertNil(canceledData)
        XCTAssertNil(outsideData)
        XCTAssertNil(passive)
        XCTAssertEqual(loader.count, 1)
    }

    func testConcurrentExplicitRetriesShareResolutionAndPreserveItsSuccessfulCache() async throws {
        let fixture = try ScreenshotKeyFixture()
        defer { fixture.remove() }
        let started = expectation(description: "retry key resolution started")
        let loader = ScreenshotKeyLoader(key: fixture.key, failures: 1, started: started)
        defer { loader.release() }
        let provider = ThumbnailDataProvider(blobRoot: fixture.root) { try loader.load() }
        let initial = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertNil(initial)
        let requests = (0..<16).map { _ in Task { await provider.rereadScreenshotData(for: fixture.imageURL) } }
        await fulfillment(of: [started], timeout: 2)
        loader.release()
        for request in requests {
            let data = await request.value
            XCTAssertEqual(data, fixture.image)
        }
        let passive = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertEqual(passive, fixture.image)
        XCTAssertEqual(loader.count, 2)
    }

    func testRecoveryNeverReturnsTamperedEncryptedImage() async throws {
        let fixture = try ScreenshotKeyFixture()
        defer { fixture.remove() }
        let loader = ScreenshotKeyLoader(key: fixture.key, failures: 1)
        let provider = ThumbnailDataProvider(blobRoot: fixture.root) { try loader.load() }
        let initial = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertNil(initial)
        let original = try Data(contentsOf: fixture.imageURL)
        var tampered = original
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: fixture.imageURL)
        let rejected = await provider.rereadScreenshotData(for: fixture.imageURL)
        XCTAssertNil(rejected)
        try original.write(to: fixture.imageURL)
        let restored = await provider.screenshotData(for: fixture.imageURL)
        XCTAssertEqual(restored, fixture.image)
        XCTAssertEqual(loader.count, 2)
    }
}

private final class ScreenshotKeyLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let key: Data
    private let failures: Int
    private let started: XCTestExpectation?
    private let gate = DispatchSemaphore(value: 0)
    private var attempts = 0

    init(key: Data, failures: Int, started: XCTestExpectation? = nil) {
        self.key = key; self.failures = failures; self.started = started
    }
    var count: Int { lock.withLock { attempts } }
    func release() { gate.signal() }
    func load() throws -> Data {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt <= failures { throw KeychainDatabaseKeyError.interactionNotAllowed }
        if let started, attempt == failures + 1 { started.fulfill(); gate.wait() }
        return key
    }
}

private struct ScreenshotKeyFixture {
    let root: URL
    let imageURL: URL
    let workerURL: URL
    let image: Data
    let key = Data(repeating: 13, count: 32)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-key-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let sealed = try KeyframeBlobCodec.seal(plaintext: image, keyMaterial: key)
        imageURL = root.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: imageURL)
        workerURL = root.appendingPathComponent("synthetic-ocr-worker")
        // Replace only the external recognizer. Real authentication, image decoding,
        // subprocess transport, transcript review and explicit re-read run above.
        let worker = """
        #!/bin/sh
        /bin/cat > /dev/null
        /usr/bin/printf '%s' '{"version":1,"lines":[{"text":"Seven blue notebooks.","confidence":0.99,"box":[0.1,0.1,0.8,0.3]}]}'
        """
        try worker.write(to: workerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workerURL.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
