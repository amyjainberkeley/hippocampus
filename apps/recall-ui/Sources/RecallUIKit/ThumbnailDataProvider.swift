// SPDX-License-Identifier: TBD-private

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
public actor ThumbnailDataProvider: ThumbnailDataProviding {
    public static let maximumBlobBytes = 12 * 1024 * 1024
    public static let minimumBlobBytes = 16 + 12 + 16
    public static let maximumThumbnailPixels = 1_024
    public static let maximumScreenshotPixels = 3_840

    public static let shared = ThumbnailDataProvider.production()

    private let blobRoot: URL
    private let keyLoader: @Sendable () throws -> Data
    private var keyResolution: (id: UUID, task: Task<Data?, Never>)?
    private var resolvedKey: Data?
    private var keyResolutionFinished = false

    public init(
        blobRoot: URL,
        keyLoader: @escaping @Sendable () throws -> Data
    ) {
        self.blobRoot = blobRoot.standardizedFileURL
        self.keyLoader = keyLoader
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

    private func imageData(for url: URL, thumbnailPixels: Int?) async -> Data? {
        guard !Task.isCancelled,
              let request = Self.validatedRequest(url: url, blobRoot: blobRoot),
              let key = await keyMaterial(),
              !Task.isCancelled
        else {
            return nil
        }

        let worker = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let blob = Self.readBoundedRegularFile(at: request.url),
                  !Task.isCancelled,
                  KeyframeBlobCodec.sha256Hex(of: blob) == request.digest,
                  let plaintext = try? KeyframeBlobCodec.open(
                      blob: blob,
                      keyMaterial: key
                  ),
                  !Task.isCancelled
            else {
                return nil as Data?
            }
            if let thumbnailPixels {
                return Self.makeBoundedThumbnail(imageData: plaintext, maxPixelSize: thumbnailPixels)
            }
            return Self.validatedScreenshot(plaintext)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
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

    private static func readBoundedRegularFile(at url: URL) -> Data? {
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
        return data
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
