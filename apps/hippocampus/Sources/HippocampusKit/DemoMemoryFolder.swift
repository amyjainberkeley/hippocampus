// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryFolder.swift — where Demo Memory lives (SPEC-DELTA 6): a folder
// of its own beside the person's memory, never inside it, with its own key.

import Foundation
import Security

/// Demo Memory's folder: the made-up week's store, its sealed screenshots,
/// its key, its calendar and the status the window reads beside the store.
///
/// The key is the folder's own: 32 random bytes in `demo.key`, readable by
/// this user only, made with the week and gone with it. It is never the
/// person's Keychain item, and Demo Memory never reads or writes the
/// Keychain at all: the window and the agent open the week through the file
/// key's path (`MCI_DEVELOPMENT_FILE_KEY`), which also keeps the window from
/// writing About You verdicts that the person's own memory would later take.
public struct DemoMemoryFolder: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// `~/Library/Application Support/Hippocampus/Demo Memory`.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(url: home.appendingPathComponent("Library/Application Support/Hippocampus/Demo Memory",
                                              isDirectory: true))
    }

    /// The person's own memory's folder, `~/Library/Application Support/MCI`.
    /// Demo Memory's folder is never this one, nor inside it.
    public static func personsOwnFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MCI", isDirectory: true).standardizedFileURL
    }

    public var database: URL { url.appendingPathComponent("mci.sqlite") }
    public var blobs: URL { url.appendingPathComponent("blobs", isDirectory: true) }
    public var keyFile: URL { url.appendingPathComponent("demo.key") }
    /// What the window reads beside the store to show remembering's state.
    public var captureStatus: URL { url.appendingPathComponent("capture-status.json") }
    /// The made-up calendar, which the window's demo calendar reads.
    public var calendar: URL { url.appendingPathComponent("demo-calendar.json") }
    /// Kept while Demo Memory is in use, so a relaunch after a crash goes
    /// back to the person's own memory and restores remembering.
    public var inUse: URL { url.appendingPathComponent("in-use.json") }
    /// The drawing tool's lists, while the week is made.
    var making: URL { url.appendingPathComponent("making", isDirectory: true) }
    /// Marks the folder as Demo Memory's, so nothing else is ever removed.
    var marker: URL { url.appendingPathComponent(".hippocampus-demo-memory") }

    public enum FolderError: Error, Equatable {
        /// The folder is the person's own memory's, inside it, or a link.
        case unsafeLocation
        /// Something else is already at the folder's place.
        case notOurs
        case couldNotWrite
    }

    /// Whether the folder is somewhere Demo Memory may write: not the
    /// person's own memory's folder or anywhere inside it, and no link.
    public func isSafe(home: URL) -> Bool {
        let own = Self.resolved(Self.personsOwnFolder(home: home)).path
        let mine = Self.resolved(url).path
        if mine == own || mine.hasPrefix(own + "/") || own.hasPrefix(mine + "/") { return false }
        // The folder itself is never a link, even one that leads nowhere.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type != .typeSymbolicLink
    }

    /// Whether Demo Memory's folder is there.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    /// An empty folder of Demo Memory's own, readable by this user only. A
    /// week left from before is removed first; anything else at its place
    /// is never touched.
    func prepareEmpty(home: URL) throws {
        guard isSafe(home: home) else { throw FolderError.unsafeLocation }
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            guard exists || ((try? manager.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false) else {
                throw FolderError.notOurs
            }
            try manager.removeItem(at: url)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw FolderError.couldNotWrite }
    }

    /// A fresh key for this week only: 64 hexadecimal characters in
    /// `demo.key`, which only this user can read. Returns it.
    func makeKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FolderError.couldNotWrite
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try Self.writeNew(Data(hex.utf8), to: keyFile)
        return hex
    }

    /// Demo Memory's record of what it changed, kept while it is in use.
    public struct InUse: Codable, Equatable, Sendable {
        public var version = 1
        /// When it started.
        public var enteredAt: Date
        /// Whether remembering was already paused, so leaving leaves it so.
        public var wasPaused: Bool

        public init(enteredAt: Date, wasPaused: Bool) {
            self.enteredAt = enteredAt
            self.wasPaused = wasPaused
        }

        enum CodingKeys: String, CodingKey {
            case version, enteredAt = "entered_at", wasPaused = "was_paused"
        }
    }

    func writeInUse(_ record: InUse) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try Self.replace(encoder.encode(record), at: inUse)
    }

    /// The record a run left, if Demo Memory was in use when it ended.
    public func readInUse() -> InUse? {
        guard exists, let data = try? Data(contentsOf: inUse) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(InUse.self, from: data), record.version == 1 else { return nil }
        return record
    }

    /// What the window reads beside the store: remembering, saved just now,
    /// as on the made-up Mac. Rewritten while Demo Memory is in use, so the
    /// window's Now stays live.
    func writeCaptureStatus(now: Date, moments: Int, screenshots: Int) throws {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = format.string(from: now)
        let text = """
            {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)", \
            "stored_frame_count": \(max(0, moments)), "stored_screenshot_count": \(max(0, screenshots)), \
            "suppression_reason": null, "blocked_reason": null}
            """
        try Self.replace(Data(text.utf8), at: captureStatus)
    }

    /// Removes Demo Memory's folder, and only it.
    func remove() {
        guard exists || !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Files

    /// A new file, readable by this user only; never over an existing one.
    static func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FolderError.couldNotWrite }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { write(descriptor, $0, buffer.count) } ?? 0
        }
        guard written == data.count else { throw FolderError.couldNotWrite }
    }

    /// Replaces a file in one step, readable by this user only.
    static func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try writeNew(data, to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw FolderError.couldNotWrite
        }
    }

    static func resolved(_ url: URL) -> URL {
        // Resolve as much of the path as exists, so a link anywhere above
        // is seen through.
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in rest { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }
}
