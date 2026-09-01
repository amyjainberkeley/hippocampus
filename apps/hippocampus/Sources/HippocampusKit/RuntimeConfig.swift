// SPDX-License-Identifier: TBD-private
import Foundation

public protocol RuntimeConfiguring: Sendable {
    var crashReportOptedIn: Bool { get }
    var captureEnabled: Bool { get }
    func setCrashReportOptedIn(_ value: Bool) throws
    func setCaptureEnabled(_ value: Bool) throws
}

/// Reads/writes `~/.config/hippocampus/runtime.toml`.
///
/// CSO: mode 0644 — non-sensitive settings (capture gate and crash-report opt-in).
/// Capture changes are enforced by the supervisor through a child restart;
/// this value itself remains a simple atomic on-disk preference.
public struct RuntimeConfig: RuntimeConfiguring, Sendable {
    public let path: URL

    public init(path: URL? = nil) {
        self.path = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hippocampus/runtime.toml")
    }

    public var crashReportOptedIn: Bool {
        get {
            boolValue(for: "crash_report_opted_in")
        }
    }

    public var captureEnabled: Bool {
        boolValue(for: "capture_enabled")
    }

    public func setCrashReportOptedIn(_ value: Bool) throws {
        try setBool(value, for: "crash_report_opted_in")
    }

    public func setCaptureEnabled(_ value: Bool) throws {
        try setBool(value, for: "capture_enabled")
    }

    private func boolValue(for key: String) -> Bool {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return Self.parseBool(key: key, in: text)
    }

    private func setBool(_ value: Bool, for key: String) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var updated: [String] = []
        var replaced = false
        for line in existingLines() {
            guard Self.assignmentKey(in: line) == key else {
                updated.append(line)
                continue
            }
            if !replaced {
                updated.append(Self.replacingBool(in: line, key: key, value: value))
                replaced = true
            }
        }
        if !replaced { updated.append("\(key) = \(value)") }

        let content = updated.joined(separator: "\n") + "\n"
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
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func parseBool(key: String, in text: String) -> Bool {
        let assignments = text.components(separatedBy: "\n").filter {
            assignmentKey(in: $0) == key
        }
        guard assignments.count == 1,
              let equals = assignments[0].firstIndex(of: "=")
        else { return false }
        let rawValue = assignments[0][assignments[0].index(after: equals)...]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return rawValue == "true" || rawValue == "1"
    }

    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=")
        else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return key
    }

    private static func replacingBool(in line: String, key: String, value: Bool) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let comment = line.firstIndex(of: "#").map { " " + line[$0...] } ?? ""
        return "\(leading)\(key) = \(value)\(comment)"
    }
}
