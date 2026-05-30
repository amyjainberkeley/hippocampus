// SPDX-License-Identifier: TBD-private
//
// UserAllowlistTOMLLoader — parse the user-mutable allowlist layer.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. ADR-0017 §3.2 (V2-P10) adds a
// second allowlist layer on top of the CSO-ratified baseline in
// `AllowlistTOMLLoader.swift`. The user-layer lives at
// `~/Library/Application Support/MCI/user-allowlist.toml`, is user-
// owned + mode 0600, and is mutated by the onboarding UI in
// `apps/onboarding/`. The capture-side helper unions
// `Allowlist.bundleIdSet` (baseline) with
// `UserAllowlist.captureEnabledBundleIds` (user-layer) when
// constructing the cascade — see `main.swift` for the wire.
//
// Trust contract (ADR-0017 §3.2 binding):
//   1. The user-layer STRICTLY ADDS to `knownSafeAppBundles`. Every
//      user-layer bundle still flows through the SAME §2–§7 cascade
//      arms + cascade-twice OCR redaction the baseline does. The
//      cascade cannot be widened past any §3/§4 redaction signal by a
//      user-layer entry.
//   2. The user-layer cannot remove a CSO baseline entry. (A future
//      CSO baseline `denylist` would gate user-layer entries; the
//      current contract leaves this enforceable but does not implement
//      it — no CSO baseline denylist exists yet.)
//   3. Per-event ADR-0030 §3 redaction (SMS-OTP regex + sensitive-
//      domain table + Mail-header check) applies identically to user-
//      layer-allowed bundles. The cascade does not distinguish source.
//   4. Per-app deep-hook opt-in (`deep_hook_enabled`) is read by the
//      agent-side per-plugin master switch (V2-P7b wires the read);
//      the helper does NOT consume that bit. Per ADR-0032 §3(a) the
//      master switch defaults OFF; V2-P10's UI is what flips it.
//
// File-permission gate:
//   - File MUST be mode 0600 (user-rw only). Group/world bits set ⇒
//     refuse with `insecureFilePermissions`. Prevents a confused-
//     deputy attack where another local process drops a malicious
//     user-allowlist into the user's home dir.
//   - File MUST be owned by the current user. Foreign-owner ⇒ refuse
//     with `notOwnedByCurrentUser`.
//
// Schema (TOML subset — strictly tighter than the baseline schema):
//
//     document = (entry-table | comment | blank)*
//     entry-table  = "[[entries]]" newline
//                     (kv-line | comment | blank){4,5}
//     kv-line  = "bundle_id"          "=" quoted-string newline
//              | "capture_enabled"    "=" bool-literal   newline
//              | "deep_hook_enabled"  "=" bool-literal   newline
//              | "added_at"           "=" quoted-string  newline
//              | "rationale"          "=" quoted-string  newline   (optional)
//     quoted-string = "\"" [^"\\\n]* "\""
//     bool-literal  = "true" | "false"
//
// `bundle_id`, `capture_enabled`, `deep_hook_enabled`, `added_at` are
// REQUIRED; `rationale` is OPTIONAL (humans add their own notes).
//
// Missing file ⇒ empty `UserAllowlist` (graceful default for a fresh
// install). The CALLER must treat the empty case as "no user opt-ins
// yet" — the baseline allowlist still gates the cascade.

import Foundation

/// A single user-layer allowlist entry.
public struct UserAllowlistEntry: Sendable, Equatable {
    public let bundleId: String
    public let captureEnabled: Bool
    public let deepHookEnabled: Bool
    /// ISO-8601-style date (yyyy-mm-dd) the user added the entry.
    public let addedAt: String
    /// Optional user-supplied note explaining why they added the bundle.
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

/// Errors the user-layer loader can surface.
public enum UserAllowlistError: Error, Equatable {
    case missingBundleId(line: Int)
    case missingCaptureEnabled(line: Int)
    case missingDeepHookEnabled(line: Int)
    case missingAddedAt(line: Int)
    case emptyValue(line: Int, key: String)
    case malformedKvLine(line: Int)
    case unexpectedLine(line: Int)
    case duplicateKey(line: Int, key: String)
    case invalidBoolean(line: Int, key: String)
    /// File mode has group/world bits set (S_IRWXG | S_IRWXO).
    case insecureFilePermissions(mode: UInt16)
    /// File is owned by a uid other than the current process's uid.
    case notOwnedByCurrentUser
}

/// In-memory snapshot of the user-layer allowlist.
public struct UserAllowlist: Sendable, Equatable {
    public let entries: [UserAllowlistEntry]

    public init(entries: [UserAllowlistEntry]) {
        self.entries = entries
    }

    /// Bundle ids the user has opted IN to capture. Unioned with the
    /// CSO baseline at cascade-construction time.
    public var captureEnabledBundleIds: Set<String> {
        Set(entries.filter { $0.captureEnabled }.map { $0.bundleId })
    }

    /// Bundle ids the user has opted IN to deep-hook (read by the
    /// agent-side per-plugin master switch in V2-P7b).
    public var deepHookEnabledBundleIds: Set<String> {
        Set(entries.filter { $0.deepHookEnabled }.map { $0.bundleId })
    }

    public static let empty = UserAllowlist(entries: [])
}

/// Loader for the user-mutable allowlist layer.
public struct UserAllowlistTOMLLoader: Sendable {
    public init() {}

