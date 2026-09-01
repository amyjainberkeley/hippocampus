import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import MCIKeyframeCodec

public enum KeyframeBlobEncoder {
    public static func encodeAndEncrypt(
        pixelBuffer: CVPixelBuffer,
        blobKeyMaterial: Data,
        maxLongEdge: Int = 1280,
        jpegQuality: Double = 0.7
    ) -> KeyframeSealedBlob? {
        guard let jpeg = encodeJPEG(
            pixelBuffer: pixelBuffer,
            maxLongEdge: maxLongEdge,
            quality: jpegQuality
        ) else {
            return nil
        }
        return try? KeyframeBlobCodec.seal(plaintext: jpeg, keyMaterial: blobKeyMaterial)
    }

    static func encodeJPEG(
        pixelBuffer: CVPixelBuffer,
        maxLongEdge: Int,
        quality: Double
    ) -> Data? {
        guard maxLongEdge > 0, (0...1).contains(quality) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }

        let longEdge = max(image.extent.width, image.extent.height)
        let output: CIImage
        if longEdge > CGFloat(maxLongEdge) {
            let scale = CGFloat(maxLongEdge) / longEdge
            output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            output = image
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).jpegRepresentation(
            of: output,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
            ]
        )
    }
}

enum KeyframeBlobStoreError: Error, Equatable {
    case invalidDigest
    case openFailed
    case writeFailed
    case syncFailed
    case publishFailed
    case verificationFailed
}

protocol KeyframeBlobPersisting: Sendable {
    func persist(_ blob: KeyframeSealedBlob) throws
    func remove(_ blob: KeyframeSealedBlob) throws
}

/// Publishes a content-addressed blob only after its bytes are fully synced.
/// The temporary file and final hard link live in the same directory, so the
/// publication step is atomic and can never expose a partial blob.
struct AtomicKeyframeBlobStore: KeyframeBlobPersisting, Sendable {
    let blobDirectory: URL

    func persist(_ blob: KeyframeSealedBlob) throws {
        guard blob.digest.count == 32,
              blob.lowercaseHexDigest.count == 64,
              blob.lowercaseHexDigest == KeyframeBlobCodec.sha256Hex(of: blob.bytes)
        else {
            throw KeyframeBlobStoreError.invalidDigest
        }

        let finalURL = url(for: blob)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            guard try verifiedExistingBlob(at: finalURL, expected: blob) else {
                throw KeyframeBlobStoreError.verificationFailed
            }
            return
        }

        let temporaryURL = blobDirectory.appendingPathComponent(
            ".\(blob.lowercaseHexDigest).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw KeyframeBlobStoreError.openFailed }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists { _ = Darwin.unlink(temporaryURL.path) }
        }

        try writeAll(blob.bytes, to: descriptor)
        try durableSync(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw KeyframeBlobStoreError.syncFailed
        }
        descriptorIsOpen = false

        if Task.isCancelled {
            throw CancellationError()
        }

        if Darwin.link(temporaryURL.path, finalURL.path) != 0 {
            if errno == EEXIST, try verifiedExistingBlob(at: finalURL, expected: blob) {
                return
            }
            throw KeyframeBlobStoreError.publishFailed
        }
        guard Darwin.unlink(temporaryURL.path) == 0 else {
            _ = Darwin.unlink(finalURL.path)
            throw KeyframeBlobStoreError.publishFailed
        }
        temporaryExists = false

        do {
            try syncDirectory()
            guard try verifiedExistingBlob(at: finalURL, expected: blob) else {
                throw KeyframeBlobStoreError.verificationFailed
            }
            if Task.isCancelled {
                try remove(blob)
                throw CancellationError()
            }
        } catch {
            _ = Darwin.unlink(finalURL.path)
            try? syncDirectory()
            throw error
        }
    }

    func remove(_ blob: KeyframeSealedBlob) throws {
        let finalURL = url(for: blob)
        if Darwin.unlink(finalURL.path) != 0, errno != ENOENT {
            throw KeyframeBlobStoreError.publishFailed
        }
        try syncDirectory()
    }

    private func url(for blob: KeyframeSealedBlob) -> URL {
        blobDirectory.appendingPathComponent(
            "\(blob.lowercaseHexDigest).bin",
            isDirectory: false
        )
    }

    private func verifiedExistingBlob(
        at url: URL,
        expected: KeyframeSealedBlob
    ) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expected.bytes.count
        else {
            return false
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        return bytes == expected.bytes
            && KeyframeBlobCodec.sha256Hex(of: bytes) == expected.lowercaseHexDigest
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw KeyframeBlobStoreError.writeFailed
                }
                guard written > 0 else { throw KeyframeBlobStoreError.writeFailed }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func durableSync(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
            throw KeyframeBlobStoreError.syncFailed
        }
    }

    private func syncDirectory() throws {
        let descriptor = Darwin.open(blobDirectory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw KeyframeBlobStoreError.openFailed }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw KeyframeBlobStoreError.syncFailed }
    }
}

