// SPDX-License-Identifier: Apache-2.0
import Foundation
import TOMLKit

public protocol RuntimeConfiguring: Sendable {
    var crashReportOptedIn: Bool { get }
    var captureEnabled: Bool { get }
    /// When the settings file last changed; nil when unknown.
    var modifiedAt: Date? { get }
    func setCrashReportOptedIn(_ value: Bool) throws
    func setCaptureEnabled(_ value: Bool) throws
}

extension RuntimeConfiguring {
    public var modifiedAt: Date? { nil }
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
/// Mode 0600, like every file Hippocampus writes (reports/e2e, finding 5; storage-security
/// review S9: it was 0644, and the home folder lets other accounts in), although these
/// are non-sensitive settings (capture gate, crash-report opt-in,
/// and pictures of side windows: whether they are kept, their budget, and when Forget
/// Pictures of Other Windows… was confirmed). Capture changes are enforced by the supervisor
/// through a child restart; this value itself remains a simple atomic on-disk preference.
/// The capture helper and the agent read the side-picture keys from this file themselves,
/// so a change takes effect at their next read without a restart.
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

    public var modifiedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    public func setCrashReportOptedIn(_ value: Bool) throws {
        try setBool(value, for: "crash_report_opted_in")
    }

    /// Remembering on or off. The first yes ever (setup's Start Remembering)
    /// also turns on pictures of side windows, which setup's promise covers
    /// ("Text and screenshots of your screen", SPEC 6.1 and 7.6). Anyone who
    /// said yes before them keeps them off until they turn them on: consent
    /// never grows on its own.
    public func setCaptureEnabled(_ value: Bool) throws {
        try update(requiringBooleans: ["capture_enabled"]) { table in
            if value, !table.contains(key: "capture_enabled"), !table.contains(key: Self.sideWindowPicturesKey) {
                table[Self.sideWindowPicturesKey] = true
            }
            table["capture_enabled"] = value
        } verify: { $0["capture_enabled"]?.bool == value }
    }

    // MARK: Pictures of side windows (SPEC 6)

    static let sideWindowPicturesKey = "side_window_pictures"
    static let sidePicturesBudgetKey = "side_pictures_budget_mb"
    static let deleteSidePicturesKey = "delete_side_pictures_requested_at"

    /// What this file says about pictures of side windows. A file that
    /// cannot be read, or says nothing, reads as off with the default budget.
    public var sidePictures: SidePictureSettings {
        guard let text = try? existingText(), !text.isEmpty, let table = try? TOMLTable(string: text) else {
            return SidePictureSettings()
        }
        let budget = table[Self.sidePicturesBudgetKey]?.int.flatMap {
            SidePictureSettings.budgetChoicesMB.contains($0) ? $0 : nil
        }
        let deleteAt = table[Self.deleteSidePicturesKey]?.int.flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
        }
        return SidePictureSettings(enabled: table[Self.sideWindowPicturesKey]?.bool ?? false,
                                   budgetMB: budget, deleteRequestedAt: deleteAt)
    }

    /// Keep pictures of side windows, or stop keeping new ones at once.
    public func setSideWindowPictures(_ value: Bool) throws {
        try update(requiringBooleans: [Self.sideWindowPicturesKey]) { table in
            table[Self.sideWindowPicturesKey] = value
        } verify: { $0[Self.sideWindowPicturesKey]?.bool == value }
    }

    /// Use at most 1, 2 or 5 GB.
    public func setSidePicturesBudgetMB(_ megabytes: Int) throws {
        guard SidePictureSettings.budgetChoicesMB.contains(megabytes) else {
            throw RuntimeConfigError.invalidDocument
        }
        try update(requiringBooleans: []) { table in
            table[Self.sidePicturesBudgetKey] = megabytes
        } verify: { $0[Self.sidePicturesBudgetKey]?.int == megabytes }
    }

    /// Forget Pictures of Other Windows… was confirmed at `date`: the agent
    /// removes every side picture kept until then. Their text stays.
    public func requestDeleteSidePictures(at date: Date) throws {
        let seconds = max(1, Int(date.timeIntervalSince1970.rounded(.up)))
        try update(requiringBooleans: []) { table in
            table[Self.deleteSidePicturesKey] = seconds
        } verify: { $0[Self.deleteSidePicturesKey]?.int == seconds }
    }

    private func boolValue(for key: String) -> Bool {
        guard let text = try? existingText(), !text.isEmpty else { return false }
        return Self.parseBool(key: key, in: text)
    }

    private func setBool(_ value: Bool, for key: String) throws {
        // The parsed document is changed, never the text (the product-truth
        // lane holds this line).
        try update(requiringBooleans: [key]) { parsed in
            parsed[key] = value
        } verify: { $0[key]?.bool == value }
    }

    /// Change the document with `change`, check the result with `verify`,
    /// and write it atomically with mode 0644. Keys in `requiringBooleans`
    /// that hold anything but a boolean stop the write, as before.
    private func update(
        requiringBooleans keys: [String],
        _ change: (TOMLTable) throws -> Void,
        verify: (TOMLTable) -> Bool
    ) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let original = try existingText()
        let parsed: TOMLTable
        do {
            parsed = try TOMLTable(string: original)
        } catch {
            throw RuntimeConfigError.invalidDocument
        }
        for key in keys {
            if let existing = parsed[key], existing.bool == nil {
                throw RuntimeConfigError.invalidBooleanValue(key)
            }
        }

        try change(parsed)
        var content = parsed.convert(to: .toml)
        if !content.hasSuffix("\n") { content.append("\n") }
        do {
            let reparsed = try TOMLTable(string: content)
            guard verify(reparsed) else {
                throw RuntimeConfigError.invalidEmittedDocument
            }
        } catch let error as RuntimeConfigError {
            throw error
        } catch {
            throw RuntimeConfigError.invalidEmittedDocument
        }
        try PrivateFileWriter.write(content, to: path)
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

/// Pictures of the windows beside the one in front, as `runtime.toml` holds
/// them (SPEC 6): kept or not, the budget, and when Forget Pictures of Other
/// Windows… was last confirmed. The capture helper and the agent read the
/// same keys.
public struct SidePictureSettings: Equatable, Sendable {
    /// Preferences' "Use at most" choices, in MB as the Mac counts them.
    public static let budgetChoicesMB = [1_000, 2_000, 5_000]
    /// The budget shown when none was chosen.
    public static let defaultBudgetMB = 2_000

    public var enabled: Bool
    public var budgetMB: Int?
    public var deleteRequestedAt: Date?

    public init(enabled: Bool = false, budgetMB: Int? = nil, deleteRequestedAt: Date? = nil) {
        self.enabled = enabled
        self.budgetMB = budgetMB
        self.deleteRequestedAt = deleteRequestedAt
    }
}
