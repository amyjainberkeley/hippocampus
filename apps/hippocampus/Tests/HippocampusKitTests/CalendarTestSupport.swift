// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import HippocampusKit

/// A calendar store for tests (SPEC-DELTA 5): macOS's answer is whatever the
/// test says, asking is counted, and nothing touches EventKit or the real
/// system's permissions.
final class FakeCalendarAccess: CalendarAccessStore, @unchecked Sendable {
    enum Answer {
        /// The person allows or refuses; macOS's answer changes to match.
        case person(allows: Bool)
        /// macOS couldn't ask; its answer stays as it was.
        case fails
        /// macOS returns without deciding; its answer stays as it was.
        case undecided
        /// The test answers later, with `answer(allows:)`.
        case held
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var current: CalendarPermission
    private let reply: Answer
    private var meetingsHeld: [CalendarMeeting]
    private var waiting: CheckedContinuation<Bool, Never>?
    private(set) var requests = 0
    private(set) var reads: [DateInterval] = []

    init(_ permission: CalendarPermission, answer: Answer = .person(allows: true), meetings: [CalendarMeeting] = []) {
        current = permission
        reply = answer
        meetingsHeld = meetings
    }

    var requestCount: Int { lock.withLock { requests } }
    var readCount: Int { lock.withLock { reads.count } }
    var readIntervals: [DateInterval] { lock.withLock { reads } }

    /// macOS's answer changes, as when the person changes it in System Settings.
    func change(to permission: CalendarPermission) {
        lock.withLock { current = permission }
    }

    func permission() -> CalendarPermission {
        lock.withLock { current }
    }

    func requestFullAccess() async throws -> Bool {
        lock.withLock { requests += 1 }
        switch reply {
        case .person(let allows):
            change(to: allows ? .fullAccess : .denied)
            return allows
        case .fails:
            throw Failure()
        case .undecided:
            return false
        case .held:
            let allows = await withCheckedContinuation { continuation in
                lock.withLock { waiting = continuation }
            }
            change(to: allows ? .fullAccess : .denied)
            return allows
        }
    }

    /// Answers a held question.
    func answer(allows: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: allows)
    }

    var isHoldingAQuestion: Bool { lock.withLock { waiting != nil } }

    func meetings(in interval: DateInterval) throws -> [CalendarMeeting] {
        lock.withLock { reads.append(interval) }
        guard permission() == .fullAccess else { return [] }
        return lock.withLock { meetingsHeld }.filter { $0.start < interval.end && $0.end > interval.start }
    }
}

/// The repository's own files, for the checks that read source.
enum CalendarSource {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String, from base: URL = package) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    static var repository: URL {
        package.deletingLastPathComponent().deletingLastPathComponent()
    }
}
