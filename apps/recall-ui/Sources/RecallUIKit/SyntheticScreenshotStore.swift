#if DEBUG
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCIKeyframeCodec

/// Synthetic screenshots sealed the way the capture helper seals them, in a
/// private temporary folder, for the off-screen renderer. Nothing here is
/// real: the images are drawn, the key is a constant, and the folder goes
/// when the renderer is done. The window opens them through the same
/// `ThumbnailDataProvider` (authentication, decryption, downsizing in memory)
/// it uses for the person's screenshots.
public final class SyntheticScreenshotStore: @unchecked Sendable {
    public let root: URL
    private let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 11) })

    public init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-synthetic-screens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Seal one drawn screenshot (JPEG or PNG) and keep it as the helper
    /// does, `<root>/<sha256 of the sealed bytes>.bin`. Returns its path.
    public func seal(_ image: Data) throws -> String {
        let sealed = try KeyframeBlobCodec.seal(plaintext: image, keyMaterial: key)
        let url = root.appendingPathComponent(sealed.lowercaseHexDigest).appendingPathExtension("bin")
        try sealed.bytes.write(to: url)
        return url.path
    }

    /// A path in this folder that names no blob: a screenshot that is gone.
    public var missingPath: String {
        root.appendingPathComponent(String(repeating: "0f", count: 32)).appendingPathExtension("bin").path
    }

    /// The window's provider, opening these blobs with this store's key.
    public func provider() -> ThumbnailDataProvider {
        let key = key
        return ThumbnailDataProvider(blobRoot: root, deletions: MemoryDeletionSignal(center: NotificationCenter())) {
            key
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
