import Foundation
import Darwin
import XCTest
@testable import MCICaptureHelperKit

final class ActivityDeliveryTests: XCTestCase {
    func testConditionalSinkRejectsInvalidatedGeneration() async throws {
        let endpoints = DeliveryEndpoints.pipe()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let wrote = try await sink.writeIfCurrent(Data([1, 2]), admitted: { false })
        XCTAssertFalse(wrote)
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
    }

    func testConditionalSinkRejectsCancelledTaskEvenIfGenerationStillCurrent() async throws {
        let endpoints = DeliveryEndpoints.pipe()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let ready = DeliveryLatch()
        let task = Task {
            await ready.wait()
            return try await sink.writeIfCurrent(Data([1, 2]), admitted: { true })
        }
        task.cancel()
        await ready.release()
        let wrote = try await task.value
        XCTAssertFalse(wrote)
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
    }

    func testCurrentGenerationWritesExactlyOneFrame() async throws {
        let endpoints = DeliveryEndpoints.pipe()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let wrote = try await sink.writeIfCurrent(Data([1, 2]), admitted: { true })
        XCTAssertTrue(wrote)
        XCTAssertEqual(endpoints.read(count: 2, timeout: 1), Data([1, 2]))
    }

    func testStalledReaderFailsWithinDeadlineAndPoisonsSiblingAfterPartialFrame() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let first = FileHandleFrameSink(handle: endpoints.writer)
        let sibling = FileHandleFrameSink(handle: endpoints.writer)
        let frame = Data(repeating: 0x41, count: 256 * 1024)
        // Rescue the old blocking implementation so a red test cannot hang XCTest.
        let rescue = Task.detached {
            try await Task.sleep(for: .seconds(2))
            return endpoints.readAvailable(until: .now() + 0.5)
        }
        let started = ContinuousClock.now
        var failed = false
        do { try await first.write(frame) } catch {
            failed = true
            XCTAssertTrue(String(describing: error).hasPrefix("capture_transport_"))
        }
        let elapsed = started.duration(to: .now)
        let prefix = try await rescue.value
        XCTAssertTrue(failed, "A stalled reader must produce an explicit transport failure")
        XCTAssertLessThan(elapsed, .milliseconds(1500))
        XCTAssertGreaterThan(prefix.count, 0)
        XCTAssertLessThan(prefix.count, frame.count)
        do {
            try await sibling.write(Data([0x42]))
            XCTFail("A partial frame failure must retire every sink sharing the transport")
        } catch {
            XCTAssertTrue(String(describing: error).hasPrefix("capture_transport_"))
        }
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
        // Retiring the original sink values must not erase failure metadata.
        do {
            try await FileHandleFrameSink(handle: endpoints.writer).write(Data([0x43]))
            XCTFail("A new sink value must see the same terminal transport")
        } catch {}
    }

    func testConcurrentLargeFramesFromSeparateSinkValuesRemainIntact() async throws {
        for endpoints in [try DeliveryEndpoints.socketPair(), DeliveryEndpoints.pipe()] {
            let first = FileHandleFrameSink(handle: endpoints.writer)
            let second = FileHandleFrameSink(handle: endpoints.writer)
            let a = Data(repeating: 0x41, count: 200 * 1024)
            let b = Data(repeating: 0x42, count: 200 * 1024)
            let read = Task.detached { endpoints.read(count: a.count + b.count, timeout: 3) }
            async let writeA: Void = first.write(a)
            async let writeB: Void = second.write(b)
            try await writeA
            try await writeB
            let received = await read.value
            XCTAssertTrue(received == a + b || received == b + a, "Whole frames must not interleave")
        }
    }

    func testInvalidationWhileWaitingForWriterSkipsEveryByte() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let first = FileHandleFrameSink(handle: endpoints.writer)
        let second = FileHandleFrameSink(handle: endpoints.writer)
        let frame = Data(repeating: 0x41, count: 200 * 1024)
        let writing = Task { try await first.write(frame) }
        let prefix = await Task.detached { endpoints.read(count: 1, timeout: 1) }.value
        XCTAssertEqual(prefix, Data([0x41]))
        let admission = DeliveryAdmission()
        let waiting = Task { try await second.writeIfCurrent(Data([0x42]), admitted: { admission.current }) }
        // Ensure the second writer gets an opportunity to contend for admission.
        try await Task.sleep(for: .milliseconds(40))
        admission.invalidate()
        let read = Task.detached { endpoints.read(count: frame.count - 1, timeout: 2) }
        try await writing.value
        let wrote = try await waiting.value
        XCTAssertFalse(wrote)
        let remainder = await read.value
        XCTAssertEqual(prefix + remainder, frame)
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
    }

    func testCancellationBeforeFirstByteWhileSocketFullSkipsFrame() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let filled = endpoints.fillWriter()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let writing = Task { try await sink.writeIfCurrent(Data([0x42]), admitted: { true }) }
        try await Task.sleep(for: .milliseconds(40))
        writing.cancel()
        // Drain only after cancellation, so a stale pre-poll check cannot pass.
        let received = endpoints.read(count: filled, timeout: 1)
        XCTAssertEqual(received.count, filled)
        let wrote = try await writing.value
        XCTAssertFalse(wrote)
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
        try await sink.write(Data([0x43]))
        XCTAssertEqual(endpoints.read(count: 1, timeout: 1), Data([0x43]))
    }

    func testOversizedFrameIsRejectedWithoutTouchingTransport() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let rescue = Task.detached {
            try await Task.sleep(for: .seconds(2))
            return endpoints.readAvailable(until: .now() + 0.5)
        }
        do {
            try await sink.write(Data(repeating: 0x41, count: (1 << 20) + 17))
            XCTFail("Reject frames above the wire payload cap plus header")
        } catch {}
        let received = try await rescue.value
        XCTAssertTrue(received.isEmpty)
        try await sink.write(Data([0x42]))
        XCTAssertEqual(endpoints.read(count: 1, timeout: 1), Data([0x42]))
    }

    func testStalledPipeAlsoHasBoundedDelivery() async throws {
        let endpoints = DeliveryEndpoints.pipe()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let started = ContinuousClock.now
        do {
            try await sink.write(Data(repeating: 0x41, count: 200 * 1024))
            XCTFail("A pipe with no reader progress must time out")
        } catch { XCTAssertEqual(error as? FrameTransportError, .timedOut) }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(1500))
        let prefix = endpoints.readAvailable(until: .now() + 0.05)
        XCTAssertGreaterThan(prefix.count, 0)
        XCTAssertLessThan(prefix.count, 200 * 1024)
    }

    func testOutstandingAdmissionIsBoundedAndZeroByteTimeoutDoesNotPoisonTransport() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let filled = endpoints.fillWriter()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let started = ContinuousClock.now
        let failures = await withTaskGroup(of: FrameTransportError?.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    do { try await sink.write(Data([0x42])); return nil }
                    catch { return error as? FrameTransportError }
                }
            }
            var failures: [FrameTransportError?] = []
            for await result in group { failures.append(result) }
            return failures
        }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(1500))
        XCTAssertEqual(failures.count, 24)
        XCTAssertGreaterThanOrEqual(failures.filter { $0 == .queueFull }.count, 16)
        XCTAssertTrue(failures.allSatisfy { $0 == .queueFull || $0 == .timedOut })
        XCTAssertEqual(endpoints.read(count: filled, timeout: 1).count, filled)
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
        try await sink.write(Data([0x43]))
        XCTAssertEqual(endpoints.read(count: 1, timeout: 1), Data([0x43]))
    }

    func testCancellationAfterPartialFrameMakesAllLaterWritesTerminal() async throws {
        let endpoints = try DeliveryEndpoints.socketPair()
        let sink = FileHandleFrameSink(handle: endpoints.writer)
        let writing = Task { try await sink.write(Data(repeating: 0x41, count: 200 * 1024)) }
        let prefix = await Task.detached { endpoints.read(count: 1, timeout: 1) }.value
        XCTAssertEqual(prefix, Data([0x41]))
        writing.cancel()
        do { try await writing.value; XCTFail("Do not silently complete a cancelled partial frame") }
        catch { XCTAssertEqual(error as? FrameTransportError, .interrupted) }
        let rest = endpoints.readAvailable(until: .now() + 0.05)
        XCTAssertLessThan(rest.count + prefix.count, 200 * 1024)
        do {
            try await FileHandleFrameSink(handle: endpoints.writer).write(Data([0x42]))
            XCTFail("The next frame cannot follow a partial frame")
        } catch { XCTAssertEqual(error as? FrameTransportError, .terminal) }
        XCTAssertTrue(endpoints.readAvailable(until: .now() + 0.05).isEmpty)
    }

    func testClosedPipeAndSocketPeersReturnContentFreeErrorsWithoutSIGPIPE() async throws {
        for endpoints in [try DeliveryEndpoints.socketPair(), DeliveryEndpoints.pipe()] {
            let sink = FileHandleFrameSink(handle: endpoints.writer)
            try endpoints.reader.close()
            do { try await sink.write(Data([0x41])); XCTFail("A closed peer must fail") }
            catch { XCTAssertEqual(error as? FrameTransportError, .writeFailed) }
            do { try await sink.write(Data([0x42])); XCTFail("A failed peer stays terminal") }
            catch { XCTAssertEqual(error as? FrameTransportError, .terminal) }
        }
    }

    func testDescriptorReuseCannotRedirectWritesOrInheritTerminalState() async throws {
        let old = try DeliveryEndpoints.socketPair()
        let oldNumber = old.writer.fileDescriptor
        let oldSink = FileHandleFrameSink(handle: old.writer)
        let fresh = try DeliveryEndpoints.socketPair()
        try old.writer.close()
        XCTAssertEqual(dup2(fresh.writer.fileDescriptor, oldNumber), oldNumber)
        let replacement = FileHandle(fileDescriptor: oldNumber, closeOnDealloc: true)
        let freshSink = FileHandleFrameSink(handle: replacement)
        try await oldSink.write(Data([0x41]))
        XCTAssertEqual(old.read(count: 1, timeout: 1), Data([0x41]))
        XCTAssertTrue(fresh.readAvailable(until: .now() + 0.05).isEmpty)
        try old.reader.close()
        do { try await oldSink.write(Data([0x42])); XCTFail("The old transport must fail") } catch {}
        try await freshSink.write(Data([0x43]))
        XCTAssertEqual(fresh.read(count: 1, timeout: 1), Data([0x43]))
    }

    func testOwnedDescriptorAndMetadataReleaseWithHandleAndSinks() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw DeliveryTestError.setup }
        defer { close(descriptors[0]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var handle: FileHandle? = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        var sink: FileHandleFrameSink? = FileHandleFrameSink(handle: handle!)
        XCTAssertNotNil(sink)
        handle = nil
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(descriptors[0], &byte, 1), -1)
        XCTAssertEqual(errno, EAGAIN, "The sink still owns the writer")
        sink = nil
        XCTAssertEqual(Darwin.read(descriptors[0], &byte, 1), 0, "No duplicate descriptor may leak past ownership")
    }

    func testUnsupportedTransportFailsBeforeIO() async throws {
        let descriptor = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeliveryTestError.setup }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let sink = FileHandleFrameSink(handle: handle)
        do { try await sink.write(Data([0x41])); XCTFail("Only pipes and AF_UNIX streams are supported") }
        catch { XCTAssertEqual(error as? FrameTransportError, .unsupportedTransport) }
    }
}

