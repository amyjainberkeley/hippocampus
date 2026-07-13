// SPDX-License-Identifier: TBD-private
//
// KeyframeBlobWriter — P3.6.5 encrypted keyframe blob writer.
//
// PROTECTED-SET per AGENT_PROTOCOL §5 + ADR-0008 §5 + ADR-0016 §4.8.
//
// Encodes a captured CVPixelBuffer as a downscaled JPEG, encrypts with
// a per-blob key derived via HKDF from the SQLCipher DbKey, writes to
// a content-addressed blob store under
// ~/Library/Application Support/MCI/blobs/<sha256-of-blob>.bin,
// and returns the sha256 hash for the OCREvent.keyframeHash wire field.
//
// CSO invariants:
//   - Blob encryption key derived from SAME DbKey via HKDF — no new
//     key material, no new key custody surface (ADR-0008 §5).
//   - Blob writes happen ONLY on .allow paths gated by cascade-twice
//     (ADR-0016 §4.8). No keyframe ever written for a tombstone.
//   - Blob filename is sha256 of the ON-DISK BLOB, not plaintext —
//     leaks zero metadata about the original screen content.
//   - Drop-oldest queue matches OCR worker discipline (ADR-0016 §3).
//
// On-disk blob layout (cycle 8.47 salt fix — closes cycle 8.46 PR #70
// HKDF invariant hole):
//
//     [ 16 bytes: random HKDF salt ] [ AES-GCM sealed box: nonce(12) || ct || tag(16) ]
//
// The salt is generated per-blob from `SecRandomCopyBytes` and
// PREPENDED to the sealed box before the file hits disk. At decrypt
// time the loader reads the file, splits the first 16 bytes as salt,
// runs HKDF to reproduce the per-blob key, and opens the sealed box.
//
// Rationale for the layout change (see cycle 8.46 PR #70 audit): the
// previous implementation used SHA256(plaintext) as the HKDF salt but
// only stored SHA256(ciphertext), so the decrypt path could NOT
// reproduce the salt from what's on disk. Blobs written under the
// old code path are UNRECOVERABLE — their first 16 bytes are part of
// the differently-salted sealed box, so AES-GCM tag verification will
// fail on decrypt (returning nil to the caller, which the UI renders
// as the "no thumbnail" placeholder — same UX as the pre-fix state).
//
// Salt discipline (ADR-0008 §5 clarification): the salt is random per
// blob, not derived from content. This is the textbook HKDF pattern —
// content-hash salts add nothing over a random salt for HKDF (HKDF's
// extract phase already handles non-uniform IKM), and they broke the
// decrypt-side recomputation contract. 16 bytes × 10k keyframes/day
// ≈ 60 MB/year on-disk cost — negligible.

import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import Security

// MARK: - Blob encoding (stateless, no actor isolation needed)

public enum KeyframeBlobEncoder {

    /// Size of the per-blob HKDF salt, in bytes, prepended to the sealed
    /// box in the on-disk blob layout. 16 bytes = 128 bits of salt
    /// entropy, matching the AES-GCM nonce width and the standard HKDF
    /// salt recommendation (RFC 5869 §3.1).
    public static let saltLength: Int = 16

    /// HKDF `info` string (context / application binding). Bumped
    /// alongside any change to the on-disk layout or salt discipline.
    /// Cycle 8.47: bumped to v2 (random salt prefix layout, see the
    /// file header for the reasoning). v1 was the buggy plaintext-hash
    /// salt scheme — its blobs are unrecoverable by construction.
    static let hkdfInfo: Data = Data("mci-blob-v2".utf8)

    /// Encode a CVPixelBuffer as a downscaled JPEG, derive a per-blob
    /// encryption key via HKDF from a fresh random salt, AES-GCM-256
    /// encrypt, and return the sha256 of the ON-DISK blob (salt ||
    /// sealed box) alongside the blob bytes themselves.
    ///
    /// Returns `nil` on any encoding or encryption failure — the caller
    /// emits the OCREvent with `keyframeHash = [0; 32]` (no blob).
    ///
    /// - Parameters:
    ///   - pixelBuffer: The retained CVPixelBuffer from the SCStream callback.
    ///   - blobKeyMaterial: 32-byte DbKey read from `MCI_DB_KEY_HEX` env var.
    ///   - maxLongEdge: Target maximum dimension for the long edge (default 1280).
    ///   - jpegQuality: JPEG compression quality 0.0–1.0 (default 0.7).
    /// - Returns: `(sha256, ciphertext)` where `ciphertext` is the full
    ///   on-disk blob (salt || sealed box) and `sha256` is SHA256 of
    ///   that blob. Returns `nil` on any failure.
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

        guard let blob = encrypt(
            plaintext: jpegData,
            blobKeyMaterial: blobKeyMaterial
        ) else {
            return nil
        }

        let digest = SHA256.hash(data: blob)
        let sha256 = Array(digest)
        return (sha256: sha256, ciphertext: blob)
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

    /// Encrypt `plaintext` with a per-blob key derived via HKDF from a
    /// fresh random 16-byte salt. Returns the ON-DISK BLOB bytes:
    ///
    ///     salt(16) || AES-GCM sealed box(nonce(12) || ct || tag(16))
    ///
    /// The salt is prepended so that `decrypt(blob:blobKeyMaterial:)`
    /// can reproduce the HKDF-derived key from the on-disk bytes
    /// alone (no side channel required). Returns `nil` if the salt
    /// RNG or AES-GCM seal fails.
    static func encrypt(
        plaintext: Data,
        blobKeyMaterial: [UInt8]
    ) -> Data? {
        guard let salt = randomSalt(count: saltLength) else { return nil }

        let ikm = SymmetricKey(data: blobKeyMaterial)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )

        guard let sealedBox = try? AES.GCM.seal(plaintext, using: derivedKey) else {
            return nil
        }
        guard let combined = sealedBox.combined else { return nil }

        var blob = Data(capacity: salt.count + combined.count)
        blob.append(salt)
        blob.append(combined)
        return blob
    }

    /// Decrypt an on-disk blob produced by `encrypt(plaintext:...)`.
    /// Splits the leading 16 bytes as the HKDF salt, reproduces the
    /// per-blob key, and opens the sealed box. Returns `nil` for any
    /// failure — undersized input, unopenable sealed box, AES-GCM tag
    /// verification failure, or (importantly) a pre-cycle-8.47 blob
    /// whose first 16 bytes are NOT a real HKDF salt.
    ///
    /// - Parameters:
    ///   - blob: The full on-disk blob bytes (salt || sealed box).
    ///   - blobKeyMaterial: 32-byte DbKey (same as encrypt).
    public static func decrypt(
        blob: Data,
        blobKeyMaterial: [UInt8]
    ) -> Data? {
        guard blobKeyMaterial.count == 32 else { return nil }
        guard blob.count > saltLength else { return nil }

        let salt = blob.prefix(saltLength)
        let sealed = blob.suffix(from: blob.startIndex + saltLength)

        let ikm = SymmetricKey(data: blobKeyMaterial)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )

        guard let sealedBox = try? AES.GCM.SealedBox(combined: sealed) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: derivedKey)
    }

    // MARK: Random salt (SecRandomCopyBytes — kernel CSPRNG)

    /// Generate `count` cryptographically random bytes via the system
    /// CSPRNG. Returns `nil` if the syscall fails (extremely rare —
    /// documented failure mode is the entropy pool being torn down
    /// during process shutdown).
    static func randomSalt(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBufferPointer { buf in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        return Data(bytes)
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
