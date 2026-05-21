// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class RuntimeConfigTests: XCTestCase {

    private func tmpConfig() throws -> (RuntimeConfig, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("runtime.toml")
        return (RuntimeConfig(path: path), dir)
    }

    // MARK: - Read defaults

    func test_default_is_false_when_file_missing() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(cfg.crashReportOptedIn)
    }

    // MARK: - Write + round-trip

    func test_set_true_round_trip() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCrashReportOptedIn(true)
        XCTAssertTrue(cfg.crashReportOptedIn)
    }

    func test_set_false_round_trip() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCrashReportOptedIn(true)
        try cfg.setCrashReportOptedIn(false)
        XCTAssertFalse(cfg.crashReportOptedIn)
    }

    func test_toggle_preserves_other_keys() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        let parent = cfg.path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try "some_other_key = 42\n".write(to: cfg.path, atomically: true, encoding: .utf8)

        try cfg.setCrashReportOptedIn(true)

        let content = try String(contentsOf: cfg.path, encoding: .utf8)
        XCTAssertTrue(content.contains("some_other_key = 42"), "Other keys preserved: \(content)")
        XCTAssertTrue(content.contains("crash_report_opted_in = true"), "Opt-in set: \(content)")
    }

    // MARK: - File permissions

    func test_file_mode_is_0644() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCrashReportOptedIn(true)

        let attrs = try FileManager.default.attributesOfItem(atPath: cfg.path.path)
        let mode = attrs[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644, "runtime.toml must be 0644")
    }

    // MARK: - parseBool

    func test_parseBool_true_values() {
        XCTAssertTrue(RuntimeConfig.parseBool(key: "k", in: "k = true"))
        XCTAssertTrue(RuntimeConfig.parseBool(key: "k", in: "k = 1"))
    }

    func test_parseBool_false_values() {
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = false"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = 0"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: ""))
    }

    func test_parseBool_ignores_comments() {
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "# k = true\nk = false"))
    }

    func test_parseBool_takes_first_match() {
        XCTAssertTrue(RuntimeConfig.parseBool(key: "k", in: "k = true\nk = false"))
    }
}
