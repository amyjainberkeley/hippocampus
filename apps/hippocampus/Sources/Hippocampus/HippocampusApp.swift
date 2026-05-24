// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit
import os
#if canImport(AppKit)
import AppKit
#endif

@main
struct HippocampusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var supervisor = ProcessSupervisor(
        locator: BundleBinaryLocator(),
        keyStore: FileKeyStore()
    )
    @StateObject private var loginItemVM = LoginItemViewModel(service: SMLoginItemService())
    private let updater = SparkleUpdaterService()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(
                supervisor: supervisor,
                loginItemVM: loginItemVM,
                updater: updater
            )
            .task {
                appDelegate.supervisorRef = supervisor
                updater.startUpdater()
                Self.startSupervisorOrDeferUntilOnboarded(
                    supervisor: supervisor,
                    appDelegate: appDelegate
                )
            }
        } label: {
            MenuBarIcon(supervisor: supervisor)
        }
    }

    /// First-launch contract — TCC ordering:
    ///
    /// On a fresh install the user hits the menu-bar icon (or just
    /// double-clicks the .app) BEFORE they've granted Screen Recording
    /// or Accessibility. Starting the helper at that moment makes the
    /// system pop the macOS permission sheets *over* whatever else we
    /// surface, which historically meant the user saw permission
    /// prompts before any explanatory UI. (CEO-reported, 2026-05-24.)
    ///
    /// New behavior:
    ///   - If the onboarding sentinel is absent, we DO NOT call
    ///     `supervisor.start()`. We only spawn the standalone
    ///     Onboarding executable, which owns the permission-request
    ///     UX inside the Permissions slide.
    ///   - The AppDelegate then watches the sentinel parent directory
    ///     with a `DispatchSourceFileSystemObject`. The instant the
    ///     Onboarding window's "Get Started" button writes the
    ///     sentinel, the watch fires and the supervisor starts —
    ///     no relaunch required, no orphan menu-bar state.
    ///
    /// Once the sentinel exists, this method is a plain
    /// `supervisor.start()`.
    @MainActor
    private static func startSupervisorOrDeferUntilOnboarded(
        supervisor: ProcessSupervisor,
        appDelegate: AppDelegate
    ) {
        let logger = Logger(subsystem: "ai.hippocampus", category: "first-launch")
        if OnboardingSentinel.isComplete {
            logger.info("first-launch: sentinel present → start supervisor immediately")
            supervisor.start()
            return
        }

        guard supervisor.hasOnboarding else {
            // No bundled Onboarding binary (shouldn't happen for
            // shipped DMGs after PR #183, but if it does we must NOT
            // strand the user: fall back to the old start-at-launch
            // behavior so the app at least works.
            logger.warning("first-launch: no Onboarding binary bundled → start supervisor as fallback")
            supervisor.start()
            return
        }

        logger.info("first-launch: sentinel absent → defer supervisor.start() until onboarding completes")

        // 1.0 s defer lets the menu-bar icon paint first so the user
        // gets visual confirmation the app launched before the
        // Onboarding window appears.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = supervisor.openOnboarding()
        }

        // Arm a one-shot file-watcher on the MCI app-support dir. When
        // the Onboarding executable writes the sentinel, this fires
        // and starts the supervisor — no user action, no relaunch.
        appDelegate.armOnboardingSentinelWatcher(supervisor: supervisor)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var supervisor: ProcessSupervisor

    var body: some View {
        switch supervisor.state {
        case .running:
            Image(systemName: "brain.filled.head.profile")
        case .paused:
            Image(systemName: "brain.head.profile")
        case .crashed:
            Image(systemName: "exclamationmark.circle.fill")
        default:
            Image(systemName: "brain.head.profile")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var supervisorRef: ProcessSupervisor?

    private let sentinelLogger = Logger(subsystem: "ai.hippocampus", category: "sentinel-watch")
    private var sentinelWatcher: DispatchSourceFileSystemObject?
    private var sentinelWatcherFd: Int32 = -1
    private var sentinelPollTask: Task<Void, Never>?

    func applicationWillTerminate(_ notification: Notification) {
        cancelSentinelWatcher()
        supervisorRef?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "hippocampus", url.host == "recall" else { continue }
            // Parse `?tab=brief` (or other) per the Brief Viewer spec:
            // `hippocampus://recall?tab=brief` deep-links the Brief tab.
            // Unknown values fall through to the recall-ui's default tab.
            let initialTab: String? = URLComponents(
                url: url, resolvingAgainstBaseURL: false
            )?
            .queryItems?
            .first(where: { $0.name == "tab" })?
            .value
            Task { @MainActor in
                supervisorRef?.openRecallUI(initialTab: initialTab)
            }
        }
    }

    /// Arm a Dispatch-source watch on the MCI app-support directory.
    /// As soon as the Onboarding executable writes
    /// `.onboarding-complete`, the watch's event handler fires and
    /// starts the supervisor.
    ///
    /// The dispatch source watches the *parent directory*, not the
    /// sentinel itself — Apple's file-system events fire on inode
    /// changes (writes / renames), so the parent dir's `.write` event
    /// catches the atomic write of a newly-created child file.
    ///
    /// We also arm a low-frequency 2 s poll as a belt-and-suspenders
    /// fallback in case the dispatch source misses the event (it has
    /// in the past on network homedirs / FileProvider mounts).
    @MainActor
    func armOnboardingSentinelWatcher(supervisor: ProcessSupervisor) {
        cancelSentinelWatcher()

        let dir = OnboardingSentinel.defaultURL.deletingLastPathComponent()
        // Ensure the dir exists so `open()` returns a valid fd.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if OnboardingSentinel.isComplete {
                    self.sentinelLogger.info(
                        "sentinel-watch: sentinel appeared → starting supervisor"
                    )
                    self.cancelSentinelWatcher()
                    Task { @MainActor in
                        supervisor.start()
                    }
                }
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.sentinelWatcherFd, fd >= 0 {
                    close(fd)
                    self?.sentinelWatcherFd = -1
                }
            }
            sentinelWatcher = source
            sentinelWatcherFd = fd
            source.resume()
            sentinelLogger.info("sentinel-watch: armed on \(dir.path, privacy: .public)")
        } else {
            sentinelLogger.warning(
                "sentinel-watch: open(\(dir.path, privacy: .public)) failed (errno=\(errno))"
            )
        }

        // Belt + suspenders. 2 s poll lasting up to 10 min — long
        // enough for any plausible onboarding completion, finite so
        // it doesn't leak forever if the user abandons the flow.
        sentinelPollTask = Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if OnboardingSentinel.isComplete {
                    self?.sentinelLogger.info(
                        "sentinel-watch: poll caught sentinel → starting supervisor"
                    )
                    self?.cancelSentinelWatcher()
                    supervisor.start()
                    return
                }
            }
        }
    }

    @MainActor
    private func cancelSentinelWatcher() {
        sentinelWatcher?.cancel()
        sentinelWatcher = nil
        sentinelPollTask?.cancel()
        sentinelPollTask = nil
    }
}
