import Foundation

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
        try config.setCaptureEnabled(false)

        let relaunched = RuntimeConfig(path: path)
        let content = try String(contentsOf: path, encoding: .utf8)
        let exactAssignments = content.split(separator: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("capture_enabled =")
        }
        precondition(!relaunched.captureEnabled, "capture must remain off after relaunch")
        precondition(exactAssignments.count == 1, "duplicates must collapse")
        precondition(content.contains("capture_enabled_backup = true"), "prefix sibling lost")
        precondition(content.contains("# capture_enabled = true"), "comment lost")
        precondition(content.contains("# user preference"), "inline comment lost")

        try "capture_enabled = 1\n".write(to: path, atomically: true, encoding: .utf8)
        precondition(!RuntimeConfig(path: path).captureEnabled, "numeric authority must stay off")
        precondition(!RuntimeConfig(path: path).captureEnabled, "numeric authority changed on relaunch")

        try """
        "capture_enabled" = true # first semantic assignment
        capture_enabled = false
        'capture_enabled' = true
        capture_enabled_backup = true
        """.write(to: path, atomically: true, encoding: .utf8)
        precondition(!RuntimeConfig(path: path).captureEnabled, "semantic duplicates must fail closed")
        try RuntimeConfig(path: path).setCaptureEnabled(false)
        let collapsed = try String(contentsOf: path, encoding: .utf8)
        precondition(
            collapsed.split(separator: "\n").filter {
                RuntimeConfig.assignmentKey(in: String($0)) == "capture_enabled"
            }.count == 1,
            "semantic duplicates must collapse"
        )
        precondition(collapsed.contains("capture_enabled_backup = true"), "prefix sibling lost")
        precondition(!RuntimeConfig(path: path).captureEnabled, "collapsed relaunch must remain off")

        try "[capture]\ncapture_enabled = true\n".write(
            to: path,
            atomically: true,
            encoding: .utf8
        )
        try RuntimeConfig(path: path).setCaptureEnabled(true)
        let rooted = try String(contentsOf: path, encoding: .utf8)
        precondition(rooted.hasPrefix("capture_enabled = true\n[capture]"))
        precondition(RuntimeConfig(path: path).captureEnabled)
    }
}
