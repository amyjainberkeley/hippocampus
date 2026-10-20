// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

/// Delete Everything as a crypto-shred (storage-security review S3): the
/// bundled agent deletes the memory, its screenshots and its Keychain key,
/// so no earlier copy of the memory (a Time Machine backup, an APFS
/// snapshot, a stale log frame) can be read again. A new key and an empty
/// memory come with the next start (`ensure-key`).
@MainActor
package protocol MemoryErasing: AnyObject {
    /// Runs the erase while nothing remembers. True when it finished.
    func erase(agentURL: URL, databaseURL: URL, environment: [String: String]) async -> Bool
}

@MainActor
final class AgentMemoryEraser: MemoryErasing {
    private let logger = Logger(subsystem: "ai.hippocampus", category: "supervisor")

    func erase(agentURL: URL, databaseURL: URL, environment: [String: String]) async -> Bool {
        do {
            let result = try await KeyCustodyCommandRunner.run(
                executableURL: agentURL,
                arguments: ["erase-memory", "--db-path", databaseURL.path],
                environment: environment
            )
            if result.terminationStatus != 0 {
                logger.error("supervisor: erase-memory exited \(result.terminationStatus, privacy: .public)")
            }
            return result.terminationStatus == 0
        } catch {
            logger.error("supervisor: erase-memory could not run: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
