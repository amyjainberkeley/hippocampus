// SPDX-License-Identifier: TBD-private
import Foundation
import Combine

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

    public enum AccessControlVerification: String, Sendable, Equatable {
        case unverified
        case notApplicable
    }

    public let implementationName: String
    public let severity: Severity
    public let keyReadable: Bool
    public let accessControlVerification: AccessControlVerification
    public let accessControlDescription: String
    public let identifier: String
    public let reveal: RevealAffordance
    public let notes: [String]
    public let generatedAt: Date

    public init(
        implementationName: String,
        severity: Severity,
        keyReadable: Bool,
        accessControlVerification: AccessControlVerification,
        accessControlDescription: String,
        identifier: String,
        reveal: RevealAffordance,
        notes: [String],
        generatedAt: Date = Date()
    ) {
        self.implementationName = implementationName
        self.severity = severity
        self.keyReadable = keyReadable
        self.accessControlVerification = accessControlVerification
        self.accessControlDescription = accessControlDescription
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
    ) async -> KeyWrapAuditReport {
        let reference = store.reference
        let itemName = "service=\(reference.service) account=\(reference.account)"
        let keyReadable: Bool
        let stateNote: String
        do {
            _ = try await KeyStoreAccess.readValidatedKey(from: store)
            keyReadable = true
            stateNote = "The exact Keychain item was readable through Security.framework."
        } catch {
            keyReadable = false
            stateNote = "The Keychain item is unavailable: \(error.localizedDescription)"
        }

        return KeyWrapAuditReport(
            implementationName: "macOS file-based Keychain",
            severity: .production,
            keyReadable: keyReadable,
            accessControlVerification: .unverified,
            accessControlDescription: "Unverified - this audit does not inspect the item's access object",
            identifier: itemName,
            reveal: .showInKeychainAccess(itemName: itemName),
            notes: [
                stateNote,
                "The query pins the file-Keychain domain and does not use an access group.",
                "Access-object inspection and signed cross-version continuity remain release-owner gates.",
                "No key bytes are included in this report.",
            ],
            generatedAt: now
        )
    }

    public static func inMemoryReport(now: Date = Date()) -> KeyWrapAuditReport {
        KeyWrapAuditReport(
            implementationName: "InMemoryKeyWrap (DEV ONLY - not production-safe)",
            severity: .devOnly,
            keyReadable: true,
            accessControlVerification: .notApplicable,
            accessControlDescription: "Not applicable - wrap held in plaintext in process memory",
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
    func auditReport(now: Date = Date()) async -> KeyWrapAuditReport {
        await KeyWrapAuditor.inspectKeychain(self, now: now)
    }
}

@MainActor
public final class KeyWrapAuditViewModel: ObservableObject {
    public enum State: Sendable, Equatable {
        case loading
        case loaded(KeyWrapAuditReport)
        case failed(String)
    }

    @Published public private(set) var state: State = .loading

    private let audit: @Sendable () async throws -> KeyWrapAuditReport

    public init(store: KeychainKeyStore = .defaultDatabaseKey) {
        self.audit = {
            await KeyWrapAuditor.inspectKeychain(store)
        }
    }

    init(audit: @escaping @Sendable () async throws -> KeyWrapAuditReport) {
        self.audit = audit
    }

    public func refresh() async {
        state = .loading
        do {
            state = .loaded(try await audit())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
