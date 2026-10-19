// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import ImageIO
import MCIKeyframeCodec
import UniformTypeIdentifiers

public protocol ThumbnailDataProviding: Sendable {
    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data?
    func screenshotData(for url: URL) async -> Data?
    /// Explicit user retry; passive image loading must use the methods above.
    func rereadScreenshotData(for url: URL) async -> Data?
}

public extension ThumbnailDataProviding {
    func screenshotData(for url: URL) async -> Data? { nil }
    func rereadScreenshotData(for url: URL) async -> Data? { await screenshotData(for: url) }
}

/// Authenticates encrypted keyframe blobs and returns only bounded image data.
/// The provider caches successful Keychain resolution for the app session and
/// retries a failed resolution only after an explicit re-read. It never writes
/// plaintext to disk. Detail views may request a bounded original image;
/// result-list thumbnails keep their smaller decoding and memory budgets.
///
/// Opened images are kept in memory only (`ScreenshotMemoryCache`, bounded
/// by `memoryByteLimit`) so a list that scrolls back shows them at once. A
/// kept image is served only while its blob is the same file it was opened
/// from, and every kept image goes when moments are deleted. Moments of one
/// window often share a screenshot: requests for the same image while it is
/// being opened share one read, one decryption and one decode, off the main
/// thread.
public actor ThumbnailDataProvider: ThumbnailDataProviding {
    public static let maximumBlobBytes = 12 * 1024 * 1024
    public static let minimumBlobBytes = 16 + 12 + 16
    public static let maximumThumbnailPixels = 1_024
    public static let maximumScreenshotPixels = 3_840
    /// Opened images kept in memory at most, in bytes and in count.
    public static let memoryByteLimit = 64 * 1024 * 1024
    public static let memoryCountLimit = 512

    public static let shared = ThumbnailDataProvider.production()

    private let blobRoot: URL
    private let keyLoader: @Sendable () throws -> Data
    private let deletions: MemoryDeletionSignal
    private var keyResolution: (id: UUID, task: Task<Data?, Never>)?
    private var resolvedKey: Data?
    private var keyResolutionFinished = false
    private var memory: ScreenshotMemoryCache<ImageKey, OpenedImage>
    private var memoryGeneration: UInt64
    private var flights: [ImageKey: Flight] = [:]
    /// How many times a blob was read and opened: tests prove sharing.
    private(set) var opensStarted = 0

    public init(
        blobRoot: URL,
        deletions: MemoryDeletionSignal = .shared,
        memoryByteLimit: Int = ThumbnailDataProvider.memoryByteLimit,
        keyLoader: @escaping @Sendable () throws -> Data
    ) {
        self.blobRoot = blobRoot.standardizedFileURL
        self.keyLoader = keyLoader
        self.deletions = deletions
        self.memory = ScreenshotMemoryCache(byteLimit: memoryByteLimit, countLimit: Self.memoryCountLimit)
        self.memoryGeneration = deletions.generation
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ThumbnailDataProvider {
        let brainPath = environment["MCI_DB_PATH"] ?? defaultBrainPath()
        let root = URL(fileURLWithPath: brainPath)
            .deletingLastPathComponent()
            .appendingPathComponent("blobs", isDirectory: true)
        let reference = KeychainDatabaseKeyReference.from(environment: environment)
        return ThumbnailDataProvider(blobRoot: root) {
            try DevelopmentDatabaseKeyMaterial.bytes(from: environment)
                ?? KeychainDatabaseKeyResolver().resolveBytes(reference: reference)
        }
    }

    public func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        await imageData(for: url, thumbnailPixels: min(Self.maximumThumbnailPixels, max(1, maxPixelSize)))
    }

    public func screenshotData(for url: URL) async -> Data? {
        await imageData(for: url, thumbnailPixels: nil)
    }

    public func rereadScreenshotData(for url: URL) async -> Data? {
        guard !Task.isCancelled, Self.validatedRequest(url: url, blobRoot: blobRoot) != nil else { return nil }
        if keyResolutionFinished, resolvedKey == nil {
            keyResolutionFinished = false
        }
        return await imageData(for: url, thumbnailPixels: nil)
    }

    /// Bytes of opened images kept in memory now.
    var memoryBytes: Int { memory.totalBytes }

    private func imageData(for url: URL, thumbnailPixels: Int?) async -> Data? {
        guard !Task.isCancelled,
              let request = Self.validatedRequest(url: url, blobRoot: blobRoot)
        else {
            return nil
        }
        let key = ImageKey(digest: request.digest, pixels: thumbnailPixels ?? 0)
        if let kept = keptImage(for: key, at: request.url) {
            return kept
        }
        guard let keyMaterial = await keyMaterial(), !Task.isCancelled else {
            return nil
        }
        if let kept = keptImage(for: key, at: request.url) {
            return kept
        }

        // An open that began before a delete is not joined: its blob may be gone.
        let current = flights[key].flatMap { $0.generation == deletions.generation ? $0 : nil }
        let flight = current ?? startFlight(
            key: key, request: request, keyMaterial: keyMaterial, thumbnailPixels: thumbnailPixels
        )
        let waiter = UUID()
        flight.waiters.insert(waiter)
        let opened = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { await self.abandon(waiter, of: flight, key: key) }
        }
        flight.waiters.remove(waiter)
        if flights[key] === flight {
            flights[key] = nil
            // A delete while it was opening may have removed this blob.
            if let opened, flight.generation == deletions.generation {
                keep(opened, for: key)
            }
        }
        guard !Task.isCancelled else { return nil }
        return opened?.data
    }

    private func startFlight(
        key: ImageKey,
        request: ValidatedRequest,
        keyMaterial: Data,
        thumbnailPixels: Int?
    ) -> Flight {
        opensStarted += 1
        let task = Task.detached(priority: .utility) {
            Self.open(request: request, keyMaterial: keyMaterial, thumbnailPixels: thumbnailPixels)
        }
        let flight = Flight(task: task, generation: deletions.generation)
        flights[key] = flight
        return flight
    }

    /// A waiter went away: the open stops when nobody waits for it any more.
    private func abandon(_ waiter: UUID, of flight: Flight, key: ImageKey) {
        flight.waiters.remove(waiter)
        guard flight.waiters.isEmpty else { return }
        flight.task.cancel()
        if flights[key] === flight {
            flights[key] = nil
        }
    }

    /// The image kept for `key`, while its blob is still the file it was
    /// opened from and no moment was deleted since.
    private func keptImage(for key: ImageKey, at url: URL) -> Data? {
        let generation = deletions.generation
        if generation != memoryGeneration {
            memory.removeAll()
            memoryGeneration = generation
            return nil
        }
        guard let kept = memory.value(for: key) else { return nil }
        guard FileIdentity(path: url.path) == kept.identity else {
            memory.removeValue(for: key)
            return nil
        }
        return kept.data
    }

    private func keep(_ opened: OpenedImage, for key: ImageKey) {
        let generation = deletions.generation
        if generation != memoryGeneration {
            memory.removeAll()
            memoryGeneration = generation
        }
        memory.insert(opened, cost: opened.data.count, for: key)
    }

    /// Read, authenticate, decrypt and decode one blob. Runs off the actor.
    private static func open(
        request: ValidatedRequest,
        keyMaterial: Data,
        thumbnailPixels: Int?
    ) -> OpenedImage? {
        guard !Task.isCancelled,
              let file = readBoundedRegularFile(at: request.url),
              !Task.isCancelled,
              KeyframeBlobCodec.sha256Hex(of: file.data) == request.digest,
              let plaintext = try? KeyframeBlobCodec.open(blob: file.data, keyMaterial: keyMaterial),
              !Task.isCancelled
        else {
            return nil
        }
        let image = if let thumbnailPixels {
            makeBoundedThumbnail(imageData: plaintext, maxPixelSize: thumbnailPixels)
        } else {
            validatedScreenshot(plaintext)
        }
        return image.map { OpenedImage(data: $0, identity: file.identity) }
    }

    private static func validatedScreenshot(_ data: Data) -> Data? {
        guard !Task.isCancelled, data.count <= maximumBlobBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumScreenshotPixels).contains(width), (1...maximumScreenshotPixels).contains(height)
        else { return nil }
        return data
    }

    private func keyMaterial() async -> Data? {
        if keyResolutionFinished {
            return resolvedKey
        }
        if keyResolution == nil {
            let loader = keyLoader
            let task = Task.detached(priority: .utility) {
                guard !Task.isCancelled,
                      let key = try? loader(),
                      key.count == 32
                else {
                    return nil as Data?
                }
                return key
            }
            keyResolution = (UUID(), task)
        }
        guard let request = keyResolution else { return nil }
        let key = await request.task.value
        // An older waiter may resume after a user has retried a failed read.
        // It must not clear that new flight or replace its cached result.
        if keyResolution?.id == request.id {
            resolvedKey = key
            keyResolutionFinished = true
            keyResolution = nil
        }
        return key
    }

    private struct ValidatedRequest: Sendable {
        let url: URL
        let digest: String
    }

    /// One opened image: a blob's digest at a size (0 is the original).
    private struct ImageKey: Hashable, Sendable {
        let digest: String
        let pixels: Int
    }

    private struct OpenedImage: Sendable {
        let data: Data
        let identity: FileIdentity
    }

    /// The file an image was opened from: a blob replaced, removed or turned
    /// into a link is another file, and its kept image is not served.
    private struct FileIdentity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ metadata: stat) {
            device = Int64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            size = Int64(metadata.st_size)
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        }

        init?(path: String) {
            var metadata = stat()
            guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
            self.init(metadata)
        }
    }

    /// One open in progress and who waits for it. Only the actor touches it.
    private final class Flight: @unchecked Sendable {
        let task: Task<OpenedImage?, Never>
        let generation: UInt64
        var waiters: Set<UUID> = []

        init(task: Task<OpenedImage?, Never>, generation: UInt64) {
            self.task = task
            self.generation = generation
        }
    }

    private static func validatedRequest(url: URL, blobRoot: URL) -> ValidatedRequest? {
        guard url.isFileURL,
              url.pathExtension == "bin"
        else {
            return nil
        }
        let digest = url.deletingPathExtension().lastPathComponent
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else {
            return nil
        }
        let expected = blobRoot
            .appendingPathComponent(digest, isDirectory: false)
            .appendingPathExtension("bin")
            .standardizedFileURL
        guard expected.path == url.standardizedFileURL.path else {
            return nil
        }
        return ValidatedRequest(url: expected, digest: digest)
    }

    private static func readBoundedRegularFile(at url: URL) -> (data: Data, identity: FileIdentity)? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= minimumBlobBytes,
              metadata.st_size <= maximumBlobBytes,
              let data = try? handle.read(upToCount: maximumBlobBytes + 1),
              data.count >= minimumBlobBytes,
              data.count <= maximumBlobBytes,
              data.count == Int(metadata.st_size)
        else {
            return nil
        }
        return (data, FileIdentity(metadata))
    }

    private static func makeBoundedThumbnail(
        imageData: Data,
        maxPixelSize: Int
    ) -> Data? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(
                  imageData as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
            thumbnail.width <= maxPixelSize,
            thumbnail.height <= maxPixelSize,
            !Task.isCancelled
        else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else {
            return nil
        }
        return output as Data
    }

    private static func defaultBrainPath() -> String {
        let supportDir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()
        return (supportDir as NSString).appendingPathComponent("MCI/mci.sqlite")
    }
}
