import Darwin
import Foundation

/// A warm `hippocampus-ocr --serve` child shared by every frame.
///
/// Starting the worker per frame reloaded the models each time: 2–6 s warm and
/// 20–44 s cold (first-launch library scanning), so frames timed out and their
/// text was lost. The persistent worker loads once, announces readiness, then
/// answers each BMP with one JSON line.
///
/// A frame that misses its deadline does not kill the worker: a cold worker
/// that is still loading would otherwise be restarted forever. Its late reply
/// is owed and drained before the next frame is sent. A worker silent for
/// `maximumSilence`, one whose reply exceeds the size limit, or one that exits
/// is discarded, and the next frame starts a fresh one. Callers are serialized
/// by the OCR execution lane; `stop()` may arrive from any thread.
final class PaddleOCRServer: @unchecked Sendable {
    enum Outcome: Equatable {
        case reply(Data)
        case timedOut
        case failed
    }

    static let maximumReplyBytes = 1_048_576
    static let maximumSilence: DispatchTimeInterval = .seconds(120)

    private let executableURL: URL
    private let lock = NSLock()
    private var stopped = false
    private var session: Session?

    private final class Session {
        let process: Process
        let input: FileHandle
        let outputPipe: Pipe
        var output: Int32 { outputPipe.fileHandleForReading.fileDescriptor }
        var buffer = Data()
        var ready = false
        /// Replies still due for frames that already timed out.
        var owed = 0
        var lastProgress = DispatchTime.now()

        init(process: Process, input: FileHandle, outputPipe: Pipe) {
            self.process = process
            self.input = input
            self.outputPipe = outputPipe
        }

        /// Never waits: Foundation reaps the child, and waiting on a worker
        /// that already exited could block the capture path indefinitely.
        func kill() {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? input.close()
        }
    }

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Start the worker now so its models load before the first frame.
    func prewarm() {
        _ = currentSession()
    }

    func stop() {
        let retired: Session? = lock.withLock {
            stopped = true
            defer { session = nil }
            return session
        }
        retired?.kill()
    }

    func recognize(bitmap: Data, deadline: DispatchTime) -> Outcome {
        guard let session = currentSession() else { return .failed }
        if !session.ready {
            switch readLine(session, deadline: deadline) {
            case .line(let line):
                guard Self.isReadyLine(line) else { return discard(session) }
                session.ready = true
            case .timeout: return waitTimedOut(session)
            case .closed: return discard(session)
            }
        }
        while session.owed > 0 {
            switch readLine(session, deadline: deadline) {
            case .line: session.owed -= 1
            case .timeout: return waitTimedOut(session)
            case .closed: return discard(session)
            }
        }
        guard write(bitmap, to: session, deadline: deadline) else { return discard(session) }
        switch readLine(session, deadline: deadline) {
        case .line(let line): return .reply(line)
        case .timeout:
            session.owed += 1
            return waitTimedOut(session)
        case .closed: return discard(session)
        }
    }

    // MARK: - Session lifetime

    private func currentSession() -> Session? {
        var exited: Session?
        defer { exited?.kill() }
        return lock.withLock {
            guard !stopped else { return nil }
            if let session, session.process.isRunning { return session }
            exited = session
            session = nil
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--serve"]
            // A child inherits the launching queue's QoS. From the OCR lane
            // (.utility) the worker ran throttled on efficiency cores: 23-30 s
            // for a frame it reads in about one second at this QoS.
            process.qualityOfService = .userInitiated
            // Never inherit provider credentials, Python paths, or user model overrides.
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                                   "OMP_NUM_THREADS": "4", "OPENBLAS_NUM_THREADS": "1"]
            let inputPipe = Pipe(), outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            // A dead worker must not deliver SIGPIPE to the capture helper.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let created = Session(process: process, input: inputPipe.fileHandleForWriting,
                                  outputPipe: outputPipe)
            session = created
            return created
        }
    }

    private func discard(_ candidate: Session) -> Outcome {
        let retired: Session? = lock.withLock {
            guard session === candidate else { return nil }
            session = nil
            return candidate
        }
        retired?.kill()
        return .failed
    }

    /// A wait that ran out of time keeps the worker unless it has said nothing
    /// for `maximumSilence`, in which case it is presumed hung.
    private func waitTimedOut(_ session: Session) -> Outcome {
        if DispatchTime.now() > session.lastProgress + Self.maximumSilence {
            _ = discard(session)
        }
        return .timedOut
    }

    static func isReadyLine(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        return object["version"] as? Int == 1 && object["ready"] as? Bool == true
    }

    // MARK: - Pipe I/O

    private enum Read { case line(Data), timeout, closed }

    private func readLine(_ session: Session, deadline: DispatchTime) -> Read {
        while true {
            if let newline = session.buffer.firstIndex(of: 0x0A) {
                let line = session.buffer[session.buffer.startIndex..<newline]
                session.buffer.removeSubrange(session.buffer.startIndex...newline)
                session.lastProgress = .now()
                return .line(Data(line))
            }
            guard session.buffer.count <= Self.maximumReplyBytes else { return .closed }
            let now = DispatchTime.now()
            guard now < deadline else { return .timeout }
            let remainingMs = Int((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000)
            var descriptor = pollfd(fd: session.output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(clamping: max(1, remainingMs)))
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(session.output, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            if count == 0 { return .closed }
            session.buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// The worker reads promptly between frames, but a write must never
    /// outlive the frame: past the deadline the worker is killed, which
    /// unblocks the write with EPIPE.
    private func write(_ bitmap: Data, to session: Session, deadline: DispatchTime) -> Bool {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let process = session.process
        timer.setEventHandler {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        timer.schedule(deadline: deadline)
        timer.resume()
        defer { timer.cancel() }
        do {
            try session.input.write(contentsOf: bitmap)
            return true
        } catch {
            return false
        }
    }
}