private final class DeliveryAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var current: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}

private final class DeliveryEndpoints: @unchecked Sendable {
    let writer: FileHandle
    let reader: FileHandle

    init(writer: FileHandle, reader: FileHandle) {
        self.writer = writer
        self.reader = reader
        let flags = fcntl(reader.fileDescriptor, F_GETFL)
        _ = fcntl(reader.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    static func socketPair() throws -> DeliveryEndpoints {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw DeliveryTestError.setup }
        var size: Int32 = 4096
        _ = setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size)))
        return DeliveryEndpoints(writer: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
                                 reader: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }

    static func pipe() -> DeliveryEndpoints {
        let pipe = Pipe()
        return DeliveryEndpoints(writer: pipe.fileHandleForWriting, reader: pipe.fileHandleForReading)
    }

    func fillWriter() -> Int {
        let descriptor = writer.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        let bytes = [UInt8](repeating: 0x41, count: 4096)
        var total = 0
        while true {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { return total }
            total += count
        }
    }

    func read(count: Int, timeout: Double) -> Data {
        readAvailable(until: .now() + timeout, maximum: count)
    }

    func readAvailable(until deadline: DispatchTime, maximum: Int = 2 * 1024 * 1024) -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while DispatchTime.now() < deadline && result.count < maximum {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(reader.fileDescriptor, $0.baseAddress, min($0.count, maximum - result.count))
            }
            if count > 0 { result.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { break }
            else if errno == EAGAIN || errno == EINTR {
                var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 5)
            } else { break }
        }
        return result
    }
}

private enum DeliveryTestError: Error { case setup }

private actor DeliveryLatch {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
