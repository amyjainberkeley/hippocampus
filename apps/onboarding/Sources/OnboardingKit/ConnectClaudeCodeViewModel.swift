// SPDX-License-Identifier: TBD-private
import Foundation

@MainActor
public final class ConnectClaudeCodeViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case running
        case success(message: String)
        case failure(message: String)
    }

    @Published public private(set) var state: State = .idle
    public let registrar: ClaudeCodeRegistrar

    public init(registrar: ClaudeCodeRegistrar) {
        self.registrar = registrar
    }

    /// Kick off `mci-agent register-mcp`. Re-entrant — if a previous
    /// attempt is already in flight (state == .running), this call is
    /// a no-op so the user double-clicking the Connect button doesn't
    /// spawn two helper processes.
    public func runRegister() async {
        if state == .running { return }
        state = .running
        do {
            let msg = try await registrar.register()
            state = .success(message: msg)
        } catch let err as ClaudeCodeRegistrarError {
            state = .failure(message: err.message)
        } catch {
            state = .failure(message: "\(error)")
        }
    }

    public var manualCommand: String { registrar.manualCommand }

    /// Reset back to idle. Used by the "Try again" affordance.
    public func reset() {
        state = .idle
    }
}
