// Run with the production SupervisorState and RecallPresentationGate sources
// concatenated on stdin to scripts/swift-package.sh -.
var gate = RecallPresentationGate()
precondition(!gate.request(initialLaunch: true, state: .idle))
precondition(!gate.consumeIfReady(state: .starting))
precondition(!gate.consumeIfReady(state: .crashed(reason: "key unavailable")))
precondition(!gate.request(initialLaunch: false, state: .starting))
precondition(gate.consumeIfReady(state: .running))
precondition(!gate.consumeIfReady(state: .running))
precondition(!gate.request(initialLaunch: true, state: .running))
precondition(gate.request(initialLaunch: false, state: .running))
precondition(gate.request(initialLaunch: false, state: .paused))
precondition(!gate.consumeIfReady(state: .paused))
print("Recall readiness, once-only launch, and reopen checks passed")
