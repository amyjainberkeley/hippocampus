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

    func test_capture_defaults_false_when_file_missing() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(cfg.captureEnabled)
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

    func test_set_capture_enabled_round_trip() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCaptureEnabled(true)
        XCTAssertTrue(cfg.captureEnabled)

        try cfg.setCaptureEnabled(false)
        XCTAssertFalse(cfg.captureEnabled)
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

    func test_capture_write_uses_file_mode_0644() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCaptureEnabled(true)

        let attrs = try FileManager.default.attributesOfItem(atPath: cfg.path.path)
        let mode = attrs[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644, "runtime.toml must be 0644 because capture_enabled is not a secret")
    }

    // MARK: - parseBool

    func test_parseBool_true_values() {
        XCTAssertTrue(RuntimeConfig.parseBool(key: "k", in: "k = true"))
    }

    func test_parseBool_false_values() {
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = false"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = 1"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = 0"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: ""))
    }

    func test_parseBool_rejects_non_boolean_toml_values() {
        for value in ["\"true\"", "'true'", "[true]", "{ value = true }", "tru", "true false"] {
            XCTAssertFalse(
                RuntimeConfig.parseBool(key: "capture_enabled", in: "capture_enabled = \(value)"),
                "invalid TOML boolean must fail closed: \(value)"
            )
        }
        XCTAssertFalse(RuntimeConfig.parseBool(
            key: "capture_enabled",
            in: "\"capture_enabled\" trailing = true"
        ))
    }

    func test_table_local_capture_key_is_not_root_capture_authority() {
        XCTAssertFalse(RuntimeConfig.parseBool(
            key: "capture_enabled",
            in: "[capture]\ncapture_enabled = true"
        ))
    }

    func test_parseBool_ignores_comments() {
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "# k = true\nk = false"))
    }

    func test_parseBool_fails_closed_on_duplicate_key() {
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = true\nk = false"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = true\nk = malformed"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "k = true\n\"k\" = false"))
        XCTAssertFalse(RuntimeConfig.parseBool(key: "k", in: "'k' = true\nk = false"))
    }

    func test_invalid_numeric_capture_authority_stays_off_after_relaunch() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "capture_enabled = 1\n".write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled)
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_formatted_capture_key_updates_exactly_and_survives_relaunch() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
         capture_enabled = true # user capture preference
        capture_enabled_backup = true
        # capture_enabled = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        try cfg.setCaptureEnabled(false)
        let relaunched = RuntimeConfig(path: cfg.path)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)

        XCTAssertFalse(relaunched.captureEnabled)
        XCTAssertTrue(content.contains(" capture_enabled = false # user capture preference"))
        XCTAssertTrue(content.contains("capture_enabled_backup = true"))
        XCTAssertTrue(content.contains("# capture_enabled = true"))
    }

    func test_capture_write_collapses_duplicate_exact_keys_deterministically() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        capture_enabled = true # keep this comment
        # separator remains
          capture_enabled = false # duplicate removed
        capture_enabled_backup = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled, "ambiguous duplicate input must fail closed")
        try cfg.setCaptureEnabled(true)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)
        let exactAssignments = content.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("capture_enabled =")
        }

        XCTAssertEqual(exactAssignments.count, 1)
        XCTAssertTrue(content.contains("capture_enabled = true # keep this comment"))
        XCTAssertTrue(content.contains("# separator remains"))
        XCTAssertTrue(content.contains("capture_enabled_backup = true"))
        XCTAssertTrue(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_capture_write_collapses_bare_and_quoted_semantic_duplicates() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        "capture_enabled" = true # preserve first comment
        capture_enabled = false
        'capture_enabled' = true
        capture_enabled_backup = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled)
        try cfg.setCaptureEnabled(false)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)

        XCTAssertEqual(
            content.split(separator: "\n").filter {
                RuntimeConfig.assignmentKey(in: String($0)) == "capture_enabled"
            }.count,
            1
        )
        XCTAssertTrue(content.contains("capture_enabled = false # preserve first comment"))
        XCTAssertTrue(content.contains("capture_enabled_backup = true"))
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_capture_on_to_off_round_trip_uses_one_key_after_each_relaunch() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }

        try cfg.setCaptureEnabled(true)
        XCTAssertTrue(RuntimeConfig(path: cfg.path).captureEnabled)
        try RuntimeConfig(path: cfg.path).setCaptureEnabled(false)
        let relaunched = RuntimeConfig(path: cfg.path)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)

        XCTAssertFalse(relaunched.captureEnabled)
        XCTAssertEqual(
            content.split(separator: "\n").filter { $0.hasPrefix("capture_enabled =") }.count,
            1
        )
    }

    func test_capture_write_inserts_root_key_before_existing_tables() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        title = "preferences"
        [capture]
        capture_enabled = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled)
        try cfg.setCaptureEnabled(true)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)

        XCTAssertTrue(content.contains("title = \"preferences\"\ncapture_enabled = true\n[capture]"))
        XCTAssertTrue(RuntimeConfig(path: cfg.path).captureEnabled)
        XCTAssertTrue(content.contains("[capture]\ncapture_enabled = true"))
    }
}
