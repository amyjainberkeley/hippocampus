// SPDX-License-Identifier: TBD-private
//
// Coordinates first-launch provisioning when a custom build includes the
// optional Qwen brief author. The multi-gigabyte copy must never occupy
// AppKit's main actor or delay launch.

import Combine
import Foundation

@MainActor
public final class BriefModelProvisioner: ObservableObject {
    public enum State: Equatable {
        /// Launch has not yet asked the provisioner to inspect the bundle.
        case notStarted
        /// A bundled model is being linked or copied to Application Support.
        case provisioning
        /// The full model and tokenizer are available to the brief worker.
        case ready
        /// This build does not include the optional prose model.
        case unavailable
        /// Provisioning attempted and did not produce a usable model.
        case failed(String)
    }

    @Published public private(set) var state: State = .notStarted

    private let isInstalled: @Sendable () -> Bool
    private let provision: @Sendable () async -> BriefModelPresence.SeedOutcome
    private var activeTask: Task<Void, Never>?

    public init(
        provision: @escaping @Sendable () async -> BriefModelPresence.SeedOutcome = {
            BriefModelPresence.seedBundledQwen3IfNeeded()
        }
    ) {
        self.isInstalled = { BriefModelPresence.isQwen3Installed() }
        self.provision = provision
    }

    public init(
        isInstalled: @escaping @Sendable () -> Bool,
        provision: @escaping @Sendable () async -> BriefModelPresence.SeedOutcome
    ) {
        self.isInstalled = isInstalled
        self.provision = provision
    }

    /// The disk remains authoritative even after a prior seed completed.
    /// This protects the menu from claiming richer wording is available after
    /// a user or cleanup tool removes Application Support while the app runs.
    public var isReadyOnDisk: Bool {
        state == .ready && isInstalled()
    }

    /// Starts exactly one provisioning task. Calls while the task is active
    /// join that task; callers never create competing multi-gigabyte copies.
    public func startIfNeeded() {
        guard activeTask == nil else { return }
        guard state != .ready else { return }

        state = .provisioning
        let provision = provision
        activeTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                await provision()
            }.value
            guard let self else { return }
            self.finish(outcome)
        }
    }

    /// Restarts provisioning after a previously ready model disappears.
    public func refreshIfMissing() {
        guard state == .ready, !isInstalled() else { return }
        state = .notStarted
        startIfNeeded()
    }

    private func finish(_ outcome: BriefModelPresence.SeedOutcome) {
        activeTask = nil
        switch outcome {
        case .alreadyPresent, .seeded:
            state = .ready
        case .noBundle:
            state = .unavailable
        case .seedError(let message):
            state = .failed(message)
        }
    }
}
