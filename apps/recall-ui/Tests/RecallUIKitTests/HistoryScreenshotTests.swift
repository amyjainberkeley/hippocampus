import AppKit
import ImageIO
import MCIKeyframeCodec
import UniformTypeIdentifiers
import XCTest
@testable import RecallUIKit

/// History's screenshots: opened from synthetic encrypted keyframes the way
/// the window opens the real ones, kept in memory only, and replaced by the
/// app's icon when a moment has none or its screenshot cannot be opened.
final class HistoryScreenshotTests: XCTestCase {
    // MARK: Opening a screenshot

    func testAListThumbnailOpensFromAnEncryptedKeyframe() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let url = try keyframes.seal(width: 480, height: 300)
        let picture = await MomentPicture.load(url: url, maxPixelSize: 160, provider: keyframes.provider())
        guard case let .screenshot(data) = picture else {
            return XCTFail("a kept screenshot must open, got \(picture)")
        }
        let image = try Self.decoded(data)
        XCTAssertEqual(image.type, UTType.jpeg.identifier, "list thumbnails are small JPEGs made in memory")
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 100)
    }

    func testTheMomentDetailOpensTheScreenshotLargerAndTheSavedImageWhole() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let url = try keyframes.seal(width: 960, height: 600)
        let provider = keyframes.provider()

        let detail = await MomentPicture.load(url: url, maxPixelSize: 640, provider: provider)
        guard case let .screenshot(detailData) = detail else { return XCTFail("detail must open") }
        XCTAssertEqual(try Self.decoded(detailData).width, 640)

        let saved = await MomentPicture.load(url: url, maxPixelSize: 640, fullResolution: true, provider: provider)
        XCTAssertEqual(saved, .screenshot(keyframes.plaintext[url]!), "the full screenshot is the saved image, unchanged")
    }

    func testTheDetailOpensItsScreenshotSharpForThePaneInSteps() {
        // A 380-point pane on a Retina display needs 760 pixels: 768.
        XCTAssertEqual(MomentPicture.pixels(for: CGSize(width: 380, height: 237.5), scale: 2), 768)
        // Resizing within a step opens nothing again.
        XCTAssertEqual(MomentPicture.pixels(for: CGSize(width: 384, height: 240), scale: 2), 768)
        // Never smaller than a useful picture, never past the thumbnail bound.
        XCTAssertEqual(MomentPicture.pixels(for: CGSize(width: 120, height: 75), scale: 1), 512)
        XCTAssertEqual(MomentPicture.pixels(for: CGSize(width: 757, height: 473), scale: 2),
                       ThumbnailDataProvider.maximumThumbnailPixels)
        XCTAssertEqual(MomentPicture.pixels(for: CGSize(width: CGFloat.infinity, height: 1), scale: 2),
                       ThumbnailDataProvider.maximumThumbnailPixels)
        XCTAssertEqual(MomentPicture.pixels(for: .zero, scale: 0), 512)
    }

    // MARK: Without a screenshot

    func testAMomentWithoutAScreenshotShowsItsAppIcon() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let picture = await MomentPicture.load(url: nil, maxPixelSize: 160, provider: keyframes.provider())
        XCTAssertEqual(picture, .appIcon(.textOnly))
    }

    func testAMissingOrCorruptScreenshotShowsTheAppIconInstead() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let missing = keyframes.root.appendingPathComponent(String(repeating: "ab", count: 32) + ".bin")

        let tampered = try keyframes.seal(width: 64, height: 40)
        var bytes = try Data(contentsOf: tampered)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: tampered, options: .atomic)

        let truncated = try keyframes.seal(width: 64, height: 40)
        let whole = try Data(contentsOf: truncated)
        try whole.prefix(whole.count / 2).write(to: truncated, options: .atomic)

        // A plain image stored under its own digest is not an encrypted blob.
        let plain = try SyntheticKeyframes.image(width: 64, height: 40)
        let unsealed = keyframes.root.appendingPathComponent(KeyframeBlobCodec.sha256Hex(of: plain) + ".bin")
        try plain.write(to: unsealed)

        let otherKey = try keyframes.seal(width: 64, height: 40, key: Data(repeating: 9, count: 32))
        let outside = keyframes.root.deletingLastPathComponent().appendingPathComponent(otherKey.lastPathComponent)

        let provider = keyframes.provider()
        for (name, url) in [("missing", missing), ("tampered", tampered), ("truncated", truncated),
                            ("not encrypted", unsealed), ("another key", otherKey), ("outside", outside)] {
            for full in [false, true] {
                let picture = await MomentPicture.load(url: url, maxPixelSize: 160, fullResolution: full,
                                                       provider: provider)
                XCTAssertEqual(picture, .appIcon(.unavailable), "\(name) (full: \(full))")
            }
        }
    }

    // MARK: Shared and kept in memory

    func testMomentsOfOneWindowShareOneOpen() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let url = try keyframes.seal(width: 480, height: 300)
        let provider = keyframes.provider()

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<24 {
                group.addTask { await provider.thumbnailData(for: url, maxPixelSize: 160) }
            }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0 != nil && $0 == results[0] })
        let opensAfterRows = await provider.opensStarted
        XCTAssertEqual(opensAfterRows, 1, "rows sharing a screenshot open it once")

        let again = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertEqual(again, results[0])
        let opensAfterScrollingBack = await provider.opensStarted
        XCTAssertEqual(opensAfterScrollingBack, 1, "a row scrolled back shows the image kept in memory")

        _ = await provider.thumbnailData(for: url, maxPixelSize: 640)
        let opensAfterDetail = await provider.opensStarted
        XCTAssertEqual(opensAfterDetail, 2, "another size is another open")
    }

    func testAKeptImageIsShownOnlyWhileItsBlobIsTheSameFile() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let url = try keyframes.seal(width: 480, height: 300)
        let sealed = try Data(contentsOf: url)
        let provider = keyframes.provider()
        let first = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertNotNil(first)

        try FileManager.default.removeItem(at: url)
        let removed = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertNil(removed, "a removed screenshot is not shown from memory")

        try sealed.write(to: url)
        let restored = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertEqual(restored, first)

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        try tampered.write(to: url, options: .atomic)
        let replaced = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertNil(replaced, "a replaced blob is opened again and fails closed")

        try FileManager.default.removeItem(at: url)
        let elsewhere = keyframes.root.deletingLastPathComponent()
            .appendingPathComponent("elsewhere-\(UUID().uuidString).bin")
        try sealed.write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        let linked = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertNil(linked, "a blob turned into a link is never shown")
    }

    func testDeletingMomentsForgetsEveryKeptImage() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let url = try keyframes.seal(width: 480, height: 300)
        let signal = MemoryDeletionSignal(center: NotificationCenter())
        let provider = keyframes.provider(deletions: signal)
        _ = await provider.thumbnailData(for: url, maxPixelSize: 160)
        _ = await provider.thumbnailData(for: url, maxPixelSize: 160)
        let before = await provider.opensStarted
        XCTAssertEqual(before, 1)

        await signal.post()
        let after = await provider.thumbnailData(for: url, maxPixelSize: 160)
        XCTAssertNotNil(after)
        let opens = await provider.opensStarted
        XCTAssertEqual(opens, 2, "after a delete, nothing is served from memory")
    }

    func testKeptImagesStayWithinTheirMemoryBudget() async throws {
        let keyframes = try SyntheticKeyframes()
        defer { keyframes.remove() }
        let budget = 48_000
        let provider = keyframes.provider(memoryByteLimit: budget)
        var opened = 0
        for _ in 0..<30 {
            let url = try keyframes.seal(width: 320, height: 200)
            if await provider.thumbnailData(for: url, maxPixelSize: 160) != nil { opened += 1 }
            let kept = await provider.memoryBytes
            XCTAssertLessThanOrEqual(kept, budget)
        }
        XCTAssertEqual(opened, 30)
        let kept = await provider.memoryBytes
        XCTAssertGreaterThan(kept, 0)
    }

    // MARK: Never on disk

    /// Opens a synthetic encrypted screenshot in a separate process that may
    /// write only inside a private folder (its HOME): the system sandbox stops
    /// the process at its first attempt to write anywhere else. Then every
    /// file in that folder is searched for the decrypted image and for every
    /// image the provider returned.
    func testNothingDecryptedLandsOnDisk() throws {
        let tool = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ThumbnailProviderBehavior")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            return XCTFail("build the package's executables first: \(tool.path) is missing")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-never-on-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = try XCTUnwrap(Self.realPath(root))
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        for directory in [home, tmp, blobs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let key = Data(repeating: 21, count: 32)
        let plaintext = try SyntheticKeyframes.image(width: 480, height: 300)
        let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)
        let blob = blobs.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: blob)

        // Any write outside the folder (the system temporary and cache
        // folders included) ends the process at once with SIGKILL.
        let profile = """
            (version 1)(allow default)
            (deny file-write* (require-not (require-any (subpath "\(canonicalRoot)") (subpath "/dev")))
                (with send-signal SIGKILL))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, tool.path, "--open-in-memory", blobs.path,
                             key.map { String(format: "%02x", $0) }.joined(), blob.path]
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
                               "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertFalse(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
                       "opening a screenshot tried to write outside its folder")
        XCTAssertEqual(process.terminationReason, .exit, printed)
        XCTAssertEqual(process.terminationStatus, 0, printed)

        // Each opened image, as the child saw it: "<name> <size> <hex slice>".
        let lines = printed.split(separator: "\n").map { $0.split(separator: " ") }
        XCTAssertEqual(lines.count, 6, printed)
        var needles = [Self.middle(of: plaintext)]
        for line in lines where line.count == 3 {
            needles.append(try XCTUnwrap(Self.hexBytes(String(line[2]))))
        }
        XCTAssertEqual(needles.count, 7)

        let files = try Self.regularFiles(under: root)
        XCTAssertFalse(files.isEmpty)
        let inBlobs = files.filter { $0.deletingLastPathComponent().lastPathComponent == "blobs" }
        XCTAssertEqual(inBlobs.map(\.lastPathComponent), [blob.lastPathComponent],
                       "the blob folder holds only the encrypted screenshot")
        XCTAssertEqual(try Data(contentsOf: blob), sealed.bytes, "the encrypted screenshot is never rewritten")
        for file in files {
            let contents = try Data(contentsOf: file)
            for needle in needles {
                XCTAssertNil(contents.range(of: needle), "decrypted image bytes in \(file.path)")
            }
        }
    }

    /// The code that opens screenshots has no way to write a file.
    func testScreenshotCodeHasNoFileWrites() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = [
            "RecallUIKit/ThumbnailDataProvider.swift",
            "RecallUIKit/ScreenshotMemoryCache.swift",
            "RecallUIKit/MomentPicture.swift",
            "RecallUI/EvidenceThumbnail.swift",
        ]
        let writes = [".write(to:", "createFile(", "forWritingTo", "forUpdating", "O_WRONLY", "O_RDWR",
                      "O_CREAT", "fopen(", "CGImageDestinationCreateWithURL", "URLCache", "copyItem(",
                      "moveItem(", "FileWrapper"]
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for write in writes {
                XCTAssertFalse(source.contains(write), "\(file) must not use \(write)")
            }
        }
    }

    // MARK: Helpers

    private struct DecodedImage {
        let type: String
        let width: Int
        let height: Int
    }

    private static func decoded(_ data: Data) throws -> DecodedImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return DecodedImage(type: try XCTUnwrap(CGImageSourceGetType(source)) as String,
                            width: image.width, height: image.height)
    }

    /// `url`'s path with every link resolved (`/var` is `/private/var`), as
    /// the sandbox compares paths.
    private static func realPath(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(url.path, &buffer) else { return nil }
        return String(cString: resolved)
    }

    private static func middle(of data: Data) -> Data {
        let start = data.startIndex + data.count / 2
        return data[start ..< start + 48]
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        return walk.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
    }
}

/// The in-memory cache's budget and order.
final class ScreenshotMemoryCacheTests: XCTestCase {
    func testTheLeastRecentlyUsedImageGoesFirst() {
        var cache = ScreenshotMemoryCache<String, Int>(byteLimit: 400, countLimit: 10)
        XCTAssertTrue(cache.insert(1, cost: 100, for: "a"))
        XCTAssertTrue(cache.insert(2, cost: 100, for: "b"))
        XCTAssertTrue(cache.insert(3, cost: 100, for: "c"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertTrue(cache.insert(4, cost: 100, for: "d"))
        XCTAssertTrue(cache.insert(5, cost: 100, for: "e"))
        XCTAssertNil(cache.value(for: "b"), "b was used least recently")
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.totalBytes, 400)
        XCTAssertEqual(cache.count, 4)
    }

    func testTheCountIsBoundedToo() {
        var cache = ScreenshotMemoryCache<Int, Int>(byteLimit: 1_000_000, countLimit: 3)
        for key in 0..<10 { cache.insert(key, cost: 1, for: key) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual([7, 8, 9].compactMap { cache.value(for: $0) }, [7, 8, 9])
    }

    func testAnImageLargerThanAQuarterOfTheBudgetIsNotKept() {
        var cache = ScreenshotMemoryCache<String, Int>(byteLimit: 400, countLimit: 10)
        cache.insert(1, cost: 100, for: "small")
        XCTAssertFalse(cache.insert(2, cost: 101, for: "large"))
        XCTAssertEqual(cache.value(for: "small"), 1)
        XCTAssertNil(cache.value(for: "large"))
    }

    func testReplacingAndRemovingKeepTheBytesRight() {
        var cache = ScreenshotMemoryCache<String, Int>(byteLimit: 400, countLimit: 10)
        cache.insert(1, cost: 100, for: "a")
        cache.insert(2, cost: 50, for: "a")
        XCTAssertEqual(cache.totalBytes, 50)
        cache.removeValue(for: "a")
        XCTAssertEqual(cache.totalBytes, 0)
        cache.insert(3, cost: 10, for: "b")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
    }
}

/// Which screenshot a History row and the screenshot viewer show.
final class HistoryRowScreenshotTests: XCTestCase {
    private static let shot1 = "/tmp/blobs/" + String(repeating: "01", count: 32) + ".bin"
    private static let shot2 = "/tmp/blobs/" + String(repeating: "02", count: 32) + ".bin"

    private func hit(_ id: UInt64, _ ts: UInt64, _ title: String, _ path: String? = nil, taken: UInt64? = nil) -> Hit {
        Hit(eventId: id, tsUs: ts, appBundleId: "com.google.Chrome", windowTitle: title, url: nil,
            ocrTextSnippet: "", source: "recent", score: nil, thumbnailPath: path, sourceKind: "screen_ocr",
            thumbnailTsUs: path == nil ? nil : (taken ?? ts))
    }

    func testARowShowsTheNewestScreenshotOfItsMoments() {
        let hits = [
            hit(4, 400, "Docs"),
            hit(3, 300, "Docs", Self.shot2),
            hit(2, 200, "Docs", Self.shot1),
            hit(1, 100, "Mail"),
        ]
        let rows = HistorySections.group(hits: hits, sessions: [], calendar: Calendar(identifier: .gregorian))
            .flatMap(\.rows)
        XCTAssertEqual(rows.map(\.count), [3, 1])
        XCTAssertEqual(rows[0].hit.id, 4, "the row still opens its newest moment")
        XCTAssertEqual(rows[0].screenshot?.id, 3)
        XCTAssertNil(rows[1].screenshot, "a row of text-only moments has no screenshot")
    }

    func testARowBorrowsOnlyWhatTheReaderWouldLetItsMomentShow() {
        func row(_ hits: [Hit]) -> HistoryRow {
            HistorySections.group(hits: hits, sessions: [], calendar: Calendar(identifier: .gregorian))
                .flatMap(\.rows)[0]
        }
        let minute: UInt64 = 60_000_000
        // A window beside the one in front never shows another moment's
        // screenshot, however near.
        var beside = hit(2, 10 * minute, "Docs")
        beside = Hit(eventId: 2, tsUs: beside.tsUs, appBundleId: beside.appBundleId, windowTitle: "Docs", url: nil,
                     ocrTextSnippet: "", source: "recent", score: nil, sourceKind: "screen_context")
        XCTAssertNil(row([beside, hit(1, 9 * minute, "Docs", Self.shot1)]).screenshot)
        // A screenshot older than five minutes stands for no later moment.
        XCTAssertNil(row([hit(2, 20 * minute, "Docs"), hit(1, 10 * minute, "Docs", Self.shot1)]).screenshot)
        XCTAssertEqual(row([hit(2, 14 * minute, "Docs"), hit(1, 10 * minute, "Docs", Self.shot1)]).screenshot?.id, 1)
        // A moment's own screenshot is always its row's.
        XCTAssertEqual(row([hit(2, 20 * minute, "Docs", Self.shot2), hit(1, 10 * minute, "Docs", Self.shot1)])
            .screenshot?.id, 2)
    }

    func testTheViewerStepsThroughEachScreenshotOnce() {
        let hits = [
            hit(6, 600, "Docs", Self.shot2, taken: 500),
            hit(5, 500, "Docs", Self.shot2),
            hit(4, 400, "Mail"),
            hit(3, 300, "Docs", Self.shot1, taken: 100),
            hit(2, 200, "Docs", Self.shot1, taken: 100),
            hit(1, 100, "Docs", Self.shot1),
        ]
        XCTAssertEqual(MCI.Workspace.screenshotMoments(from: hits).map(\.id), [6, 3])
        XCTAssertEqual(MCI.Workspace.screenshotMoments(from: hits, keeping: 2).map(\.id), [6, 2],
                       "the moment open stands for its screenshot")
        XCTAssertEqual(MCI.Workspace.screenshotMoments(from: hits, keeping: 4).map(\.id), [6, 3])
    }

    func testTheWireSaysWhenTheScreenshotWasTaken() throws {
        let path = Self.shot1
        let json = """
        [{"event_id":7,"ts_us":5000000,"app_bundle_id":"com.google.Chrome","window_title":"Docs",\
        "url":null,"ocr_text_snippet":"","source":"recent","score":null,"thumbnail_path":"\(path)",\
        "thumbnail_ts_us":2000000,"source_kind":"screen_ocr"},
        {"event_id":8,"ts_us":2000000,"app_bundle_id":"com.google.Chrome","window_title":"Docs",\
        "url":null,"ocr_text_snippet":"","source":"recent","score":null,"thumbnail_path":"\(path)",\
        "thumbnail_ts_us":2000000},
        {"event_id":9,"ts_us":3000000,"app_bundle_id":null,"window_title":null,\
        "url":null,"ocr_text_snippet":"","source":"recent","score":null,"thumbnail_path":"\(path)"},
        {"event_id":10,"ts_us":3000000,"app_bundle_id":null,"window_title":null,\
        "url":null,"ocr_text_snippet":"","source":"recent","score":null,"thumbnail_path":null,\
        "thumbnail_ts_us":1000000}]
        """
        let hits = try JSONDecoder().decode([HitWire].self, from: Data(json.utf8)).map { $0.toHit() }
        XCTAssertEqual(hits.map(\.thumbnailTsUs), [2_000_000, 2_000_000, nil, nil])
        XCTAssertEqual(hits.map(\.screenshotIsEarlier), [true, false, false, false],
                       "only a screenshot kept by an earlier moment says so; an older FFI says nothing")
    }
}

/// Synthetic encrypted keyframes in a private blob folder, sealed with the
/// capture helper's codec. Nothing here is real.
private final class SyntheticKeyframes: @unchecked Sendable {
    let root: URL
    let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
    private(set) var plaintext: [URL: Data] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-history-screenshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func provider(deletions: MemoryDeletionSignal = MemoryDeletionSignal(center: NotificationCenter()),
                  memoryByteLimit: Int = ThumbnailDataProvider.memoryByteLimit) -> ThumbnailDataProvider {
        let key = key
        return ThumbnailDataProvider(blobRoot: root, deletions: deletions, memoryByteLimit: memoryByteLimit) { key }
    }

    /// Seal a new synthetic screenshot and store it as the helper does.
    func seal(width: Int, height: Int, key: Data? = nil) throws -> URL {
        let image = try Self.image(width: width, height: height)
        let sealed = try KeyframeBlobCodec.seal(plaintext: image, keyMaterial: key ?? self.key)
        let url = root.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: url)
        plaintext[url] = image
        return url
    }

    /// A PNG of a window-like layout over noise, so every image's bytes are
    /// its own.
    static func image(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let rowBytes = bitmap.bytesPerRow
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let bar = y < height / 10
                let base = bar ? 214 : (x < width / 5 ? 236 : 250)
                let value = UInt8(max(0, base - Int.random(in: 0...40, using: &generator)))
                let offset = y * rowBytes + x * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = bar ? value : value &+ (value < 250 ? 5 : 0)
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
