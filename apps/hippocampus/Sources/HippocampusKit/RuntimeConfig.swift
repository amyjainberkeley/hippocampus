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
        var inRootTable = true
        for line in existingLines() {
            if inRootTable, Self.isTableHeader(line) {
                if !replaced {
                    updated.append("\(key) = \(value)")
                    replaced = true
                }
                inRootTable = false
            }
            guard inRootTable, Self.assignmentKey(in: line) == key else {
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
        var assignments: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isTableHeader(line) { break }
            if assignmentKey(in: line) == key { assignments.append(line) }
        }
        guard assignments.count == 1,
              let value = tomlBooleanValue(in: assignments[0])
        else { return false }
        return value
    }

    /// Deliberately narrow TOML key grammar for the two runtime booleans.
    /// Bare, basic-quoted, and literal-quoted exact keys are recognized so
    /// semantically duplicate spellings cannot create a second authority.
    static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let contentStart = trimmed.index(after: trimmed.startIndex)
            guard let closing = trimmed[contentStart...].firstIndex(of: quote) else {
                return nil
            }
            let key = String(trimmed[contentStart..<closing])
            guard isRuntimeKey(key) else { return key }
            let suffix = trimmed[trimmed.index(after: closing)...]
                .trimmingCharacters(in: .whitespaces)
            // Return the semantic key even for malformed exact assignments;
            // reads then fail closed and writes replace the bad authority.
            guard suffix.isEmpty || suffix.hasPrefix("=") else { return key }
            return key
        }

        let keyEnd = trimmed.firstIndex { character in
            character == "=" || character == " " || character == "\t"
        } ?? trimmed.endIndex
        let key = String(trimmed[..<keyEnd])
        guard !key.isEmpty else { return nil }
        return key
    }

    private static func replacingBool(in line: String, key: String, value: Bool) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let comment = commentStart(in: line).map { " " + line[$0...] } ?? ""
        return "\(leading)\(key) = \(value)\(comment)"
    }

    private static func tomlBooleanValue(in line: String) -> Bool? {
        guard let key = assignmentKey(in: line),
              let equals = equalsAfterKey(in: line),
              isValidKeySyntax(String(line[..<equals]), key: key)
        else { return nil }
        let valueStart = line.index(after: equals)
        let valueAndComment = String(line[valueStart...])
        let valueEnd = commentStart(in: valueAndComment) ?? valueAndComment.endIndex
        let rawValue = valueAndComment[..<valueEnd].trimmingCharacters(in: .whitespaces)
        switch rawValue {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func equalsAfterKey(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && character == "\\" && !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote && !escaped { quote = nil }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            } else if character == "#" {
                return nil
            }
        }
        return nil
    }

    private static func commentStart(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && character == "\\" && !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote && !escaped { quote = nil }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return index
            }
        }
        return nil
    }

    private static func isRuntimeKey(_ key: String) -> Bool {
        key == "capture_enabled" || key == "crash_report_opted_in"
    }

    private static func isValidKeySyntax(_ rawKey: String, key: String) -> Bool {
        let trimmed = rawKey.trimmingCharacters(in: .whitespaces)
        return trimmed == key || trimmed == "\"\(key)\"" || trimmed == "'\(key)'"
    }

    private static func isTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }
}
