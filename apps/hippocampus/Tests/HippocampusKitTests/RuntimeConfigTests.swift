// SPDX-License-Identifier: TBD-private
import TOMLKit
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

    func test_parseBool_fails_closed_when_any_part_of_document_is_malformed() {
        for document in [
            "capture_enabled = true\n[unterminated",
            "capture_enabled = true\nunrelated =",
            "capture_enabled = true\nunrelated = [1, 2",
        ] {
            XCTAssertFalse(
                RuntimeConfig.parseBool(key: "capture_enabled", in: document),
                "partial parsing must never authorize capture: \(document)"
            )
        }
    }

    func test_parseBool_fails_closed_on_escaped_semantic_duplicate() {
        XCTAssertFalse(RuntimeConfig.parseBool(
            key: "capture_enabled",
            in: "capture_enabled = true\n\"\\u0063apture_enabled\" = false"
        ))
    }

    func test_write_rejects_malformed_document_without_mutating_it() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let malformed = "capture_enabled = true\nunrelated = [1, 2\n"
        try malformed.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try cfg.setCaptureEnabled(false))
        XCTAssertEqual(try String(contentsOf: cfg.path, encoding: .utf8), malformed)
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_write_rejects_wrong_type_and_escaped_duplicate_without_mutation() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        for invalid in [
            "capture_enabled = 1\n",
            "capture_enabled = true\n\"\\u0063apture_enabled\" = false\n",
        ] {
            try invalid.write(to: cfg.path, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try cfg.setCaptureEnabled(false))
            XCTAssertEqual(try String(contentsOf: cfg.path, encoding: .utf8), invalid)
            XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
        }
    }

    func test_invalid_numeric_capture_authority_stays_off_after_relaunch() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "capture_enabled = 1\n".write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled)
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_formatted_capture_key_updates_semantically_and_survives_relaunch() throws {
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
        XCTAssertTrue(content.contains("capture_enabled = false"))
        XCTAssertTrue(content.contains("capture_enabled_backup = true"))
    }

    func test_escaped_root_key_updates_after_full_parse_and_survives_relaunch() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "\"\\u0063apture_enabled\" = true # escaped key\n".write(
            to: cfg.path,
            atomically: true,
            encoding: .utf8
        )

        try cfg.setCaptureEnabled(false)
        let content = try String(contentsOf: cfg.path, encoding: .utf8)

        XCTAssertTrue(content.contains("capture_enabled = false"))
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_capture_write_rejects_duplicate_exact_keys_without_mutation() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        capture_enabled = true # keep this comment
        # separator remains
          capture_enabled = false # duplicate removed
        capture_enabled_backup = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled, "ambiguous duplicate input must fail closed")
        let original = try String(contentsOf: cfg.path, encoding: .utf8)
        XCTAssertThrowsError(try cfg.setCaptureEnabled(true))
        XCTAssertEqual(try String(contentsOf: cfg.path, encoding: .utf8), original)
        XCTAssertFalse(RuntimeConfig(path: cfg.path).captureEnabled)
    }

    func test_capture_write_rejects_semantic_duplicates_without_mutation() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        "capture_enabled" = true # preserve first comment
        capture_enabled = false
        'capture_enabled' = true
        capture_enabled_backup = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        XCTAssertFalse(cfg.captureEnabled)
        let original = try String(contentsOf: cfg.path, encoding: .utf8)
        XCTAssertThrowsError(try cfg.setCaptureEnabled(false))
        XCTAssertEqual(try String(contentsOf: cfg.path, encoding: .utf8), original)
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
        let parsed = try TOMLTable(string: content)

        XCTAssertEqual(parsed["title"]?.string, "preferences")
        XCTAssertTrue(RuntimeConfig(path: cfg.path).captureEnabled)
        XCTAssertTrue(content.contains("[capture]"))
    }

    func test_capture_write_handles_table_like_line_inside_multiline_string() throws {
        let (cfg, dir) = try tmpConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        notes = '''
        alpha
        [text]
        omega
        '''
        [capture]
        capture_enabled = true
        """.write(to: cfg.path, atomically: true, encoding: .utf8)

        try cfg.setCaptureEnabled(true)

        let content = try String(contentsOf: cfg.path, encoding: .utf8)
        XCTAssertTrue(RuntimeConfig(path: cfg.path).captureEnabled)
        XCTAssertTrue(content.contains("[text]"))
    }
}
