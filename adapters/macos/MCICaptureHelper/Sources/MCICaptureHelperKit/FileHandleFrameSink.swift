// SPDX-License-Identifier: TBD-private
//
// FileHandleFrameSink — concrete FrameSink backed by a Foundation
// FileHandle. Production wraps the AF_UNIX socket the Rust core
// passed to the helper at launch (cycle 3 wires this); tests wrap
// a Pipe's writing end.

import Foundation
import Darwin
import ObjectiveC

public enum FrameTransportError: String, Error, Sendable, CustomStringConvertible, LocalizedError {
    case unavailable, unsupportedTransport, frameTooLarge, queueFull, timedOut, writeFailed, interrupted, terminal, cancelled
    public var description: String { "capture_transport_\(rawValue)" }
    public var errorDescription: String? { description }
}

/// A bounded, whole-frame transport for a FIFO or AF_UNIX stream socket.
/// All writers of the supplied handle must use this sink: O_NONBLOCK is shared
/// by duplicated descriptors. The owned CLOEXEC duplicate remains open until
/// the handle and its sinks are released, or a terminal transport failure.
public struct FileHandleFrameSink: AdmissionControlledFrameSink {
    private static let creationLock = NSLock()
    nonisolated(unsafe) private static var associationKey: UInt8 = 0
    private let handle: FileHandle
    private let transport: BoundedFrameTransport

    public init(handle: FileHandle) {
        self.handle = handle
        transport = Self.creationLock.withLock {
            if let existing = objc_getAssociatedObject(handle, &Self.associationKey) as? BoundedFrameTransport {
                return existing
            }
            let transport = BoundedFrameTransport(descriptor: handle.fileDescriptor)
            // The value never retains the key. Metadata lasts exactly as long as
            // this FileHandle, including when every previous sink was dropped.
            objc_setAssociatedObject(handle, &Self.associationKey, transport, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return transport
        }
    }

    public func write(_ data: Data) async throws {
        guard try await transport.write(data, admitted: { true }) else { throw FrameTransportError.cancelled }
    }

    public func writeIfCurrent(_ data: Data, admitted: @escaping @Sendable () -> Bool) async throws -> Bool {
        try await transport.write(data, admitted: admitted)
    }
}

private final class BoundedFrameTransport: @unchecked Sendable {
    // Rust's MAX_FRAME_PAYLOAD_BYTES plus the fixed wire header. No frame copy
    // or per-write task is created; at most eight caller-owned buffers wait here.
    private static let maximumFrameBytes = (1 << 20) + 16
    private static let maximumWriters = 8
    private static let deadlineNs: UInt64 = 1_000_000_000
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var failure: FrameTransportError?
    private var writers = 0
    private var writing = false

    init(descriptor original: Int32) {
        let owned = fcntl(original, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { failure = .unavailable; return }
        var info = stat()
        guard fstat(owned, &info) == 0 else {
            close(owned)
            failure = .unavailable
            return
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFSOCK {
            var address = sockaddr_storage()
            var addressSize = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(owned, $0, &addressSize) }
            }
            var socketType: Int32 = 0
            var typeSize = socklen_t(MemoryLayout.size(ofValue: socketType))
            guard result == 0, address.ss_family == sa_family_t(AF_UNIX),
                  getsockopt(owned, SOL_SOCKET, SO_TYPE, &socketType, &typeSize) == 0,
                  socketType == SOCK_STREAM else {
                close(owned)
                failure = .unsupportedTransport
                return
            }
        } else if kind != S_IFIFO {
            close(owned)
            failure = .unsupportedTransport
            return
        }
        let flags = fcntl(owned, F_GETFL)
        guard flags >= 0, fcntl(owned, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(owned, F_SETNOSIGPIPE, 1) == 0 else {
            close(owned)
            failure = .unavailable
            return
        }
        descriptor = owned
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    func write(_ data: Data, admitted: @Sendable () -> Bool) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.deadlineNs
        guard data.count <= Self.maximumFrameBytes else { throw FrameTransportError.frameTooLarge }
        guard !Task.isCancelled, admitted() else { return false }
        try reserve()
        var ownsWriter = false
        defer { release(ownsWriter: ownsWriter) }
        while true {
            guard !Task.isCancelled, admitted() else { return false }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw FrameTransportError.timedOut }
            if try beginWriting() { ownsWriter = true; break }
            do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return false }
        }
        return try data.withUnsafeBytes { bytes in
            try writeBytes(bytes, deadline: deadline, admitted: admitted)
        }
    }

    private func reserve() throws {
        try stateLock.withLock {
            if let failure { throw failure }
            guard writers < Self.maximumWriters else { throw FrameTransportError.queueFull }
            writers += 1
        }
    }

    private func beginWriting() throws -> Bool {
        try stateLock.withLock {
            if let failure { throw failure }
            guard !writing else { return false }
            writing = true
            return true
        }
    }

    private func release(ownsWriter: Bool) {
        stateLock.withLock {
            writers -= 1
            if ownsWriter { writing = false }
        }
    }

    private func retire() {
        stateLock.withLock {
            failure = .terminal
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
        }
    }

    private func writeBytes(_ bytes: UnsafeRawBufferPointer, deadline: UInt64,
                            admitted: @Sendable () -> Bool) throws -> Bool {
        var offset = 0
        while offset < bytes.count {
            // In particular, recheck after waiting for either the writer slot or
            // POLLOUT. A revoked frame with no emitted bytes is safely skipped.
            guard !Task.isCancelled, admitted() else {
                if offset == 0 { return false }
                retire()
                throw FrameTransportError.interrupted
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                if offset > 0 { retire() }
                throw FrameTransportError.timedOut
            }
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                retire()
                throw FrameTransportError.writeFailed
            }
            var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let remainingMs = (deadline - now + 999_999) / 1_000_000
            let result = poll(&readiness, 1, Int32(min(20, remainingMs)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0, readiness.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                retire()
                throw FrameTransportError.writeFailed
            }
        }
        return true
    }
}