    public func parse(_ source: String) throws -> [UserAllowlistEntry] {
        var entries: [UserAllowlistEntry] = []
        var pendingBundleId: String?
        var pendingCapture: Bool?
        var pendingDeepHook: Bool?
        var pendingAddedAt: String?
        var pendingRationale: String?
        var pendingStartLine = 0
        var inTable = false

        func flushPending() throws {
            guard inTable else { return }
            guard let bundleId = pendingBundleId else {
                throw UserAllowlistError.missingBundleId(line: pendingStartLine)
            }
            guard let capture = pendingCapture else {
                throw UserAllowlistError.missingCaptureEnabled(line: pendingStartLine)
            }
            guard let deepHook = pendingDeepHook else {
                throw UserAllowlistError.missingDeepHookEnabled(line: pendingStartLine)
            }
            guard let addedAt = pendingAddedAt else {
                throw UserAllowlistError.missingAddedAt(line: pendingStartLine)
            }
            entries.append(UserAllowlistEntry(
                bundleId: bundleId,
                captureEnabled: capture,
                deepHookEnabled: deepHook,
                addedAt: addedAt,
                rationale: pendingRationale
            ))
            pendingBundleId = nil
            pendingCapture = nil
            pendingDeepHook = nil
            pendingAddedAt = nil
            pendingRationale = nil
        }

        for (idx, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = idx + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line == "[[entries]]" {
                try flushPending()
                inTable = true
                pendingStartLine = lineNumber
                continue
            }

            guard inTable else {
                throw UserAllowlistError.unexpectedLine(line: lineNumber)
            }

            let (key, value) = try parseKV(line: line, lineNumber: lineNumber)

            switch key {
            case "bundle_id":
                if pendingBundleId != nil {
                    throw UserAllowlistError.duplicateKey(line: lineNumber, key: key)
                }
                guard case let .string(s) = value, !s.isEmpty else {
                    throw UserAllowlistError.emptyValue(line: lineNumber, key: key)
                }
                pendingBundleId = s
            case "capture_enabled":
                if pendingCapture != nil {
                    throw UserAllowlistError.duplicateKey(line: lineNumber, key: key)
                }
                guard case let .bool(b) = value else {
                    throw UserAllowlistError.invalidBoolean(line: lineNumber, key: key)
                }
                pendingCapture = b
            case "deep_hook_enabled":
                if pendingDeepHook != nil {
                    throw UserAllowlistError.duplicateKey(line: lineNumber, key: key)
                }
                guard case let .bool(b) = value else {
                    throw UserAllowlistError.invalidBoolean(line: lineNumber, key: key)
                }
                pendingDeepHook = b
            case "added_at":
                if pendingAddedAt != nil {
                    throw UserAllowlistError.duplicateKey(line: lineNumber, key: key)
                }
                guard case let .string(s) = value, !s.isEmpty else {
                    throw UserAllowlistError.emptyValue(line: lineNumber, key: key)
                }
                pendingAddedAt = s
            case "rationale":
                if pendingRationale != nil {
                    throw UserAllowlistError.duplicateKey(line: lineNumber, key: key)
                }
                guard case let .string(s) = value else {
                    throw UserAllowlistError.malformedKvLine(line: lineNumber)
                }
                pendingRationale = s
            default:
                throw UserAllowlistError.malformedKvLine(line: lineNumber)
            }
        }

        try flushPending()
        return entries
    }

    /// TOML value kinds the user-layer schema accepts.
    private enum Value {
        case string(String)
        case bool(Bool)
    }

    private func parseKV(line: String, lineNumber: Int) throws -> (key: String, value: Value) {
        guard let eqIdx = line.firstIndex(of: "=") else {
            throw UserAllowlistError.malformedKvLine(line: lineNumber)
        }
        let keyPart = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        let valuePart = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

        if valuePart == "true" {
            return (keyPart, .bool(true))
        }
        if valuePart == "false" {
            return (keyPart, .bool(false))
        }

        guard valuePart.count >= 2,
              valuePart.first == "\"",
              valuePart.last == "\"" else {
            throw UserAllowlistError.malformedKvLine(line: lineNumber)
        }
        let inner = valuePart.dropFirst().dropLast()
        if inner.contains("\"") || inner.contains("\\") {
            throw UserAllowlistError.malformedKvLine(line: lineNumber)
        }
        return (keyPart, .string(String(inner)))
    }
}

extension UserAllowlistTOMLLoader {
    /// Canonical user-layer path.
    public static var defaultUserAllowlistURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/user-allowlist.toml")
    }

    /// Load the user-layer from `defaultUserAllowlistURL`.
    ///
    /// Returns `UserAllowlist.empty` if the file is missing (no opt-ins
    /// yet — the graceful default state for a fresh install). Any other
    /// error (insecure perms, foreign owner, parse failure) is thrown
    /// — the caller MUST decide whether to fail-stop or fall back to
    /// empty + log. The helper's main.swift currently falls back to
    /// empty on any error to preserve the cascade's fail-closed default.
    public static func loadFromUserPath() throws -> UserAllowlist {
        let url = defaultUserAllowlistURL
        if !FileManager.default.fileExists(atPath: url.path) {
            return .empty
        }
        try validatePermissions(at: url)
        let source = try String(contentsOf: url, encoding: .utf8)
        let entries = try UserAllowlistTOMLLoader().parse(source)
        return UserAllowlist(entries: entries)
    }

    /// Refuse a user-allowlist whose file is world/group-readable or
    /// whose owner is not the current uid. ADR-0017 §3.2 trust contract.
    static func validatePermissions(at url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // 0o077 covers group + world rwx bits. The file MUST be user-rw only.
        if perms & 0o077 != 0 {
            throw UserAllowlistError.insecureFilePermissions(mode: perms)
        }
        let ownerId = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max
        if ownerId != UInt32(getuid()) {
            throw UserAllowlistError.notOwnedByCurrentUser
        }
    }
}
