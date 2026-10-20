// SPDX-License-Identifier: Apache-2.0
//
// WindowChannelServer.swift — the app's end of the window's private pipe
// (SPEC 2.6.4). Pause, Resume, Turn On, Try Again and the forget hold never
// travel over DistributedNotificationCenter, where any process on the Mac
// can post; they come only from the window this app started, on the pipe it
// gave it. The app decides: a request is carried out only in a state where
// the same click in the menu bar would be, unknown ops and malformed lines
// are ignored, and nothing about their content is logged.

import Foundation
import os

/// One request from the window.
public struct WindowChannelRequest: Equatable, Sendable {
    public enum Op: String, CaseIterable, Sendable {
        case pause, resume, turnOn, tryAgain, openSystemSettings, quit, hold, release
        /// Leave Demo Memory: back to the person's own memory, with
        /// remembering as it was before, as the menu bar's Leave does.
        case leaveDemo
        /// The window is still deleting under its hold: the hold's end moves
        /// 30 seconds out (`CaptureHold.renew`).
        case renew
    }

    public let id: String
    public let op: Op
    /// Pause: when it ends; nil until the person resumes.
    public let until: Date?
    /// Open System Settings: which permission.
    public let permission: TCCRevokedReason?

    public init(id: String, op: Op, until: Date? = nil, permission: TCCRevokedReason? = nil) {
        self.id = id
        self.op = op
        self.until = until
        self.permission = permission
    }

    /// The longest line either side sends or takes, newline included.
    public static let maxLineBytes = 4_096

    /// One line from the window; nil for anything that isn't exactly a
    /// request this version knows. A request never carries content.
    public static func parse(_ line: Data) -> WindowChannelRequest? {
        guard line.count < maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["v"] as? Int == 1,
              let id = object["id"] as? String, (1...64).contains(id.utf8.count),
              let raw = object["op"] as? String, let op = Op(rawValue: raw)
        else { return nil }
        var until: Date?
        if let text = object["until"] as? String {
            guard op == .pause, let date = timestamp(text) else { return nil }
            until = date
        }
        var permission: TCCRevokedReason?
        if op == .openSystemSettings {
            switch object["permission"] as? String {
            case "screenRecording": permission = .screenRecording
            case "accessibility": permission = .accessibility
            default: return nil
            }
        }
        return WindowChannelRequest(id: id, op: op, until: until, permission: permission)
    }

    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// What the app pushes about remembering: the menu bar's own words, so the
/// window never disagrees with it.
public struct WindowStatusMessage: Equatable, Sendable {
    public enum State: String, Sendable {
        case remembering, starting, nothingSaved, skipping, paused, off, needsPermission, notSaving,
             couldNotStop, couldNotTurnOn, notSetUp, forgetting
    }

    public var state: State
    public var title: String
    public var detail: String?
    public var action: CaptureStatusAction?
    public var pausedSince: Date?
    public var pausedUntil: Date?
    public var lowPower: Bool

    public init(state: State, title: String, detail: String? = nil, action: CaptureStatusAction? = nil,
                pausedSince: Date? = nil, pausedUntil: Date? = nil, lowPower: Bool = false) {
        self.state = state
        self.title = title
        self.detail = detail
        self.action = action
        self.pausedSince = pausedSince
        self.pausedUntil = pausedUntil
        self.lowPower = lowPower
    }

    /// The status row and what it's made from, as the window reads it.
    public init(row: StatusRow, status: MenuBarStatus, setupComplete: Bool, forgetting: Bool,
                pausedSince: Date?, pausedUntil: Date?, lowPower: Bool) {
        let state: State
        if forgetting {
            state = .forgetting
        } else if !setupComplete {
            state = .notSetUp
        } else {
            switch status {
            case .recording, .unchanged: state = .remembering
            case .starting: state = .starting
            case .noMemory: state = .nothingSaved
            case .skipping: state = .skipping
            case .paused: state = .paused
            case .idle: state = .off
            case .needsPermission: state = .needsPermission
            case .blocked, .stale, .error: state = .notSaving
            case .stopFailed: state = .couldNotStop
            case .turnOnFailed: state = .couldNotTurnOn
            }
        }
        self.init(state: state, title: row.title, detail: row.detail, action: forgetting ? nil : row.action,
                  pausedSince: state == .paused ? pausedSince : nil,
                  pausedUntil: state == .paused ? pausedUntil : nil, lowPower: lowPower)
    }

