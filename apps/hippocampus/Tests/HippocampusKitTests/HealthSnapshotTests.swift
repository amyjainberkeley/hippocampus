// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class HealthSnapshotTests: XCTestCase {

    // MARK: - Log parsing

    func test_readFromLog_parses_last_line() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logFile = tmp.appendingPathComponent("helper-health.jsonl")
        let lines = [
            #"{"wall_ts":"2026-05-20T10:00:00.000Z","device_id":"aaaa","uptime_ms":1000,"frames_delivered":5,"frames_suppressed":1,"frames_redacted_by_failsafe":0,"cascade_forced_count":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#,
            #"{"wall_ts":"2026-05-20T10:01:00.000Z","device_id":"aaaa","uptime_ms":2000,"frames_delivered":18,"frames_suppressed":3,"frames_redacted_by_failsafe":0,"cascade_forced_count":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#,
        ]
        try lines.joined(separator: "\n").write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = HealthSnapshot.readFromLog(at: logFile)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.framesDelivered, 18)
        XCTAssertEqual(snapshot?.framesSuppressed, 3)
    }

    func test_readFromLog_returns_nil_for_missing_file() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).jsonl")
        let snapshot = HealthSnapshot.readFromLog(at: bogus)
        XCTAssertNil(snapshot)
    }

    func test_readFromLog_returns_nil_for_empty_file() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hst-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logFile = tmp.appendingPathComponent("empty.jsonl")
        try "".write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = HealthSnapshot.readFromLog(at: logFile)
        XCTAssertNil(snapshot)
    }

    func test_readFromLog_handles_single_line() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hst-single-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logFile = tmp.appendingPathComponent("single.jsonl")
        let line = #"{"wall_ts":"2026-05-21T08:00:00.000Z","device_id":"bbbb","uptime_ms":500,"frames_delivered":3,"frames_suppressed":0,"frames_redacted_by_failsafe":0,"cascade_forced_count":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#
        try line.write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = HealthSnapshot.readFromLog(at: logFile)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.framesDelivered, 3)
    }

    func test_readFromLog_parses_wall_ts_as_lastCaptureTs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hst-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logFile = tmp.appendingPathComponent("ts.jsonl")
        let line = #"{"wall_ts":"2026-05-21T12:30:00.000Z","device_id":"cccc","uptime_ms":100,"frames_delivered":1,"frames_suppressed":0,"frames_redacted_by_failsafe":0,"cascade_forced_count":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#
        try line.write(to: logFile, atomically: true, encoding: .utf8)

        let snapshot = HealthSnapshot.readFromLog(at: logFile)!
        XCTAssertNotNil(snapshot.lastCaptureTs)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = fmt.date(from: "2026-05-21T12:30:00.000Z")!
        XCTAssertEqual(snapshot.lastCaptureTs, expected)
    }

    // MARK: - eventCount priority

    func test_eventCount_prefers_brain_over_frames() {
        let s = HealthSnapshot(
            framesDelivered: 100,
            framesSuppressed: 0,
            brainEventCount: 42,
            lastCaptureTs: nil,
            lastUpdated: Date()
        )
        XCTAssertEqual(s.eventCount, 42)
    }

    func test_eventCount_falls_back_to_framesDelivered() {
        let s = HealthSnapshot(
            framesDelivered: 77,
            framesSuppressed: 0,
            brainEventCount: nil,
            lastCaptureTs: nil,
            lastUpdated: Date()
        )
        XCTAssertEqual(s.eventCount, 77)
    }

    // MARK: - displayText

    func test_displayText_with_lastCaptureTs() {
        let s = HealthSnapshot(
            framesDelivered: 10,
            framesSuppressed: 0,
            brainEventCount: nil,
            lastCaptureTs: Date().addingTimeInterval(-120),
            lastUpdated: Date()
        )
        let text = s.displayText
        XCTAssertTrue(text.hasPrefix("10 events captured"), "Got: \(text)")
        XCTAssertTrue(text.contains("last"), "Got: \(text)")
    }

    func test_displayText_without_lastCaptureTs_uses_lastUpdated() {
        let s = HealthSnapshot(
            framesDelivered: 5,
            framesSuppressed: 0,
            brainEventCount: nil,
            lastCaptureTs: nil,
            lastUpdated: Date().addingTimeInterval(-60)
        )
        let text = s.displayText
        XCTAssertTrue(text.hasPrefix("5 events captured"), "Got: \(text)")
    }
}
