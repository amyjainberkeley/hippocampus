import Foundation
import HippocampusKit

@main
struct RuntimeConfigBehavior {
    static func main() throws {
        for invalid in ["1", "\"true\"", "[true]", "tru", "true false"] {
            precondition(
                !RuntimeConfig.parseBool(
                    key: "capture_enabled",
                    in: "capture_enabled = \(invalid)"
                ),
                "invalid TOML boolean authorized capture: \(invalid)"
            )
        }
        precondition(
            !RuntimeConfig.parseBool(
                key: "capture_enabled",
                in: "[capture]\ncapture_enabled = true"
            ),
            "table-local key must not authorize root capture"
        )
        precondition(
            !RuntimeConfig.parseBool(
                key: "capture_enabled",
                in: "\"capture_enabled\" trailing = true"
            ),
            "malformed quoted assignment must fail closed"
        )
        precondition(
            !RuntimeConfig.parseBool(key: "capture_enabled", in: "capture_enabled = true\ncapture_enabled = malformed"),
            "any duplicate exact key must fail closed"
        )
        precondition(
            !RuntimeConfig.parseBool(key: "capture_enabled", in: "capture_enabled = true\n\"capture_enabled\" = false"),
            "quoted and bare semantic duplicates must fail closed"
        )
        for malformedDocument in [
            "capture_enabled = true\n[unterminated",
            "capture_enabled = true\nunrelated =",
            "capture_enabled = true\nunrelated = [1, 2",
        ] {
            precondition(
                !RuntimeConfig.parseBool(key: "capture_enabled", in: malformedDocument),
                "malformed whole document authorized capture: \(malformedDocument)"
            )
        }
        precondition(
            !RuntimeConfig.parseBool(
                key: "capture_enabled",
                in: "capture_enabled = true\n\"\\u0063apture_enabled\" = false"
            ),
            "escaped semantic duplicate authorized capture"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-runtime-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("runtime.toml")
        try """
         capture_enabled = true # user preference
        capture_enabled_backup = true
          capture_enabled = false # duplicate
        # capture_enabled = true
        """.write(to: path, atomically: true, encoding: .utf8)

        let config = RuntimeConfig(path: path)
        precondition(!config.captureEnabled, "duplicate input must fail closed")
        let duplicateInput = try String(contentsOf: path, encoding: .utf8)
        do {
            try config.setCaptureEnabled(false)
            preconditionFailure("duplicate document write must be rejected")
        } catch {}
        let duplicateAfterRejectedWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            duplicateAfterRejectedWrite == duplicateInput,
            "rejected duplicate document was mutated"
        )
        precondition(!RuntimeConfig(path: path).captureEnabled, "capture must remain off after relaunch")

        try "capture_enabled = 1\n".write(to: path, atomically: true, encoding: .utf8)
        precondition(!RuntimeConfig(path: path).captureEnabled, "numeric authority must stay off")
        precondition(!RuntimeConfig(path: path).captureEnabled, "numeric authority changed on relaunch")
        do {
            try RuntimeConfig(path: path).setCaptureEnabled(false)
            preconditionFailure("wrong-typed authority write must be rejected")
        } catch {}
        let wrongTypedAfterRejectedWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            wrongTypedAfterRejectedWrite == "capture_enabled = 1\n",
            "rejected wrong-typed authority was mutated"
        )

        let escapedDuplicate = "capture_enabled = true\n\"\\u0063apture_enabled\" = false\n"
        try escapedDuplicate.write(to: path, atomically: true, encoding: .utf8)
        do {
            try RuntimeConfig(path: path).setCaptureEnabled(false)
            preconditionFailure("escaped semantic duplicate write must be rejected")
        } catch {}
        let escapedDuplicateAfterRejectedWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            escapedDuplicateAfterRejectedWrite == escapedDuplicate,
            "rejected escaped semantic duplicate was mutated"
        )

        try """
        "capture_enabled" = true # first semantic assignment
        capture_enabled = false
        'capture_enabled' = true
        capture_enabled_backup = true
        """.write(to: path, atomically: true, encoding: .utf8)
        precondition(!RuntimeConfig(path: path).captureEnabled, "semantic duplicates must fail closed")
        let semanticDuplicateInput = try String(contentsOf: path, encoding: .utf8)
        do {
            try RuntimeConfig(path: path).setCaptureEnabled(false)
            preconditionFailure("semantic duplicate write must be rejected")
        } catch {}
        let semanticDuplicateAfterRejectedWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            semanticDuplicateAfterRejectedWrite == semanticDuplicateInput,
            "rejected semantic duplicate document was mutated"
        )
        precondition(!RuntimeConfig(path: path).captureEnabled, "duplicate relaunch must remain off")

        let malformed = "capture_enabled = true\nunrelated = [1, 2\n"
        try malformed.write(to: path, atomically: true, encoding: .utf8)
        do {
            try RuntimeConfig(path: path).setCaptureEnabled(false)
            preconditionFailure("malformed whole document write must be rejected")
        } catch {}
        let malformedAfterRejectedWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            malformedAfterRejectedWrite == malformed,
            "rejected malformed document was mutated"
        )
        precondition(!RuntimeConfig(path: path).captureEnabled, "malformed relaunch must remain off")

        let multilineString = """
        notes = '''
        alpha
        [text]
        omega
        '''
        [capture]
        capture_enabled = true
        """
        try multilineString.write(to: path, atomically: true, encoding: .utf8)
        try RuntimeConfig(path: path).setCaptureEnabled(true)
        let multilineAfterWrite = try String(contentsOf: path, encoding: .utf8)
        precondition(
            RuntimeConfig(path: path).captureEnabled,
            "multiline string content was mistaken for a table header"
        )
        precondition(
            multilineAfterWrite.contains("[text]"),
            "multiline string semantics were not preserved"
        )

        try "[capture]\ncapture_enabled = true\n".write(
            to: path,
            atomically: true,
            encoding: .utf8
        )
        try RuntimeConfig(path: path).setCaptureEnabled(true)
        let rooted = try String(contentsOf: path, encoding: .utf8)
        precondition(rooted.contains("capture_enabled = true"))
        precondition(rooted.contains("[capture]"))
        precondition(RuntimeConfig(path: path).captureEnabled)
    }
}
