import Foundation

@main
struct SupervisorTransitionGateBehavior {
    static func main() {
        var gate = SupervisorTransitionGate()
        guard let initial = gate.beginTransition() else { preconditionFailure("initial transition") }
        precondition(gate.beginTransition() == nil, "overlapping transition must be rejected")
        precondition(!gate.acceptsUnexpectedExit(generationID: "initial"))
        precondition(gate.commit(generationID: "initial", transitionID: initial))
        precondition(gate.acceptsUnexpectedExit(generationID: "initial"))

        guard let captureChange = gate.beginTransition() else {
            preconditionFailure("capture transition")
        }
        precondition(!gate.acceptsUnexpectedExit(generationID: "initial"))
        precondition(!gate.acceptsUnexpectedExit(generationID: "requested"))
        precondition(!gate.acceptsUnexpectedExit(generationID: "rollback"))
        precondition(!gate.canBeginRetry(expectedGenerationID: "initial"))

        precondition(gate.commit(generationID: "rollback", transitionID: captureChange))
        precondition(!gate.acceptsUnexpectedExit(generationID: "requested"))
        precondition(gate.acceptsUnexpectedExit(generationID: "rollback"))
        precondition(gate.canBeginRetry(expectedGenerationID: "rollback"))

        let stale = UUID()
        precondition(!gate.commit(generationID: "stale", transitionID: stale))
        precondition(gate.acceptsUnexpectedExit(generationID: "rollback"))

        gate.reset()
        precondition(!gate.acceptsUnexpectedExit(generationID: "rollback"))
        precondition(!gate.canBeginRetry(expectedGenerationID: "rollback"))
    }
}
