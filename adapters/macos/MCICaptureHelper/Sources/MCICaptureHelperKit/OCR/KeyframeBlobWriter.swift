// SPDX-License-Identifier: TBD-private
//
// KeyframeBlobWriter — P3.6.5 encrypted keyframe blob writer.
//
// PROTECTED-SET per AGENT_PROTOCOL §5 + ADR-0008 §5 + ADR-0016 §4.8.
//
// Encodes a captured CVPixelBuffer as a downscaled JPEG, encrypts with
// a per-blob key derived via HKDF from the SQLCipher DbKey, writes to
// a content-addressed blob store under
// ~/Library/Application Support/MCI/blobs/<sha256-of-ciphertext>.bin,
// and returns the sha256 hash for the OCREvent.keyframeHash wire field.
//
// CSO invariants:
//   - Blob encryption key derived from SAME DbKey via HKDF — no new
//     key material, no new key custody surface (ADR-0008 §5).
//   - Blob writes happen ONLY on .allow paths gated by cascade-twice
//     (ADR-0016 §4.8). No keyframe ever written for a tombstone.
//   - Blob filename is sha256 of CIPHERTEXT, not plaintext — leaks
//     zero metadata about the original screen content.
//   - Drop-oldest queue matches OCR worker discipline (ADR-0016 §3).

import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation

// MARK: - Blob encoding (stateless, no actor isolation needed)

public enum KeyframeBlobEncoder {

    /// Encode a CVPixelBuffer as a downscaled JPEG, derive a per-blob
    /// encryption key via HKDF, AES-GCM-256 encrypt, and return the
    /// sha256 of the ciphertext alongside the ciphertext itself.
    ///
    /// Returns `nil` on any encoding or encryption failure — the caller
    /// emits the OCREvent with `keyframeHash = [0; 32]` (no blob).
    ///
    /// - Parameters:
    ///   - pixelBuffer: The retained CVPixelBuffer from the SCStream callback.
    ///   - blobKeyMaterial: 32-byte DbKey read from `MCI_DB_KEY_HEX` env var.
    ///   - maxLongEdge: Target maximum dimension for the long edge (default 1280).
    ///   - jpegQuality: JPEG compression quality 0.0–1.0 (default 0.7).
    /// - Returns: `(sha256, ciphertext)` or `nil`.
    public static func encodeAndEncrypt(
        pixelBuffer: CVPixelBuffer,
        blobKeyMaterial: [UInt8],
        maxLongEdge: Int = 1280,
        jpegQuality: Double = 0.7
    ) -> (sha256: [UInt8], ciphertext: Data)? {
        guard blobKeyMaterial.count == 32 else { return nil }

        guard let jpegData = encodeJPEG(
            pixelBuffer: pixelBuffer,
            maxLongEdge: maxLongEdge,
            quality: jpegQuality
        ) else {
            return nil
        }

        guard let ciphertext = encrypt(
            plaintext: jpegData,
            blobKeyMaterial: blobKeyMaterial
        ) else {
            return nil
        }

        let digest = SHA256.hash(data: ciphertext)
        let sha256 = Array(digest)
        return (sha256: sha256, ciphertext: ciphertext)
    }

    // MARK: JPEG encoding

    static func encodeJPEG(
        pixelBuffer: CVPixelBuffer,
        maxLongEdge: Int,
        quality: Double
    ) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ciImage.extent.width
        let height = ciImage.extent.height
        guard width > 0, height > 0 else { return nil }

        let longEdge = max(width, height)
        let scaled: CIImage
        if longEdge > CGFloat(maxLongEdge) {
            let scale = CGFloat(maxLongEdge) / longEdge
            scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = ciImage
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]

        guard let jpegData = context.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: options
        ) else {
            return nil
        }

        return jpegData
    }

    // MARK: Encryption — AES-GCM-256 with HKDF-derived per-blob key

    static func encrypt(
        plaintext: Data,
        blobKeyMaterial: [UInt8]
    ) -> Data? {
        let plaintextDigest = SHA256.hash(data: plaintext)
        let salt = Data(plaintextDigest)

        let ikm = SymmetricKey(data: blobKeyMaterial)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("mci-blob-v1".utf8),
            outputByteCount: 32
        )

        guard let sealedBox = try? AES.GCM.seal(plaintext, using: derivedKey) else {
            return nil
        }

        guard let combined = sealedBox.combined else { return nil }
        return combined
    }

    /// Decrypt a blob. Used in tests to verify round-trip correctness.
    public static func decrypt(
        ciphertext: Data,
        originalPlaintext: Data,
        blobKeyMaterial: [UInt8]
    ) -> Data? {
        let plaintextDigest = SHA256.hash(data: originalPlaintext)
        let salt = Data(plaintextDigest)

        let ikm = SymmetricKey(data: blobKeyMaterial)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("mci-blob-v1".utf8),
            outputByteCount: 32
        )

        guard let sealedBox = try? AES.GCM.SealedBox(combined: ciphertext) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: derivedKey)
    }
}