    /// One line of JSON and a newline, never longer than the limit.
    public func line() -> Data? {
        var object: [String: Any] = ["v": 1, "op": "status", "state": state.rawValue, "title": title,
                                     "lowPower": lowPower]
        if let detail { object["detail"] = detail }
        if let action {
            object["action"] = Self.word(action)
            if case let .openSystemSettings(permission) = action {
                object["permission"] = permission == .accessibility ? "accessibility" : "screenRecording"
            }
        }
        if let pausedSince { object["pausedSince"] = Self.stamp(pausedSince) }
        if let pausedUntil { object["pausedUntil"] = Self.stamp(pausedUntil) }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data.count <= WindowChannelRequest.maxLineBytes ? data : nil
    }

    static func word(_ action: CaptureStatusAction) -> String {
        switch action {
        case .pause: "pause"
        case .resume: "resume"
        case .turnOn: "turnOn"
        case .turnOff: "turnOff"
        case .openSystemSettings: "openSystemSettings"
        case .tryAgain: "tryAgain"
        case .quit: "quit"
        case .finishSetup: "finishSetup"
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Whether the menu bar would carry out `request` now, given its status
/// row: the window may do only what the person could click here (SPEC
/// 2.6.4). Turn On only after setup (before it, the row offers Finish
/// Setup…), Resume only when paused, and so on. The hold is always asked;
/// the app answers it at once when nothing holds the memory, and renews or
/// releases it only while it holds. Leave Demo Memory is the menu's own item
/// beside the row: it is there whenever Demo Memory is in use
/// (`demoMemory`), whatever the row offers.
public enum WindowChannelPolicy {
    public static func allows(_ request: WindowChannelRequest, row: StatusRow, holding: Bool,
                              demoMemory: Bool = false) -> Bool {
        switch request.op {
        case .pause: return row.action == .pause
        case .resume: return row.action == .resume
        case .turnOn: return row.action == .turnOn
        case .tryAgain: return row.action == .tryAgain
        case .quit: return row.action == .quit
        // Never in the middle of a forget: the window it reopens is the
        // one deleting.
        case .leaveDemo: return demoMemory && !holding
        case .openSystemSettings:
            guard case let .openSystemSettings(permission) = row.action else { return false }
            return permission == request.permission
        case .hold: return !holding
        case .release, .renew: return holding
        }
    }
}

/// The app's end of one window's pipe: reads its requests, hands each to
/// `handle` on the main actor and answers, and pushes status lines.
@MainActor
public final class WindowChannelServer {
    private let input: FileHandle
    private let output: FileHandle
    private let handle: @MainActor (WindowChannelRequest) async -> Bool
    private let writes = DispatchQueue(label: "ai.hippocampus.window-channel.server.write")
    private let logger = Logger(subsystem: "ai.hippocampus", category: "window-channel")
    private var lastStatus: Data?
    private var reading: Thread?
    private var closed = false

    /// `input` is what the window writes; `output` what it reads.
    public init(input: FileHandle, output: FileHandle,
                handle: @escaping @MainActor (WindowChannelRequest) async -> Bool) {
        self.input = input
        self.output = output
        self.handle = handle
    }

    public func start() {
        let descriptor = input.fileDescriptor
        let thread = Thread { [weak self] in
            Self.read(descriptor) { line in
                Task { @MainActor [weak self] in await self?.receive(line) }
            }
        }
        thread.name = "ai.hippocampus.window-channel.server.read"
        thread.qualityOfService = .utility
        reading = thread
        thread.start()
    }

    /// Pushes `message` when it differs from the last one pushed.
    public func push(_ message: WindowStatusMessage) {
        guard !closed, let line = message.line(), line != lastStatus else { return }
        lastStatus = line
        write(line)
    }

    public func close() {
        closed = true
    }

    func receive(_ line: Data) async {
        guard !closed else { return }
        guard let request = WindowChannelRequest.parse(line) else {
            // Content-free: never the line itself.
            logger.info("window channel: ignored a line it doesn't know")
            return
        }
        let ok = await handle(request)
        let answer = "{\"v\":1,\"id\":\(Self.quoted(request.id)),\"ok\":\(ok)}\n"
        write(Data(answer.utf8))
    }

    private func write(_ data: Data) {
        let descriptor = output.fileDescriptor
        writes.async {
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let wrote = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if wrote < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += wrote
                }
            }
        }
    }

    private static func quoted(_ id: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [id])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    /// Lines from the window. A line longer than the limit is dropped up to
    /// its newline.
    nonisolated static func read(_ descriptor: Int32, line: @escaping (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        var discarding = false
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            for byte in chunk[0..<count] {
                if byte == 0x0A {
                    if !discarding, !buffer.isEmpty { line(buffer) }
                    buffer = Data()
                    discarding = false
                } else if !discarding {
                    buffer.append(byte)
                    if buffer.count >= WindowChannelRequest.maxLineBytes {
                        buffer = Data()
                        discarding = true
                    }
                }
            }
        }
    }
}
