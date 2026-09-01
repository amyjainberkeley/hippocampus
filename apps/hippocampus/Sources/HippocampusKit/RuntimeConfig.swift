// SPDX-License-Identifier: TBD-private
import Foundation
import TOMLKit

public protocol RuntimeConfiguring: Sendable {
    var crashReportOptedIn: Bool { get }
    var captureEnabled: Bool { get }
    func setCrashReportOptedIn(_ value: Bool) throws
    func setCaptureEnabled(_ value: Bool) throws
}

public enum RuntimeConfigError: LocalizedError, Equatable {
    case invalidUTF8
    case invalidDocument
    case invalidBooleanValue(String)
    case invalidEmittedDocument

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "runtime.toml is not valid UTF-8."
        case .invalidDocument:
            "runtime.toml is not a valid, unambiguous TOML document."
        case .invalidBooleanValue(let key):
            "The root \(key) value must be a TOML boolean."
        case .invalidEmittedDocument:
            "The updated runtime configuration did not pass TOML validation."
        }
    }
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
        guard let text = try? existingText(), !text.isEmpty else { return false }
        return Self.parseBool(key: key, in: text)
    }

    private func setBool(_ value: Bool, for key: String) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let original = try existingText()
        let parsed: TOMLTable
        do {
            parsed = try TOMLTable(string: original)
        } catch {
            throw RuntimeConfigError.invalidDocument
        }
        if let existing = parsed[key], existing.bool == nil {
            throw RuntimeConfigError.invalidBooleanValue(key)
        }

        var updated: [String] = []
        var replaced = false
        var inRootTable = true
        for line in Self.lines(in: original) {
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
        do {
            let reparsed = try TOMLTable(string: content)
            guard reparsed[key]?.bool == value else {
                throw RuntimeConfigError.invalidEmittedDocument
            }
        } catch let error as RuntimeConfigError {
            throw error
        } catch {
            throw RuntimeConfigError.invalidEmittedDocument
        }
        try content.write(to: path, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )
    }

    private func existingText() throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        let data = try Data(contentsOf: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeConfigError.invalidUTF8
        }
        return text
    }

    private static func lines(in text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    package static func parseBool(key: String, in text: String) -> Bool {
        guard let table = try? TOMLTable(string: text) else { return false }
        return table[key]?.bool ?? false
    }

    /// This lexical helper runs only after TOMLKit validates the full document.
    /// Parsing the key probe with the same conforming parser lets the editor
    /// recognize quoted Unicode escapes without becoming a second authority.
    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let equals = equalsAfterKey(in: line) else { return nil }
        let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty,
              let probe = try? TOMLTable(string: "\(rawKey) = true")
        else { return nil }
        return ["capture_enabled", "crash_report_opted_in"].first {
            probe[$0]?.bool == true
        }
    }

    private static func replacingBool(in line: String, key: String, value: Bool) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let comment = commentStart(in: line).map { " " + line[$0...] } ?? ""
        return "\(leading)\(key) = \(value)\(comment)"
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

    private static func isTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }
}
