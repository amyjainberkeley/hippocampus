// SPDX-License-Identifier: TBD-private
//
// Read-only key-wrap inspection surface (DOGFOOD_V1 #28).
//
// Visible, verifiable evidence that substantiates TrustSlide's
// "256-bit key sealed on this Mac" claim. Content-free: never
// returns key bytes, never reads the SQLCipher store, never
// makes a network call. Only metadata about the wrap discipline
// (impl name, sealed bool, ACL, identifier, severity).
//
// PROTECTED-SET ADJACENT (AGENT_PROTOCOL §5). This file is a
// READER over existing wrap state — it does not change the wrap
// policy, does not rotate or generate keys, does not touch crypto
// internals in `core/src/crypto/`.

import Foundation

/// A content-free snapshot of the key-wrap state in use right now.
///
/// `KeyWrapAuditReport` carries only metadata about *how* the key is
/// sealed — never the key bytes, the SQLCipher header, or anything
/// derived from event content. The recall UI's "Inspect Key Wrap"
/// panel renders this verbatim.
public struct KeyWrapAuditReport: Sendable, Equatable {
    /// Trust posture of the wrap impl backing the report.
    public enum Severity: String, Sendable, Equatable {
        /// Production-grade: macOS Keychain item with an `AccessControl`
        /// ACL, or Secure-Enclave-backed wrap.
        case production
        /// Owner-only file under `Application Support/MCI/`. Production-
        /// safe at rest (POSIX 0600) but not the long-term wrap; ADR-0017
        /// §6 replaces it with Keychain backing.
        case interim
        /// Test-only — `InMemoryKeyWrap` or other no-confidentiality wrap.
        /// MUST NEVER appear in a shipped build. Rendered loudly in red.
        case devOnly
    }

    /// What the user can be deep-linked into to verify the wrap themselves.
    public enum RevealAffordance: Sendable, Equatable {
        /// Open Finder focused on the wrap file.
        case showInFinder(URL)
        /// Open `/Applications/Utilities/Keychain Access.app`. macOS does
        /// not support deep-linking to a specific item, so this is a
        /// best-effort surface — the user finds the item by name.
        case showInKeychainAccess(itemName: String)
        /// No external reveal affordance — wrap lives entirely in
        /// process memory (test-only).
        case none
    }

    /// Short label rendered as the panel headline. E.g.
    /// `"FileKeyStore (interim)"`, `"macOS Keychain"`,
    /// `"InMemoryKeyWrap (DEV ONLY)"`.
    public let implementationName: String

    /// Trust posture; drives the panel's badge colour.
    public let severity: Severity

    /// `true` iff the wrap is presently reachable for unseal on this
    /// device — for the file wrap, "the file exists and is readable";
    /// for a Keychain wrap, "SecItemCopyMatching returned success".
    /// Content-free.
    public let sealed: Bool

    /// Human-readable access-control description. Examples:
    /// `"POSIX 0600 (owner-only read/write)"`,
    /// `"kSecAttrAccessibleWhenUnlocked"`,
    /// `"kSecAttrAccessibleWhenUnlockedThisDeviceOnly + biometry-current-set"`.
    public let aclDescription: String

    /// Where the wrap blob lives — the file path for `FileKeyStore`,
    /// the Keychain service+account string for a Keychain wrap. Name
    /// only; never contents.
    public let identifier: String

    /// Affordance the panel offers to let the user verify the wrap
    /// outside the app (Finder or Keychain Access).
    public let reveal: RevealAffordance

    /// Extra context lines rendered under the metadata block.
    /// Documentation pointers and ADR references; no secrets.
    public let notes: [String]

    /// Wall-clock instant the report was generated. Used by the
    /// "Re-verify wrap" button to show the user the panel actually
    /// re-read state.
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

/// Read-only inspectors over the key-wrap state. Pure functions over
/// the wrap surface; never mutate, never call network, never log
/// secrets.
public enum KeyWrapAuditor {
    /// Inspect a `FileKeyStore`-style wrap (the current Hippocampus
    /// path until ADR-0017 §6 lands Keychain backing).
    ///
    /// Reads only file existence, POSIX mode, and size. Never opens
    /// the file's contents.
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

    /// Inspect a future Keychain-backed wrap. Not used by the current
    /// shipping `FileKeyStore` path; lands when ADR-0017 §6 wires
    /// `SecItem` storage. Kept here so the panel's view code is
    /// already aligned to the production shape.
    ///
    /// Implementations should pass `sealed: true` only if a
    /// `SecItemCopyMatching` lookup of the wrap item returns success.
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

    /// Inspect a test-only `InMemoryKeyWrap` (Rust `core` test wrap).
    /// Used by integration tests that build with the
    /// `insecure-test-keywrap` feature; MUST NEVER fire in a shipped
    /// build. The panel renders this report with a loud red banner.
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

public extension FileKeyStore {
    /// Convenience — generate a current `KeyWrapAuditReport` for this
    /// store. Read-only; never mutates the file.
    func auditReport(now: Date = Date()) -> KeyWrapAuditReport {
        KeyWrapAuditor.inspectFile(at: path, now: now)
    }
}
