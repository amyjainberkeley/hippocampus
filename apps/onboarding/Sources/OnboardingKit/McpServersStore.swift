// SPDX-License-Identifier: Apache-2.0
//
// McpServersStore — V2-MCP-2 user-mutable MCP-server registration
// layer. Mirrors the V2-P10 `UserAllowlistStore` pattern (PR #251)
// because the agent reads the SAME file the onboarding writes.
//
// File contract (ADR-0001 amendment 2026-05-31, Audit row #5):
//   - Path: `~/Library/Application Support/MCI/Config.noindex/mcp-servers.toml`.
//     The file can carry an `Authorization` header, so it lives in a
//     `.noindex` folder, which Spotlight does not index (storage-security
//     review S9). A file an earlier release left in `MCI/` itself is read
//     when the new one is missing, and removed once the new one is saved.
//   - Mode 0600, owned by current user, from the moment it exists: it is
//     written to a private temporary file and renamed into place, so the
//     agent's `core/mcp-client/src/config.rs` loader's permission gate
//     accepts it and no other account can ever read it.
//   - Schema: per-entry `name` + `url` + optional `auth_header`
//     + optional `enabled` (default true).
//   - Loopback-only: `url` validation happens via the agent's
//     `LoopbackHost::parse` (Rust). The Swift side here does a
//     conservative pre-check at registration time (`isLikelyLoopbackURL`)
//     so the user gets immediate feedback in the UI even before the
//     agent restart.

import Darwin
import Foundation

/// One row of the MCP-server registration file.
///
/// Mirrors the `[[server]]` block consumed by `core/mcp-client/src/
/// config.rs`. `auth_header` is rendered into the file verbatim;
/// `enabled` defaults to true on read when absent.
public struct McpServerEntry: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public var url: String
    public var authHeader: String?
    public var enabled: Bool

    public init(
        name: String,
        url: String,
        authHeader: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.url = url
        self.authHeader = authHeader
        self.enabled = enabled
    }
}

/// Persistence surface for the user-mutable MCP-server list.
public protocol McpServersStore: Sendable {
    func load() async -> [McpServerEntry]
    func save(_ entries: [McpServerEntry]) async throws
}

/// Real implementation backed by
/// `~/Library/Application Support/MCI/Config.noindex/mcp-servers.toml`.
public final class FileMcpServersStore: McpServersStore {
    private let url: URL
    /// Where an earlier release kept the file: `MCI/` itself, which
    /// Spotlight indexes. Read when `url` is missing; removed on save.
    private let legacyURL: URL?

    public init(url: URL = FileMcpServersStore.defaultURL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL ?? Self.legacyURL(for: url)
    }

    /// The `.noindex` folder the file lives in.
    public static let configFolderName = "Config.noindex"

    public static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
            .appendingPathComponent(configFolderName, isDirectory: true)
            .appendingPathComponent("mcp-servers.toml")
    }

    /// `MCI/mcp-servers.toml` for `MCI/Config.noindex/mcp-servers.toml`;
    /// nil for a file outside a `Config.noindex` folder.
    static func legacyURL(for url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent == configFolderName else { return nil }
        return folder.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
    }

    public func load() async -> [McpServerEntry] {
        let source = (try? String(contentsOf: url, encoding: .utf8))
            ?? legacyURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard let source else { return [] }
        return (try? McpServersTOMLDocument.parse(source)) ?? []
    }

    public func save(_ entries: [McpServerEntry]) async throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try PrivateFileWriter.write(Data(McpServersTOMLDocument.emit(entries).utf8), to: url)
        // The new file is in place: the copy Spotlight indexed goes.
        if let legacyURL, legacyURL.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}

/// Writes a file that only this user can read from the moment it exists:
/// a temporary file created mode 0600 beside the target, synced, then
/// renamed over it (storage-security review S9). Foundation's atomic write
/// creates its temporary with the umask's mode (0644), so a file it writes
/// is readable by other accounts until a later chmod.
public enum PrivateFileWriter {
    public enum WriteError: Error, Equatable {
        case couldNotCreate(Int32)
        case couldNotWrite(Int32)
        case couldNotReplace(Int32)
    }

    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WriteError.couldNotCreate(errno) }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while written < buffer.count {
                let result = Darwin.write(descriptor, base + written, buffer.count - written)
                if result <= 0 { return false }
                written += result
            }
            return true
        }
        let writeErrno = errno
        _ = fchmod(descriptor, 0o600)
        _ = fsync(descriptor)
        Darwin.close(descriptor)
        guard ok else {
            _ = Darwin.unlink(temporary.path)
            throw WriteError.couldNotWrite(writeErrno)
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let renameErrno = errno
            _ = Darwin.unlink(temporary.path)
            throw WriteError.couldNotReplace(renameErrno)
        }
    }
}

/// In-memory stub for headless tests.
public actor InMemoryMcpServersStore: McpServersStore {
    private var _entries: [McpServerEntry]

    public init(entries: [McpServerEntry] = []) {
        self._entries = entries
    }

    public func load() async -> [McpServerEntry] {
        _entries
    }

    public func save(_ entries: [McpServerEntry]) async throws {
        _entries = entries
    }

    /// Test-only — peek at current state.
    public func entriesForTest() async -> [McpServerEntry] {
        _entries
    }
}
