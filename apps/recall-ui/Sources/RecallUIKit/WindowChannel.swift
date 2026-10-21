import Darwin
import Foundation

/// The window's private pipe to the app that opened it (SPEC 2.6.4).
///
/// Pause, Resume, Turn On, Try Again and the forget hold never travel over
/// `DistributedNotificationCenter`: any process on the Mac can post there,
/// and none may ever turn remembering back on. The app starts the window as
/// its own child with two anonymous pipes on file descriptors 3 (window to
/// app) and 4 (app to window), and says so in `MCI_WINDOW_CHANNEL=3,4`. The
/// window marks both close-on-exec as its first act, so the agent processes
/// it starts never inherit them.
///
/// Messages are one line of JSON each, at most 4 KB, versioned:
/// `{"v":1,"id":"…","op":"pause","until":"2026-10-12T15:40:00-07:00"}`. The
/// app answers each with `{"v":1,"id":"…","ok":true}` or a content-free
/// error, and pushes `status` whenever it changes. The app decides: it does
/// only what the same click in the menu bar would do in that state.
public enum WindowChannelProtocol {
    public static let version = 1
    /// The environment variable naming the two descriptors: "3,4".
    public static let environmentKey = "MCI_WINDOW_CHANNEL"
    /// The window writes here; the app reads.
    public static let windowWritesDescriptor: Int32 = 3
    /// The app writes here; the window reads.
    public static let windowReadsDescriptor: Int32 = 4
    /// The longest line either side sends or takes, newline included.
    public static let maxLineBytes = 4_096

    /// What the window may ask for.
    public enum Op: String, CaseIterable, Sendable {
        case pause
        case resume
        case turnOn
        /// Turn Off, offered while a turn-on is under way: its own op,
        /// never a pause, which the app takes only when it offers Pause.
        case turnOff
        case tryAgain
        case openSystemSettings
        /// Quit Hippocampus, the one fix for "Couldn't stop", as in the
        /// menu bar.
        case quit
        /// Stop remembering for a forget, without the person's pause.
        case hold
        /// The forget is done: remember again, if it was on.
        case release
        /// The forget's deletes still run: keep the hold. Sent every 10
        /// seconds while they do, and never awaited: an app that doesn't know
        /// it ignores the line.
        case renew
        /// Leave Demo Memory: back to the person's own memory with
        /// remembering as it was before, a pause they made included, as the
        /// menu bar's Leave does. Never a Resume.
        case leaveDemo
        /// Delete Everything: the app stops remembering, erases the memory
        /// and its key, and starts again (storage-security review S3).
        case erase
        /// The app pushes this; the window never sends it.
        case status
    }

    /// The pause's end, written as an ISO 8601 time with its offset.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// One request from the window to the app.
public struct WindowChannelRequest: Equatable, Sendable {
    public let id: String
    public let op: WindowChannelProtocol.Op
    /// Pause: when it ends; nil pauses until the person resumes.
    public var until: Date?
    /// Open System Settings: `screenRecording` or `accessibility`.
    public var permission: String?

    public init(id: String = UUID().uuidString, op: WindowChannelProtocol.Op, until: Date? = nil,
                permission: String? = nil) {
        self.id = id
        self.op = op
        self.until = until
        self.permission = permission
    }

    /// The line sent: JSON and a newline, never longer than the limit.
    public func line() -> Data? {
        var object: [String: Any] = ["v": WindowChannelProtocol.version, "id": id, "op": op.rawValue]
        if let until { object["until"] = WindowChannelProtocol.timestamp(until) }
        if let permission { object["permission"] = permission }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data.count <= WindowChannelProtocol.maxLineBytes ? data : nil
    }
}

/// What the app pushes about remembering: the menu bar's own words, so the
/// window, the menu bar, Ask's footer and Preferences never disagree.
public struct WindowChannelStatus: Equatable, Sendable {
    /// The state, coarsely: decides the dot and the banner.
    public enum State: String, Sendable, CaseIterable {
        case remembering
        case starting
        case nothingSaved
        case skipping
        case paused
        case off
        case needsPermission
        case notSaving
        case couldNotStop
        case couldNotTurnOn
        case notSetUp
        case forgetting
    }

    public var state: State
    /// The menu bar's first line: "Remembering", "Paused", …
    public var title: String
    /// The menu bar's second line, when there is one.
    public var detail: String?
    /// The one button the menu bar offers now: `pause`, `resume`, `turnOn`,
    /// `turnOff`, `openSystemSettings`, `tryAgain`, `quit`, `finishSetup`.
    public var action: String?
    /// `screenRecording` or `accessibility`, for Open System Settings.
    public var permission: String?
    public var pausedSince: Date?
    /// A timed pause's end.
    public var pausedUntil: Date?
    public var lowPower: Bool

    public init(state: State, title: String, detail: String? = nil, action: String? = nil,
                permission: String? = nil, pausedSince: Date? = nil, pausedUntil: Date? = nil,
                lowPower: Bool = false) {
        self.state = state
        self.title = title
        self.detail = detail
        self.action = action
        self.permission = permission
        self.pausedSince = pausedSince
        self.pausedUntil = pausedUntil
        self.lowPower = lowPower
    }