// MARK: - KeyframeBlobWriter actor (file-write queue with drop-oldest)

/// Fire-and-forget file writer for encrypted keyframe blobs. Manages a
/// bounded queue of pending writes; drops the oldest pending job when
/// at capacity (matches OCR worker discipline per ADR-0016 §3).
///
/// The caller (CascadeTwiceOCREmitter) computes the sha256 + ciphertext
/// synchronously via `KeyframeBlobEncoder.encodeAndEncrypt(...)`, uses
/// the sha256 for the OCREvent wire field immediately, and then
/// submits the file write here as a best-effort operation.
public actor KeyframeBlobWriter {
    /// Default write-queue capacity.
    public static let defaultCapacity: Int = 4

    private let blobDir: URL
    private let capacity: Int
    private var queue: [WriteJob] = []
    private var dropped: UInt64 = 0
    private var consumer: Task<Void, Never>?
    private var awaiter: CheckedContinuation<Void, Never>?
    private var stopped: Bool = false

    private struct WriteJob {
        let sha256Hex: String
        let data: Data
    }

    public init(blobDir: URL, capacity: Int = KeyframeBlobWriter.defaultCapacity) {
        precondition(capacity >= 1, "KeyframeBlobWriter capacity must be >= 1")
        self.blobDir = blobDir
        self.capacity = capacity
    }

    /// Spin up the consumer task. Idempotent.
    public func start() {
        guard consumer == nil, !stopped else { return }
        consumer = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the consumer and discard pending writes. Idempotent.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        consumer?.cancel()
        consumer = nil
        queue.removeAll()
        if let a = awaiter {
            awaiter = nil
            a.resume()
        }
    }

    /// Queue a ciphertext blob for writing. Drop-oldest if at capacity.
    public func queueWrite(sha256: [UInt8], ciphertext: Data) {
        guard !stopped else { return }
        let hex = sha256.map { String(format: "%02x", $0) }.joined()
        if queue.count >= capacity {
            _ = queue.removeFirst()
            dropped &+= 1
        }
        queue.append(WriteJob(sha256Hex: hex, data: ciphertext))
        if let a = awaiter {
            awaiter = nil
            a.resume()
        }
    }

    /// Content-free counter of dropped write jobs.
    public func droppedCount() -> UInt64 { dropped }

    /// Current pending count. Test helper.
    public func pendingCount() -> Int { queue.count }

    /// True iff stop() has been called.
    public func isStopped() -> Bool { stopped }

    // MARK: - Consumer loop

    private func runLoop() async {
        while !Task.isCancelled, !stopped {
            if let job = takeJob() {
                writeFile(job)
            } else {
                await waitForJob()
            }
        }
    }

    private func takeJob() -> WriteJob? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func waitForJob() async {
        if stopped { return }
        await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
            if stopped {
                cc.resume()
                return
            }
            precondition(
                awaiter == nil,
                "KeyframeBlobWriter: multiple consumers — single-consumer invariant violated"
            )
            awaiter = cc
        }
    }

    private func writeFile(_ job: WriteJob) {
        let path = blobDir.appendingPathComponent("\(job.sha256Hex).bin")
        do {
            try job.data.write(to: path, options: .atomic)
        } catch {
            // Best-effort. The OCREvent already carries the hash; a
            // missing blob is graceful degradation (recall UI shows
            // "no keyframe" instead of the image).
        }
    }
}

// MARK: - Hex utilities

/// Decode a hex string into bytes. Returns nil on invalid hex.
public func hexStringToBytes(_ hex: String) -> [UInt8]? {
    let chars = Array(hex)
    guard chars.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let b = UInt8(String(chars[i ... i + 1]), radix: 16) else {
            return nil
        }
        bytes.append(b)
    }
    return bytes
}
