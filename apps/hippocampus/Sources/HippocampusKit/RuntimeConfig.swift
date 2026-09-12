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

        parsed[key] = value
        var content = parsed.convert(to: .toml)
        if !content.hasSuffix("\n") { content.append("\n") }
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

    package static func parseBool(key: String, in text: String) -> Bool {
        guard let table = try? TOMLTable(string: text) else { return false }
        return table[key]?.bool ?? false
    }
}
