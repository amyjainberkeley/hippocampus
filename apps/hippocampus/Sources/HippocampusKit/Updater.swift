// SPDX-License-Identifier: TBD-private
import Foundation
import Combine
@preconcurrency import Sparkle
import os

public enum UpdaterState: Sendable, Equatable {
    case idle
    case checking
    case available(version: String)
    case installing
    case error(String)
}

@MainActor
public protocol UpdaterService: AnyObject {
    var statePublisher: AnyPublisher<UpdaterState, Never> { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
public final class SparkleUpdaterService: NSObject, UpdaterService, @unchecked Sendable {
    private let controller: SPUStandardUpdaterController
    private let stateSubject = CurrentValueSubject<UpdaterState, Never>(.idle)
    private let logger = Logger(subsystem: "ai.hippocampus", category: "updater")

    public var statePublisher: AnyPublisher<UpdaterState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    public var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    public var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            logger.info("updater: auto-check = \(newValue)")
        }
    }

    public override init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        // Auto-check OFF by default — user must opt in via menu.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        // No system profiling telemetry.
        controller.updater.sendsSystemProfile = false
        logger.info("updater: initialized. auto-check=OFF, system-profiling=OFF")
    }

    public func startUpdater() {
        do {
            try controller.updater.start()
            logger.info("updater: started")
        } catch {
            logger.error("updater: failed to start: \(error.localizedDescription)")
            stateSubject.send(.error(error.localizedDescription))
        }
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        stateSubject.send(.checking)
        controller.checkForUpdates(nil)
        logger.info("updater: manual check initiated")
    }

    /// Silent background poll of the appcast feed. Unlike `checkForUpdates()`,
    /// this does NOT surface UI unless a new version is actually available —
    /// matches Sparkle's default background behavior. Gated on the same
    /// `automaticallyChecksForUpdates` opt-in the user controls from the menu;
    /// if auto-check is off, this is a no-op.
    ///
    /// Called by `HippocampusApp` with a 10 s delay after launch so the
    /// network + XML parse never competes with `ProcessSupervisor.start()`
    /// (which is spinning up MCICaptureHelper + mci-agent + the recall-ui
    /// bind path in that window).
    public func checkForUpdatesInBackground() {
        guard canCheckForUpdates else { return }
        guard controller.updater.automaticallyChecksForUpdates else {
            logger.info("updater: background check skipped (auto-check opt-in is OFF)")
            return
        }
        stateSubject.send(.checking)
        controller.updater.checkForUpdatesInBackground()
        logger.info("updater: background check initiated")
    }

    /// Schedule a one-shot background check `delay` seconds after this call.
    /// Called from the app launch path; the delay is a launch-storm mitigator,
    /// not a rate-limit — Sparkle's own `SUScheduledCheckInterval` handles
    /// steady-state polling once auto-check is opted in.
    public func scheduleBackgroundCheck(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.checkForUpdatesInBackground()
        }
    }
}