    /// From a pushed `status` line; nil for anything malformed.
    public init?(json object: [String: Any]) {
        guard object["op"] as? String == WindowChannelProtocol.Op.status.rawValue,
              let raw = object["state"] as? String, let state = State(rawValue: raw),
              let title = object["title"] as? String, !title.isEmpty, title.count <= 80
        else { return nil }
        self.init(
            state: state,
            title: title,
            detail: (object["detail"] as? String).flatMap { $0.count <= 200 ? $0 : nil },
            action: object["action"] as? String,
            permission: object["permission"] as? String,
            pausedSince: WindowChannelProtocol.date(object["pausedSince"] as? String),
            pausedUntil: WindowChannelProtocol.date(object["pausedUntil"] as? String),
            lowPower: object["lowPower"] as? Bool ?? false
        )
    }
}

/// How the window speaks to the app: the pipe in the app, a fake in tests,
/// renders and the synthetic preview (which never has one).
public protocol WindowChannelSending: AnyObject, Sendable {
    /// Sends `request` and waits at most `timeout` for the app's answer:
    /// true when it did it, false when it refused or did not answer.
    func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool
    /// Every status the app pushes, newest last.
    func statuses() -> AsyncStream<WindowChannelStatus>
}

/// The window's end of the private pipe.
public final class WindowChannel: WindowChannelSending, @unchecked Sendable {
    /// The descriptors in `MCI_WINDOW_CHANNEL`, when the environment names
    /// two that are pipes. Nil for a window opened by hand (Finder, a
    /// script): it has no controls.
    public static func descriptors(environment: [String: String]) -> (write: Int32, read: Int32)? {
        guard let value = environment[WindowChannelProtocol.environmentKey] else { return nil }
        let parts = value.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] == WindowChannelProtocol.windowWritesDescriptor,
              parts[1] == WindowChannelProtocol.windowReadsDescriptor
        else { return nil }
        guard isPipe(parts[0]), isPipe(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// Marks `descriptor` close-on-exec, so no process the window starts
    /// inherits it. True when it is set.
    @discardableResult
    public static func closeOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    static func isPipe(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFIFO
    }

    /// The window's channel at launch: the descriptors marked close-on-exec
    /// first, then the reader started. Nil without a channel.
    public static func open(environment: [String: String] = ProcessInfo.processInfo.environment) -> WindowChannel? {
        guard let fds = descriptors(environment: environment) else { return nil }
        guard closeOnExec(fds.write), closeOnExec(fds.read) else { return nil }
        return WindowChannel(writeDescriptor: fds.write, readDescriptor: fds.read)
    }

    private let writeDescriptor: Int32
    private let readDescriptor: Int32
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]
    private var listeners: [UUID: AsyncStream<WindowChannelStatus>.Continuation] = [:]
    private var latest: WindowChannelStatus?
    private let writes = DispatchQueue(label: "ai.hippocampus.window-channel.write")
    private var reader: Thread?

    /// Both descriptors must already be close-on-exec (`open`).
    public init(writeDescriptor: Int32, readDescriptor: Int32) {
        self.writeDescriptor = writeDescriptor
        self.readDescriptor = readDescriptor
        // Never SIGPIPE: an app that is gone is a refusal, not a crash.
        _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "ai.hippocampus.window-channel.read"
        thread.qualityOfService = .utility
        reader = thread
        thread.start()
    }

    public func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
        guard let line = request.line() else { return false }
        return await withCheckedContinuation { continuation in
            lock.lock()
            waiting[request.id] = continuation
            lock.unlock()
            writes.async { [weak self] in
                guard let self else { return }
                let sent = line.withUnsafeBytes { buffer -> Bool in
                    var offset = 0
                    while offset < buffer.count {
                        let wrote = Darwin.write(self.writeDescriptor, buffer.baseAddress!.advanced(by: offset),
                                                 buffer.count - offset)
                        if wrote < 0 {
                            if errno == EINTR { continue }
                            return false
                        }
                        offset += wrote
                    }
                    return true
                }
                if !sent { self.answer(request.id, ok: false) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.answer(request.id, ok: false)
            }
        }
    }

    public func statuses() -> AsyncStream<WindowChannelStatus> {
        AsyncStream { continuation in
            let key = UUID()
            lock.lock()
            listeners[key] = continuation
            let current = latest
            lock.unlock()
            if let current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.listeners[key] = nil
                self.lock.unlock()
            }
        }
    }

    private func answer(_ id: String, ok: Bool) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: ok)
    }

    /// Lines from the app, one at a time. A line longer than the limit, or
    /// one that does not parse, is dropped without a word about its content.
    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        var discarding = false
        while true {
            let count = Darwin.read(readDescriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for byte in chunk[0..<count] {
                if byte == 0x0A {
                    if !discarding { handle(buffer) }
                    buffer.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    buffer.append(byte)
                    if buffer.count >= WindowChannelProtocol.maxLineBytes {
                        buffer.removeAll(keepingCapacity: true)
                        discarding = true
                    }
                }
            }
        }
        // The app is gone: nothing waiting will be answered.
        lock.lock()
        let pending = waiting
        waiting.removeAll()
        let streams = listeners
        listeners.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: false) }
        for stream in streams.values { stream.finish() }
    }

    func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["v"] as? Int == WindowChannelProtocol.version
        else { return }
        if let status = WindowChannelStatus(json: object) {
            lock.lock()
            latest = status
            let streams = Array(listeners.values)
            lock.unlock()
            for stream in streams { stream.yield(status) }
            return
        }
        guard let id = object["id"] as? String, let ok = object["ok"] as? Bool else { return }
        answer(id, ok: ok)
    }
}

/// No channel: a window opened by hand, the synthetic preview, renders and
/// tests that ask for none. Every request is refused.
public final class NoWindowChannel: WindowChannelSending, @unchecked Sendable {
    public init() {}
    public func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool { false }
    public func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
}
