import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
import MCIKeyframeCodec

public enum KeyframeBlobEncoder {
    public static let maximumLongEdge = 3840
    public static let maximumJPEGBytes = 10 * 1024 * 1024

    public static func encodeAndEncrypt(
        pixelBuffer: CVPixelBuffer,
        blobKeyMaterial: Data,
        maxLongEdge: Int = maximumLongEdge,
        jpegQuality: Double = 0.88
    ) -> KeyframeSealedBlob? {
        guard let jpeg = encodeJPEG(
            pixelBuffer: pixelBuffer,
            maxLongEdge: maxLongEdge,
            quality: jpegQuality
        ), jpeg.count <= maximumJPEGBytes else {
            return nil
        }
        return try? KeyframeBlobCodec.seal(plaintext: jpeg, keyMaterial: blobKeyMaterial)
    }

    static func encodeJPEG(
        pixelBuffer: CVPixelBuffer,
        maxLongEdge: Int,
        quality: Double
    ) -> Data? {
        guard (1...maximumLongEdge).contains(maxLongEdge), (0...1).contains(quality) else { return nil }
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
    case cleanupFailed
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
            do {
                try remove(blob)
            } catch {
                throw KeyframeBlobStoreError.cleanupFailed
            }
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
            do {
                try remove(blob)
            } catch {
                throw KeyframeBlobStoreError.cleanupFailed
            }
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
    ) async throws -> KeyframeRetention?

    func confirm(_ retention: KeyframeRetention) async
    func discard(_ retention: KeyframeRetention) async throws
}

public actor KeyframeRetentionCoordinator: KeyframeRetaining {
    public static let maximumPendingCommits = 1
    public static let cleanupAttemptLimit = 3

    typealias Sealer = @Sendable (CVPixelBuffer, Data) -> KeyframeSealedBlob?

    private struct PendingCommit {
        let blob: KeyframeSealedBlob
        let candidate: KeyframeEvidenceCandidate
        var cleanupRequired: Bool
    }

    private let policy: KeyframePolicy
    private let keyMaterial: Data
    private let store: any KeyframeBlobPersisting
    private let sealer: Sealer
    private var previousConfirmed: KeyframeEvidenceCandidate?
    private var pendingCommit: PendingCommit?
    /// Where the blobs live, when this coordinator keeps them on disk.
    private nonisolated let blobDirectory: URL?

    public init(
        blobDirectory: URL,
        keyMaterial: Data,
        policy: KeyframePolicy = .default
    ) {
        precondition(keyMaterial.count == 32)
        self.policy = policy
        self.keyMaterial = keyMaterial
        self.store = AtomicKeyframeBlobStore(blobDirectory: blobDirectory)
        self.blobDirectory = blobDirectory
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
        self.blobDirectory = nil
        self.sealer = sealer
    }

    /// Pictures of the windows beside the one in front, sealed with the same
    /// key into the same folder as this coordinator's screenshots (SPEC
    /// 6.4), under the person's own settings. Nil when this coordinator
    /// keeps no folder of its own.
    public nonisolated func makeSidePictureRetainer() -> SidePictureRetainer? {
        guard let blobDirectory else { return nil }
        return SidePictureRetainer(
            blobDirectory: blobDirectory, keyMaterial: keyMaterial,
            environment: LiveSidePictureEnvironment(blobDirectory: blobDirectory))
    }

    public func retain(
        input: KeyframePixelInput,
        candidate: KeyframeEvidenceCandidate
    ) throws -> KeyframeRetention? {
        if let pending = pendingCommit {
            guard pending.cleanupRequired else { return nil }
            try removeWithRetry(pending.blob)
            pendingCommit = nil
        }
        guard policy.decision(previous: previousConfirmed, current: candidate).shouldRetain,
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
            try removeWithRetry(blob)
            return nil
        }

        let retention = KeyframeRetention(sealedBlob: blob)
        pendingCommit = PendingCommit(
            blob: blob,
            candidate: candidate,
            cleanupRequired: false
        )
        return retention
    }

    public func confirm(_ retention: KeyframeRetention) {
        guard let commit = pendingCommit,
              commit.blob.lowercaseHexDigest == retention.lowercaseHexDigest,
              !commit.cleanupRequired
        else {
            return
        }
        previousConfirmed = commit.candidate
        pendingCommit = nil
    }

    public func discard(_ retention: KeyframeRetention) throws {
        guard let commit = pendingCommit,
              commit.blob.lowercaseHexDigest == retention.lowercaseHexDigest
        else {
            return
        }
        do {
            try removeWithRetry(commit.blob)
            pendingCommit = nil
        } catch {
            var cleanupCommit = commit
            cleanupCommit.cleanupRequired = true
            pendingCommit = cleanupCommit
            throw error
        }
    }

    private func removeWithRetry(_ blob: KeyframeSealedBlob) throws {
        for attempt in 1...Self.cleanupAttemptLimit {
            do {
                try store.remove(blob)
                return
            } catch {
                if attempt == Self.cleanupAttemptLimit {
                    throw KeyframeBlobStoreError.cleanupFailed
                }
            }
        }
    }

    func currentPreviousRetainedForTesting() -> KeyframeEvidenceCandidate? {
        previousConfirmed
    }
}

