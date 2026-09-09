import Darwin
import Foundation

/// Content-free proof receipts remain readable when Launch Services owns stdout.
final class ScreenProofReceiptSink {
    private let handle: FileHandle

    init(url: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hippocampus-screen-proof-receipt-\(UUID().uuidString).jsonl"
    )) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ line: Data) throws {
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}
