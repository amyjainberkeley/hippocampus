// Read-only key-wrap inspection surface (DOGFOOD_V1 #28).
//
// Mirrors `HippocampusKit/KeyWrapAudit.swift`. Kept in sync by design
// rather than by a shared package — the onboarding executable and the
// Hippocampus executable do not (and should not) depend on each
// other's libraries.
//
// PROTECTED-SET ADJACENT (AGENT_PROTOCOL §5). Read-only over the
// existing wrap surface; does not change the wrap policy. Content-
// free: never returns key bytes, store contents, or anything derived
// from event content.

import Foundation

public struct KeyWrapAuditReport: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case production
        case interim
        case devOnly
    }

    public enum RevealAffordance: Sendable, Equatable {
        case showInFinder(URL)
        case showInKeychainAccess(itemName: String)
        case none
    }

    public let implementationName: String
    public let severity: Severity
    public let sealed: Bool
    public let aclDescription: String
    public let identifier: String
    public let reveal: RevealAffordance
    public let notes: [String]
    public let generatedAt: Date

    public init(
        implementationName: String,
        severity: Severity,
        sealed: Bool,
        aclDescription: String,
        identifier: String,
        reveal: RevealAffordance,
        notes: [String],
        generatedAt: Date = Date()
    ) {
        self.implementationName = implementationName
        self.severity = severity
        self.sealed = sealed
        self.aclDescription = aclDescription
        self.identifier = identifier
        self.reveal = reveal
        self.notes = notes
        self.generatedAt = generatedAt
    }
}

public enum KeyWrapAuditor {
    /// Inspect a `FileKeyStore`-style wrap (the current interim wrap
    /// until ADR-0017 §6 lands macOS Keychain backing). Reads only
    /// file existence + POSIX mode + size. Never opens the file's
    /// contents.
    public static func inspectFile(at path: URL, now: Date = Date()) -> KeyWrapAuditReport {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path.path)
        var aclDescription = "POSIX 0600 (owner-only read/write)"
        var notes: [String] = [
            "Interim wrap per ADR-0017 §6 — Phase 4 replaces this with macOS Keychain backing.",
            "File lives in your user-only Application Support directory.",
        ]

        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let perms = attrs[.posixPermissions] as? Int {
                let octal = String(perms, radix: 8)
                if perms == 0o600 {
                    aclDescription = "POSIX 0600 (owner-only read/write) — verified"
                } else {
                    aclDescription = "POSIX 0\(octal) — UNEXPECTED, should be 0600"
                    notes.append("Permission mode is not 0600. Re-run onboarding to regenerate the key file with safe permissions.")
                }
            }
        } else {
            notes.insert("Key file not found on disk — onboarding has not generated a key yet, or it was deleted.", at: 0)
        }

        return KeyWrapAuditReport(
            implementationName: "FileKeyStore (interim)",
            severity: .interim,
            sealed: exists,
            aclDescription: aclDescription,
            identifier: path.path,
            reveal: .showInFinder(path),
            notes: notes,
            generatedAt: now
        )
    }

    public static func keychainReport(
        itemName: String,
        accessControlDescription: String,
        sealed: Bool,
        now: Date = Date()
    ) -> KeyWrapAuditReport {
        KeyWrapAuditReport(
            implementationName: "macOS Keychain",
            severity: .production,
            sealed: sealed,
            aclDescription: accessControlDescription,
            identifier: itemName,
            reveal: .showInKeychainAccess(itemName: itemName),
            notes: [
                "Wrap blob is held by the macOS Keychain (Security.framework).",
                "Only this Mac, signed-in to your user account, can unwrap the brain key.",
                "Inspect the item directly in Keychain Access for an OS-level second opinion.",
            ],
            generatedAt: now
        )
    }

    public static func inMemoryReport(now: Date = Date()) -> KeyWrapAuditReport {
        KeyWrapAuditReport(
            implementationName: "InMemoryKeyWrap (DEV ONLY — not production-safe)",
            severity: .devOnly,
            sealed: true,
            aclDescription: "NONE — wrap held in plaintext in process memory",
            identifier: "in-process (test wrap)",
            reveal: .none,
            notes: [
                "This wrap provides NO at-rest confidentiality.",
                "A release build cannot compile this type (CSO tripwire in core/src/crypto/key_wrap.rs).",
                "Seeing this label in a shipped Hippocampus.app is a critical bug — please report it.",
            ],
            generatedAt: now
        )
    }
}

/// Convenience — the well-known dev.key path the onboarding flow
/// writes to. Read-only.
public enum DefaultKeyWrapLocation {
    public static func devKeyURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCI")
            .appendingPathComponent("dev.key")
    }
}