// MARK: - Pictures of the windows beside the one in front (SPEC 6.4)

/// One side window that may get a picture, from the display frame its text
/// was read from: the window, its title and text as keys (never the text),
/// and where its picture lies in that frame.
public struct SidePictureCandidate: Sendable, Equatable {
    public let windowId: CGWindowID
    public let titleKey: Int
    public let text: SideWindowText
    public let plan: WindowPictureCrop.Plan
    public let tsUs: UInt64

    public init(windowId: CGWindowID, title: String?, text: SideWindowText, plan: WindowPictureCrop.Plan,
                tsUs: UInt64) {
        self.windowId = windowId
        self.titleKey = (title ?? "").hashValue
        self.text = text
        self.plan = plan
        self.tsUs = tsUs
    }
}

/// Keeps pictures of side windows: the keep rules (`SidePictureLedger`, the
/// person's settings, the budget, the disk floor, power), then the masked
/// crop sealed with the same AES-GCM key and published with the same
/// atomic, content-addressed store as the window in front's screenshots.
/// Its digest reaches the side window's moment only after the moment's text
/// cleared both privacy passes and the blob is durable
/// (`CascadeTwiceOCREmitter.handleOCRResult`).
public actor SidePictureRetainer {
    public static let cleanupAttemptLimit = 3

    private struct Pending {
        let candidate: SidePictureCandidate
        let dhash: DHash
        let bytes: Int
        let blob: KeyframeSealedBlob
    }

    private let keyMaterial: Data
    private let store: any KeyframeBlobPersisting
    private let environment: any SidePictureEnvironment
    private let now: @Sendable () -> Date
    private var ledger: SidePictureLedger
    private var floor = SidePictureDiskFloor()
    private var pending: [String: Pending] = [:]
    /// Sealed bytes kept since the agent last measured: the budget counts
    /// them until its next usage record does.
    private var keptSince: [(at: Date, bytes: Int)] = []

    public init(blobDirectory: URL, keyMaterial: Data, environment: any SidePictureEnvironment,
                policy: SideWindowPicturePolicy = .default) {
        self.init(keyMaterial: keyMaterial, store: AtomicKeyframeBlobStore(blobDirectory: blobDirectory),
                  environment: environment, policy: policy, now: Date.init)
    }

    init(keyMaterial: Data, store: any KeyframeBlobPersisting, environment: any SidePictureEnvironment,
         policy: SideWindowPicturePolicy, now: @escaping @Sendable () -> Date) {
        precondition(keyMaterial.count == 32)
        self.keyMaterial = keyMaterial
        self.store = store
        self.environment = environment
        self.now = now
        self.ledger = SidePictureLedger(policy: policy)
    }

    /// Why the last candidate was not kept, for tests and the trace.
    private(set) var lastSkip: SidePictureSkip?

    /// Seal and publish a picture of `candidate` from `frame`, or nil when a
    /// rule says no. Nothing is kept on disk unless this returns a retention.
    public func retain(frame: KeyframePixelInput, candidate: SidePictureCandidate) throws -> KeyframeRetention? {
        lastSkip = nil
        if let skip = skipBeforePicture(candidate) {
            lastSkip = skip
            OCRTrace.emit("side-picture", "decision=skip reason=\(skip.rawValue)")
            return nil
        }
        // The picture's work counts toward the shared read budget (SPEC 6.9).
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            CaptureReadBudget.shared.recordExtraWork(
                tookUs: (DispatchTime.now().uptimeNanoseconds &- started) / 1_000)
        }
        guard !Task.isCancelled,
              let picture = WindowPictureCrop.render(frame.pixelBuffer, plan: candidate.plan)
        else { return nil }
        if picture.nearlyOneColour {
            lastSkip = .nearlyOneColour
            OCRTrace.emit("side-picture", "decision=skip reason=\(SidePictureSkip.nearlyOneColour.rawValue)")
            return nil
        }
        if let skip = ledger.admitsPicture(windowId: candidate.windowId, dhash: picture.dhash, nowUs: candidate.tsUs) {
            lastSkip = skip
            OCRTrace.emit("side-picture", "decision=skip reason=\(skip.rawValue)")
            return nil
        }
        guard let jpeg = WindowPictureCrop.jpeg(picture.image), jpeg.count <= KeyframeBlobEncoder.maximumJPEGBytes,
              let blob = try? KeyframeBlobCodec.seal(plaintext: jpeg, keyMaterial: keyMaterial),
              !Task.isCancelled
        else { return nil }
        do {
            try store.persist(blob)
        } catch {
            return nil
        }
        guard !Task.isCancelled else {
            try removeWithRetry(blob)
            return nil
        }
        pending[blob.lowercaseHexDigest] = Pending(candidate: candidate, dhash: picture.dhash,
                                                   bytes: blob.bytes.count, blob: blob)
        // Content-free: the size only.
        OCRTrace.emit("side-picture", "decision=kept bytes=\(blob.bytes.count)")
        return KeyframeRetention(sealedBlob: blob)
    }

    /// The moment carrying the picture was written: it counts from now on.
    public func confirm(_ retention: KeyframeRetention) {
        guard let kept = pending.removeValue(forKey: retention.lowercaseHexDigest) else { return }
        ledger.record(windowId: kept.candidate.windowId, titleKey: kept.candidate.titleKey,
                      text: kept.candidate.text, dhash: kept.dhash, nowUs: kept.candidate.tsUs)
        keptSince.append((now(), kept.bytes))
    }

    /// The moment was not written: the picture goes from disk.
    public func discard(_ retention: KeyframeRetention) throws {
        guard let kept = pending[retention.lowercaseHexDigest] else { return }
        try removeWithRetry(kept.blob)
        pending.removeValue(forKey: retention.lowercaseHexDigest)
    }

    /// Rules 2, 6 (counts and timing), 7 and 8, before any pixel is touched.
    private func skipBeforePicture(_ candidate: SidePictureCandidate) -> SidePictureSkip? {
        let settings = environment.settings()
        guard settings.enabled else { return .off }
        let power = environment.power()
        if power.mode == .lowPower { return .lowPower }
        if !CapturePower.allowsSidePictures(mode: power.mode, batteryPercent: power.batteryPercent) {
            return .lowBattery
        }
        let disk = environment.disk()
        if floor.update(availableBytes: disk.availableBytes) { return .lowDisk }
        if usedBytes() >= settings.budgetBytes(diskTotalBytes: disk.totalBytes) { return .budgetFull }
        return ledger.admits(windowId: candidate.windowId, titleKey: candidate.titleKey, text: candidate.text,
                             nowUs: candidate.tsUs)
    }

    /// The agent's last measure plus what was kept since.
    private func usedBytes() -> Int64 {
        let recorded = environment.recordedSideBytes()
        if let measuredAt = recorded?.measuredAt {
            keptSince.removeAll { $0.at <= measuredAt }
        }
        let since = keptSince.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        return (recorded?.bytes ?? 0) + since
    }

    private func removeWithRetry(_ blob: KeyframeSealedBlob) throws {
        for attempt in 1...Self.cleanupAttemptLimit {
            do {
                try store.remove(blob)
                return
            } catch {
                if attempt == Self.cleanupAttemptLimit { throw KeyframeBlobStoreError.cleanupFailed }
            }
        }
    }

    func ledgerForTesting() -> SidePictureLedger { ledger }
}

/// One side window's retention, in the shape the cascade-twice emitter
/// retains with, so the same path that keeps the window in front's
/// screenshot keeps this one: after both privacy passes, durable before its
/// digest is written, removed again if the moment is not.
struct SidePictureRetention: KeyframeRetaining {
    let retainer: SidePictureRetainer
    let candidate: SidePictureCandidate

    /// What the emitter passes along; a side picture's own rules decide.
    var evidence: KeyframeEvidenceCandidate {
        KeyframeEvidenceCandidate(captureOrdinal: 0, focusedWindowId: candidate.windowId,
                                  dhash: DHash(bits: 0), monotonicNanoseconds: 0)
    }

    func retain(input: KeyframePixelInput, candidate _: KeyframeEvidenceCandidate) async throws -> KeyframeRetention? {
        try await retainer.retain(frame: input, candidate: candidate)
    }

    func confirm(_ retention: KeyframeRetention) async {
        await retainer.confirm(retention)
    }

    func discard(_ retention: KeyframeRetention) async throws {
        try await retainer.discard(retention)
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
