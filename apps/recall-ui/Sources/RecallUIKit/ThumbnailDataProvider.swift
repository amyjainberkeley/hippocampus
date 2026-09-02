// SPDX-License-Identifier: TBD-private

import Darwin
import Foundation
import ImageIO
import MCIKeyframeCodec
import UniformTypeIdentifiers

public protocol ThumbnailDataProviding: Sendable {
    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data?
}

/// Authenticates encrypted keyframe blobs and returns only bounded image data.
/// The provider owns one Keychain resolution per app session and never writes
/// plaintext to disk or exposes full-resolution pixels to SwiftUI state.
public actor ThumbnailDataProvider: ThumbnailDataProviding {
    public static let maximumBlobBytes = 12 * 1024 * 1024
    public static let minimumBlobBytes = 16 + 12 + 16
    public static let maximumThumbnailPixels = 1_024

    public static let shared = ThumbnailDataProvider.production()

    private let blobRoot: URL
    private let keyLoader: @Sendable () throws -> Data
    private var keyResolution: Task<Data?, Never>?
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
        guard !Task.isCancelled,
              let request = Self.validatedRequest(url: url, blobRoot: blobRoot),
              let key = await keyMaterial(),
              !Task.isCancelled
        else {
            return nil
        }

        let requestedPixels = min(
            Self.maximumThumbnailPixels,
            max(1, maxPixelSize)
        )
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
            return Self.makeBoundedThumbnail(
                imageData: plaintext,
                maxPixelSize: requestedPixels
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func keyMaterial() async -> Data? {
        if keyResolutionFinished {
            return resolvedKey
        }
        if let keyResolution {
            let key = await keyResolution.value
            resolvedKey = key
            keyResolutionFinished = true
            self.keyResolution = nil
            return key
        }

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
        keyResolution = task
        let key = await task.value
        resolvedKey = key
        keyResolutionFinished = true
        keyResolution = nil
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
