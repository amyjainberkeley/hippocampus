// SPDX-License-Identifier: TBD-private
import Foundation

/// Content-free metadata about the active database-key custody mechanism.
public struct KeyWrapAuditReport: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case production
        case devOnly
    }

    public enum RevealAffordance: Sendable, Equatable {
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

/// Read-only, content-free inspectors over the active Keychain reference.
public enum KeyWrapAuditor {
    public static func inspectKeychain(
        _ store: KeychainKeyStore = .defaultDatabaseKey,
        now: Date = Date()
    ) -> KeyWrapAuditReport {
        let reference = store.reference
        let itemName = "service=\(reference.service) account=\(reference.account)"
        let sealed: Bool
        let stateNote: String
        do {
            _ = try store.readKey()
            sealed = true
            stateNote = "The exact Keychain item resolved through Security.framework."
        } catch {
            sealed = false
            stateNote = "The Keychain item is unavailable: \(error.localizedDescription)"
        }

        return KeyWrapAuditReport(
            implementationName: "macOS file-based Keychain",
            severity: .production,
            sealed: sealed,
            aclDescription: "SecAccess ACL for the four bundled signed executables; non-synchronizable",
            identifier: itemName,
            reveal: .showInKeychainAccess(itemName: itemName),
            notes: [
                stateNote,
                "The query pins the file-Keychain domain and does not use an access group.",
                "No key bytes are included in this report.",
            ],
            generatedAt: now
        )
    }

    public static func inMemoryReport(now: Date = Date()) -> KeyWrapAuditReport {
        KeyWrapAuditReport(
            implementationName: "InMemoryKeyWrap (DEV ONLY - not production-safe)",
            severity: .devOnly,
            sealed: true,
            aclDescription: "NONE - wrap held in plaintext in process memory",
            identifier: "in-process (test wrap)",
            reveal: .none,
            notes: [
                "This wrap provides NO at-rest confidentiality.",
                "A release build cannot compile this type.",
                "Seeing this label in a shipped app is a critical bug.",
            ],
            generatedAt: now
        )
    }
}

public extension KeychainKeyStore {
    func auditReport(now: Date = Date()) -> KeyWrapAuditReport {
        KeyWrapAuditor.inspectKeychain(self, now: now)
    }
}
