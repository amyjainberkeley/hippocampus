// SPDX-License-Identifier: TBD-private
import Foundation

/// Reads/writes `~/.config/hippocampus/runtime.toml`.
///
/// CSO: mode 0644 — non-sensitive setting (crash-report opt-in boolean).
/// Supervisor reads on next spawn; no live reload to avoid mid-session
/// env-var dance.
public struct RuntimeConfig: Sendable {
    public let path: URL

    public init(path: URL? = nil) {
        self.path = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hippocampus/runtime.toml")
    }

    public var crashReportOptedIn: Bool {
        get {
            guard let data = try? Data(contentsOf: path),
                  let text = String(data: data, encoding: .utf8)
            else { return false }
            return Self.parseBool(key: "crash_report_opted_in", in: text)
        }
    }

    public func setCrashReportOptedIn(_ value: Bool) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var lines = existingLines()
        let newLine = "crash_report_opted_in = \(value)"

        if let idx = lines.firstIndex(where: { $0.hasPrefix("crash_report_opted_in") }) {
            lines[idx] = newLine
        } else {
            lines.append(newLine)
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: path, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )
    }

    private func existingLines() -> [String] {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func parseBool(key: String, in text: String) -> Bool {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if k == key {
                return v == "true" || v == "1"
            }
        }
        return false
    }
}
