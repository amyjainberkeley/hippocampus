import Foundation

public enum OneShotHealthSinkError: Error, Equatable {
    case invalidHealthFrame, alreadyWritten, missingFrame
}

/// In-memory collector for the CLI's one-shot regular-file health fixture.
/// Not an IPC transport or an admission-controlled capture sink. It retains
/// one wire-0x09 health frame with counters only, never an app-identity map.
/// The caller performs explicit filesystem I/O, with no latency guarantee.
public actor OneShotHealthSink: FrameSink {
    private static let payloadBytes = 93
    private var written = false
    private var frame: Data?

    public init() {}

    public func write(_ data: Data) throws {
        guard !written else { throw OneShotHealthSinkError.alreadyWritten }
        guard data.count == minFrameHeaderBytes + Self.payloadBytes else {
            throw OneShotHealthSinkError.invalidHealthFrame
        }
        let valid = data.withUnsafeBytes { bytes in
            bytes[0] == frameMagic && bytes[1] == frameVersion
                && bytes.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian == MessageType.helperHealth.rawValue
                && bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian == Self.payloadBytes
                && bytes[minFrameHeaderBytes + 72] == 0
        }
        guard valid else { throw OneShotHealthSinkError.invalidHealthFrame }
        written = true
        frame = data
    }

    public func takeFrame() throws -> Data {
        guard let frame else { throw OneShotHealthSinkError.missingFrame }
        self.frame = nil
        return frame
    }
}
