// SPDX-License-Identifier: TBD-private
import Foundation

struct SupervisorTransitionGate {
    private var activeTransitionID: UUID?
    private var committedGenerationID: String?

    mutating func beginTransition() -> UUID? {
        guard activeTransitionID == nil else { return nil }
        let transitionID = UUID()
        activeTransitionID = transitionID
        return transitionID
    }

    @discardableResult
    mutating func commit(generationID: String, transitionID: UUID) -> Bool {
        guard activeTransitionID == transitionID else { return false }
        committedGenerationID = generationID
        activeTransitionID = nil
        return true
    }

    mutating func fail(transitionID: UUID) {
        guard activeTransitionID == transitionID else { return }
        committedGenerationID = nil
        activeTransitionID = nil
    }

    func acceptsUnexpectedExit(generationID: String) -> Bool {
        activeTransitionID == nil && committedGenerationID == generationID
    }

    func canBeginRetry(expectedGenerationID: String) -> Bool {
        acceptsUnexpectedExit(generationID: expectedGenerationID)
    }

    mutating func reset() {
        activeTransitionID = nil
        committedGenerationID = nil
    }
}
