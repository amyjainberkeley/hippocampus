// SPDX-License-Identifier: TBD-private
import Foundation

public enum SupervisorState: Sendable, Equatable {
    case idle
    case starting
    case running
    case paused
    case crashed(reason: String)
    case stopped

    public var isActive: Bool {
        switch self {
        case .running, .paused: return true
        default: return false
        }
    }

    public var statusText: String {
        switch self {
        case .idle: return "○ Off"
        case .starting: return "○ Starting…"
        case .running: return "● Recording"
        case .paused: return "❚❚ Paused"
        case .crashed(let reason): return "⚠ Error: \(reason)"
        case .stopped: return "○ Off"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .running: return "brain.filled.head.profile"
        case .paused: return "brain.head.profile"
        case .crashed: return "exclamationmark.circle.fill"
        default: return "brain.head.profile"
        }
    }

    public var iconColor: String {
        switch self {
        case .running: return "green"
        case .paused: return "yellow"
        case .crashed: return "red"
        default: return "secondary"
        }
    }
}
