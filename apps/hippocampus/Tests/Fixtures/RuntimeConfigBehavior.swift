import Foundation

@main
struct RuntimeConfigBehavior {
    static func main() throws {
        precondition(
            !RuntimeConfig.parseBool(key: "capture_enabled", in: "capture_enabled = true\ncapture_enabled = malformed"),
            "any duplicate exact key must fail closed"
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
    }
}
