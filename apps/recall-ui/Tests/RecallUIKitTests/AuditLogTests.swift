// AuditLogTests.swift — pin the enterprise-audit-log wire shape,
// append + read semantics, rotation policy, and Downloads export.
//
// The pure encode/decode surface is exercised without any on-disk
// state; the append + rotation + read tests use a per-test temporary
// directory so the shared singleton is never perturbed.

import XCTest
@testable import RecallUIKit

final class AuditLogTests: XCTestCase {

    // MARK: - Test scaffolding

    private var tmpDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
        tmpDir = base.appendingPathComponent("AuditLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tmpDir, FileManager.default.fileExists(atPath: tmpDir.path) {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    private func fixedClock(_ iso: String) -> @Sendable () -> Date {
        let f = AuditLog.iso8601Formatter
        let d = f.date(from: iso)!
        return { d }
    }

    // MARK: - Pure encode / decode

    func testEncodeLineEmptyDetails() {
        let date = AuditLog.iso8601Formatter.date(from: "2026-07-13T18:04:22Z")!
        let line = AuditLog.encodeLine(
            timestamp: date, action: .appLaunched, details: [:]
        )
        XCTAssertEqual(line, "2026-07-13T18:04:22Z app_launched {}")
    }

    func testEncodeLineSortedDetails() {
        let date = AuditLog.iso8601Formatter.date(from: "2026-07-13T18:04:22Z")!
        // Insertion order is intentionally NOT alphabetical to prove
        // the encoder sorts keys (byte-exact reproducibility for
        // security-team diffing across log rotations).
        let line = AuditLog.encodeLine(
            timestamp: date,
            action: .deleteEventsInRange,
            details: ["range_hours": "24", "count": "47"]
        )
        XCTAssertEqual(
            line,
            "2026-07-13T18:04:22Z delete_events_in_range {\"count\":\"47\",\"range_hours\":\"24\"}"
        )
    }

    func testParseLineRoundTrip() throws {
        let date = AuditLog.iso8601Formatter.date(from: "2026-07-13T18:04:22Z")!
        let encoded = AuditLog.encodeLine(
            timestamp: date,
            action: .exportJson,
            details: ["events": "1234", "path": "~/Downloads/foo.json"]
        )
        let parsed = try AuditLog.parseLine(encoded)
        XCTAssertEqual(parsed.action, .exportJson)
        XCTAssertEqual(parsed.timestamp, date)
        XCTAssertEqual(parsed.details["events"], "1234")
        XCTAssertEqual(parsed.details["path"], "~/Downloads/foo.json")
    }

    func testParseLineRejectsUnknownAction() {
        XCTAssertThrowsError(
            try AuditLog.parseLine("2026-07-13T18:04:22Z totally_bogus {}")
        )
    }

    func testParseLineRejectsBadTimestamp() {
        XCTAssertThrowsError(
            try AuditLog.parseLine("not-a-timestamp app_launched {}")
        )
    }

    // MARK: - Append + read

    func testRecordThenReadRecentReturnsNewestFirst() throws {
        let log = AuditLog(baseURL: tmpDir)
        log.record(action: .appLaunched)
        log.record(action: .deleteEvent, details: ["ts_us": "1736000000000000"])
        log.record(action: .exportJson, details: ["events": "7"])

        let entries = log.readRecent(count: 20)
        XCTAssertEqual(entries.count, 3)
        // Newest-first ordering — the UI shows most recent at the top.
        XCTAssertEqual(entries[0].action, .exportJson)
        XCTAssertEqual(entries[1].action, .deleteEvent)
        XCTAssertEqual(entries[2].action, .appLaunched)
        XCTAssertEqual(entries[1].details["ts_us"], "1736000000000000")
    }

    func testReadRecentHonorsCountCap() throws {
        let log = AuditLog(baseURL: tmpDir)
        for i in 0..<30 {
            log.record(action: .deleteEvent, details: ["n": "\(i)"])
        }
        let entries = log.readRecent(count: 5)
        XCTAssertEqual(entries.count, 5)
        // Last five recorded were 25..29 — newest first, so "29" leads.
        XCTAssertEqual(entries.first?.details["n"], "29")
        XCTAssertEqual(entries.last?.details["n"], "25")
    }

    func testReadRecentOnMissingFileReturnsEmpty() {
        let log = AuditLog(baseURL: tmpDir)
        XCTAssertEqual(log.readRecent(count: 10), [])
    }

    // MARK: - Rotation

    func testRotationShiftsOldFileToDotOne() throws {
        let log = AuditLog(baseURL: tmpDir)
        // Pre-seed a large file to force rotation on next write.
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let big = Data(count: AuditLog.rotationThresholdBytes + 1)
        try big.write(to: log.logURL)

        log.record(action: .appLaunched)

        let rotated = tmpDir.appendingPathComponent("audit.log.1")
        XCTAssertTrue(fm.fileExists(atPath: rotated.path),
                      "expected rotated file at .1")
        // Active file should now be small (one line).
        let attrs = try fm.attributesOfItem(atPath: log.logURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertLessThan(size, 1_000)
    }

    func testRotationDiscardsBeyondMaxRotatedFiles() throws {
        let log = AuditLog(baseURL: tmpDir)
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Seed .1 … .5 with distinctive contents so we can prove which
        // survives + which is discarded across a rotation cycle.
        for n in 1...AuditLog.maxRotatedFiles {
            let url = tmpDir.appendingPathComponent("audit.log.\(n)")
            try "seed-\(n)".write(to: url, atomically: true, encoding: .utf8)
        }
        // Active file oversized → triggers a rotate on next write.
        let big = Data(count: AuditLog.rotationThresholdBytes + 1)
        try big.write(to: log.logURL)

        log.record(action: .appLaunched)

        // Old .5 should be gone (discarded); new .5 = old .4 contents;
        // new .1 = the previously-active (now empty-ish) content start.
        let dot5 = tmpDir.appendingPathComponent("audit.log.5")
        let dot5Text = (try? String(contentsOf: dot5, encoding: .utf8)) ?? ""
        XCTAssertEqual(dot5Text, "seed-4",
                       "old .4 should have shifted into .5 slot")
        XCTAssertTrue(fm.fileExists(atPath:
            tmpDir.appendingPathComponent("audit.log.1").path))
    }

    // MARK: - Export to Downloads

    func testExportToDownloadsWritesCurrentLog() throws {
        let log = AuditLog(baseURL: tmpDir, now: fixedClock("2026-07-13T18:04:22Z"))
        log.record(action: .appLaunched)
        log.record(action: .exportJson, details: ["events": "3"])

        let url = try log.exportToDownloads()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(url.lastPathComponent.hasPrefix("hippocampus-audit-log-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("app_launched"))
        XCTAssertTrue(text.contains("export_json"))
    }

}
