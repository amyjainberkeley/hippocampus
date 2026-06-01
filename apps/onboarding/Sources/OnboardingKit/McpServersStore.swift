// SPDX-License-Identifier: TBD-private
//
// McpServersStore — V2-MCP-2 user-mutable MCP-server registration
// layer. Mirrors the V2-P10 `UserAllowlistStore` pattern (PR #251)
// because the agent reads the SAME file the onboarding writes.
//
// File contract (ADR-0001 amendment 2026-05-31, Audit row #5):
//   - Path: `~/Library/Application Support/MCI/mcp-servers.toml`.
//   - Mode 0600, owned by current user. The store sets these explicitly
//     on every write so the agent's `core/mcp-client/src/config.rs`
//     loader's permission gate accepts the file.
//   - Schema: per-entry `name` + `url` + optional `auth_header`
//     + optional `enabled` (default true).
//   - Loopback-only: `url` validation happens via the agent's
//     `LoopbackHost::parse` (Rust). The Swift side here does a
//     conservative pre-check at registration time (`isLikelyLoopbackURL`)
//     so the user gets immediate feedback in the UI even before the
//     agent restart.

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

/// Real implementation backed by `~/Library/Application Support/MCI/mcp-servers.toml`.
public final class FileMcpServersStore: McpServersStore {
    private let url: URL

    public init(url: URL = FileMcpServersStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/mcp-servers.toml")
    }

    public func load() async -> [McpServerEntry] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return (try? McpServersTOMLDocument.parse(source)) ?? []
    }

    public func save(_ entries: [McpServerEntry]) async throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let source = McpServersTOMLDocument.emit(entries)
        try source.write(to: url, atomically: true, encoding: .utf8)
        // Re-tighten mode after the atomic write — Foundation's
        // atomic-write resets the file's permissions to the umask
        // default. Mirror UserAllowlistStore's discipline (PR #251)
        // because the agent's loader refuses anything with group/world
        // bits set (Audit row #5).
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
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
