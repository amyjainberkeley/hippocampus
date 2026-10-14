// SPDX-License-Identifier: Apache-2.0
import Foundation
import os

@MainActor
public final class LoginItemViewModel: ObservableObject, Sendable {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var hasPromptedOnce: Bool

    private let service: LoginItemService
    private let promptedKey = "ai.hippocampus.loginItem.prompted"
    private let logger = Logger(subsystem: "ai.hippocampus", category: "login-item-vm")

    public init(service: LoginItemService) {
        self.service = service
        self.isEnabled = service.status() == .enabled
        self.hasPromptedOnce = UserDefaults.standard.bool(forKey: promptedKey)
    }

    public func toggle() {
        if isEnabled {
            do {
                try service.unregister()
                isEnabled = false
                logger.info("login-item-vm: disabled")
            } catch {
                logger.error("login-item-vm: unregister failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try service.register()
                isEnabled = true
                logger.info("login-item-vm: enabled")
            } catch {
                logger.error("login-item-vm: register failed: \(error.localizedDescription)")
            }
        }
    }

    public func refreshStatus() {
        isEnabled = service.status() == .enabled
    }

    public func markPrompted() {
        hasPromptedOnce = true
        UserDefaults.standard.set(true, forKey: promptedKey)
    }

    public var shouldPrompt: Bool {
        !hasPromptedOnce && !isEnabled
    }

    /// Apply the "Open Hippocampus at login" checkbox setup wrote with
    /// consent (RULINGS O8): register only when it was ticked. Unticked, or
    /// no choice at all (an older setup), leaves the login item exactly as
    /// it is. No launch ever turns it on by itself.
    public func applySetupChoice(opensAtLogin: Bool?) {
        guard opensAtLogin == true else { return }
        markPrompted()
        guard !isEnabled else { return }
        do {
            try service.register()
            isEnabled = true
            logger.info("login-item-vm: enabled as chosen in setup")
        } catch {
            logger.error("login-item-vm: register failed: \(error.localizedDescription)")
        }
    }
}
