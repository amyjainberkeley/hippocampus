// SPDX-License-Identifier: TBD-private
//
// UserAllowlistStore — V2-P10 user-mutable allowlist layer.
//
// Headless-testable persistence for the per-bundle capture + deep-hook
// opt-ins the onboarding UI collects. Mirrors the schema parsed by
// `UserAllowlistTOMLLoader` in MCICaptureHelperKit; the helper reads
// the same file the onboarding writes.
//
// File contract (ADR-0017 §3.2 binding):
//   - Path: `~/Library/Application Support/MCI/user-allowlist.toml`.
//   - Mode 0600, owned by current user. The store sets these explicitly
//     on every write to keep the file in compliance with the helper's
//     `UserAllowlistTOMLLoader.validatePermissions` gate.
//   - Schema: per-entry `bundle_id` + `capture_enabled` + `deep_hook_enabled`
//     + `added_at` + optional `rationale`.

import Foundation

/// One row of the user-mutable allowlist.
///
/// Mirrors `UserAllowlistEntry` in MCICaptureHelperKit. The two types
/// live in separate SwiftPM packages because OnboardingKit is bundled
/// into the onboarding `.app` while the helper has its own SPM target;
/// the file format is the shared contract.
public struct UserAllowlistEntry: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public var captureEnabled: Bool
    public var deepHookEnabled: Bool
    public let addedAt: String
    public let rationale: String?

    public init(
        bundleId: String,
        captureEnabled: Bool,
        deepHookEnabled: Bool,
        addedAt: String,
        rationale: String? = nil
    ) {
        self.bundleId = bundleId
        self.captureEnabled = captureEnabled
        self.deepHookEnabled = deepHookEnabled
        self.addedAt = addedAt
        self.rationale = rationale
    }
}

/// Persistence surface for the user-mutable allowlist.
public protocol UserAllowlistStore: Sendable {
    func load() async -> [UserAllowlistEntry]
    func save(_ entries: [UserAllowlistEntry]) async throws
}

/// Real implementation backed by `~/Library/Application Support/MCI/user-allowlist.toml`.
public final class FileUserAllowlistStore: UserAllowlistStore {
    private let url: URL

    public init(url: URL = FileUserAllowlistStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/user-allowlist.toml")
    }

    public func load() async -> [UserAllowlistEntry] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return (try? UserAllowlistTOMLDocument.parse(source)) ?? []
    }

    public func save(_ entries: [UserAllowlistEntry]) async throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let source = UserAllowlistTOMLDocument.emit(entries)
        try source.write(to: url, atomically: true, encoding: .utf8)
        // Re-tighten mode after the atomic-write replaces the file —
        // NSData's atomic write resets the file's permissions to the
        // umask default; the helper's `validatePermissions` gate refuses
        // anything with group/world bits set, so we re-tighten here.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}

/// In-memory stub for headless tests.
public actor InMemoryUserAllowlistStore: UserAllowlistStore {
    private var _entries: [UserAllowlistEntry]

    public init(entries: [UserAllowlistEntry] = []) {
        self._entries = entries
    }

    public func load() async -> [UserAllowlistEntry] {
        _entries
    }

    public func save(_ entries: [UserAllowlistEntry]) async throws {
        _entries = entries
    }

    /// Test-only — peek at current state.
    public func entriesForTest() async -> [UserAllowlistEntry] {
        _entries
    }
}
