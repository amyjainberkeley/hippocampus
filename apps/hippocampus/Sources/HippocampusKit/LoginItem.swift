// SPDX-License-Identifier: TBD-private
import Foundation
@preconcurrency import ServiceManagement
import os

// SMAppService.LoginItem requires macOS 13+; our deployment target is 14+.

public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unknown
}

public protocol LoginItemService: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

public struct SMLoginItemService: LoginItemService, Sendable {
    private let service: SMAppService
    private let logger = Logger(subsystem: "ai.hippocampus", category: "login-item")

    public init() {
        self.service = SMAppService.mainApp
    }

    public func status() -> LoginItemStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notRegistered
        @unknown default: return .unknown
        }
    }

    public func register() throws {
        try service.register()
        logger.info("login-item: registered")
    }

    public func unregister() throws {
        try service.unregister()
        logger.info("login-item: unregistered")
    }
}