public struct KeyframePixelInput: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

public struct KeyframeRetention: Sendable, Equatable {
    public let digest: [UInt8]
    public let lowercaseHexDigest: String

    init(sealedBlob: KeyframeSealedBlob) {
        self.digest = sealedBlob.digest
        self.lowercaseHexDigest = sealedBlob.lowercaseHexDigest
    }
}

public protocol KeyframeRetaining: Sendable {
    func retain(
        input: KeyframePixelInput,
        candidate: KeyframeEvidenceCandidate
    ) async -> KeyframeRetention?

    func confirm(_ retention: KeyframeRetention) async
    func discard(_ retention: KeyframeRetention) async
}

public actor KeyframeRetentionCoordinator: KeyframeRetaining {
    public static let maximumPendingCommits = 4

    typealias Sealer = @Sendable (CVPixelBuffer, Data) -> KeyframeSealedBlob?

    private struct PendingCommit {
        let blob: KeyframeSealedBlob
        let candidate: KeyframeEvidenceCandidate
        let previous: KeyframeEvidenceCandidate?
    }

    private let policy: KeyframePolicy
    private let keyMaterial: Data
    private let store: any KeyframeBlobPersisting
    private let sealer: Sealer
    private var previousRetained: KeyframeEvidenceCandidate?
    private var pendingCommits: [String: PendingCommit] = [:]

    public init(
        blobDirectory: URL,
        keyMaterial: Data,
        policy: KeyframePolicy = .default
    ) {
        precondition(keyMaterial.count == 32)
        self.policy = policy
        self.keyMaterial = keyMaterial
        self.store = AtomicKeyframeBlobStore(blobDirectory: blobDirectory)
        self.sealer = { pixelBuffer, keyMaterial in
            KeyframeBlobEncoder.encodeAndEncrypt(
                pixelBuffer: pixelBuffer,
                blobKeyMaterial: keyMaterial
            )
        }
    }

    init(
        policy: KeyframePolicy,
        keyMaterial: Data,
        store: any KeyframeBlobPersisting,
        sealer: @escaping Sealer
    ) {
        precondition(keyMaterial.count == 32)
        self.policy = policy
        self.keyMaterial = keyMaterial
        self.store = store
        self.sealer = sealer
    }

    public func retain(
        input: KeyframePixelInput,
        candidate: KeyframeEvidenceCandidate
    ) -> KeyframeRetention? {
        guard policy.decision(previous: previousRetained, current: candidate).shouldRetain,
              pendingCommits.count < Self.maximumPendingCommits,
              !Task.isCancelled,
              let blob = sealer(input.pixelBuffer, keyMaterial),
              !Task.isCancelled
        else {
            return nil
        }

        do {
            try store.persist(blob)
        } catch {
            return nil
        }
        guard !Task.isCancelled else {
            try? store.remove(blob)
            return nil
        }

        let retention = KeyframeRetention(sealedBlob: blob)
        pendingCommits[retention.lowercaseHexDigest] = PendingCommit(
            blob: blob,
            candidate: candidate,
            previous: previousRetained
        )
        previousRetained = candidate
        return retention
    }

    public func confirm(_ retention: KeyframeRetention) {
        pendingCommits.removeValue(forKey: retention.lowercaseHexDigest)
    }

    public func discard(_ retention: KeyframeRetention) {
        guard let commit = pendingCommits.removeValue(
            forKey: retention.lowercaseHexDigest
        ) else {
            return
        }
        try? store.remove(commit.blob)
        if previousRetained == commit.candidate {
            previousRetained = commit.previous
        }
    }

    func currentPreviousRetainedForTesting() -> KeyframeEvidenceCandidate? {
        previousRetained
    }
}

public func hexStringToBytes(_ hex: String) -> [UInt8]? {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        output.append(byte)
        index = next
    }
    return output
}
