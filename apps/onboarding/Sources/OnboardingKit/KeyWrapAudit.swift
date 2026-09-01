import Foundation

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

public enum KeyWrapAuditor {
    /// Onboarding is intentionally absent from the item ACL, so this reports
    /// the production reference without pretending that onboarding read it.
    public static func keychainReferenceReport(now: Date = Date()) -> KeyWrapAuditReport {
        let itemName = "service=ai.hippocampus.brain account=database-key-v1"
        return KeyWrapAuditReport(
            implementationName: "macOS file-based Keychain",
            severity: .production,
            sealed: false,
            aclDescription: "SecAccess ACL for the four bundled signed executables; non-synchronizable",
            identifier: itemName,
            reveal: .showInKeychainAccess(itemName: itemName),
            notes: [
                "Onboarding is not authorized to read the database key and cannot claim a successful probe.",
                "The trusted mci-agent prepares and validates custody before capture starts.",
                "The Hippocampus Key Wrap Audit can verify availability after onboarding.",
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
            notes: ["This wrap provides NO at-rest confidentiality."],
            generatedAt: now
        )
    }
}
