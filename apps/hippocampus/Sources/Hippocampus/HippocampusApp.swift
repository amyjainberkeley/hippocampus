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
    @StateObject private var loginItemVM = LoginItemViewModel(service: SMLoginItemService())
    private let updater = SparkleUpdaterService()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(
                supervisor: appDelegate.supervisor,
                loginItemVM: loginItemVM,
                updater: updater
            )
            .task {
                // Supervisor lifecycle (start / defer-until-onboarded)
                // is owned by `AppDelegate.applicationDidFinishLaunching`
                // — see below. Without that, the launch path only ran
                // when the user OPENED the menu (CEO dogfood 2026-05-26
                // "onboarding doesn't open unless I touch the icon").
                // Here we only do menu-open-time chores: Sparkle updater
                // start + the LoginItem one-time prompt mark.
                updater.startUpdater()
                if loginItemVM.shouldPrompt {
                    loginItemVM.markPrompted()
                }
            }
        } label: {
            MenuBarIcon(supervisor: appDelegate.supervisor)
        }

        // Separate Window scene for the Daily Briefs model download.
        // Previously this was a `.sheet(isPresented:)` attached to the
        // menu view, but SwiftUI dismisses a MenuBarExtra menu on item
        // tap BEFORE the sheet can present — the user saw "nothing
        // happens" when clicking "Daily Briefs: Off — Download Model…"
        // (CEO dogfood 2026-05-26). A real `Window` scene survives the
        // menu close. `openWindow(id: "model-download")` from
        // StatusMenuView triggers it.
        Window("Download AI Model", id: "model-download") {
            ModelDownloadView(
                onDismiss: {
                    closeModelDownloadWindow()
                },
                onComplete: {
                    closeModelDownloadWindow()
                }
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func closeModelDownloadWindow() {
        for window in NSApp.windows where window.identifier?.rawValue == "model-download" {
            window.close()
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var supervisor: ProcessSupervisor

    var body: some View {
        switch supervisor.state {
        case .running, .paused:
            Image(nsImage: Self.templateImage)
        case .crashed:
            Image(systemName: "exclamationmark.circle.fill")
        default:
            Image(nsImage: Self.templateImage)
        }
    }

    /// Loaded once from `Contents/Resources/statusbar-icon.png` (+ @2x/@3x).
    /// `isTemplate = true` is the OS contract that makes NSStatusItem tint
    /// the alpha mask for light/dark menu bars; setting it programmatically
    /// is more reliable than the "*Template" filename convention or
    /// SwiftUI's `.renderingMode(.template)` modifier in MenuBarExtra.
    private static let templateImage: NSImage = {
        let img = NSImage(named: "statusbar-icon") ?? NSImage(size: NSSize(width: 22, height: 22))
        img.isTemplate = true
        return img
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Supervisor is owned by AppDelegate (not the SwiftUI App's
    /// `@StateObject`) so the launch lifecycle hooks below can drive
    /// it at the right moment — `applicationDidFinishLaunching` fires
    /// on app launch, whereas a `.task` attached to a menu only fires
    /// when the menu OPENS. The CEO regression of "onboarding doesn't
    /// open until I click the menu-bar icon" (2026-05-26) traces
    /// straight to that older shape — the previous code parked the
    /// launch logic in `StatusMenuView.task`.
    let supervisor: ProcessSupervisor

    private let firstLaunchLogger = Logger(
        subsystem: "ai.hippocampus", category: "first-launch"
    )
    private let sentinelLogger = Logger(
        subsystem: "ai.hippocampus", category: "sentinel-watch"
    )
    private var sentinelWatcher: DispatchSourceFileSystemObject?
    private var sentinelWatcherFd: Int32 = -1
    private var sentinelPollTask: Task<Void, Never>?

    override init() {
        // `ProcessSupervisor.init` is `@MainActor`; this class is too
        // (declared above) so the call site is in actor context.
        // `NSApplicationDelegateAdaptor` constructs the delegate on
        // the main thread during the SwiftUI App init.
        self.supervisor = ProcessSupervisor(
            locator: BundleBinaryLocator(),
            keyStore: FileKeyStore()
        )
        super.init()
    }

    /// Called by AppKit immediately after the app finishes launching —
    /// strictly BEFORE the user can interact with anything, including
    /// opening the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.installBrowserHostManifests()
            self.startSupervisorOrDeferUntilOnboarded()
        }
    }

    /// Idempotent: writes the Chromium native-messaging host JSON into
    /// each installed Chromium-family browser's `NativeMessagingHosts/`
    /// dir, pointing at the running `.app`'s bundled binary. Re-runs
    /// on every launch so the manifest tracks the current install
    /// location (Applications, ~/Applications, Desktop, etc.).
    @MainActor
    private func installBrowserHostManifests() {
        let installer = BrowserHostInstaller()
        let outcomes = installer.install()
        let summary = outcomes
            .map { "\($0.browser)=\($0.action.rawValue)" }
            .joined(separator: " ")
        firstLaunchLogger.info("browser-host install: \(summary, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelSentinelWatcher()
        supervisor.stop()
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
                supervisor.openRecallUI(initialTab: initialTab)
            }
        }
    }

    /// First-launch contract — TCC ordering:
    ///
    /// On a fresh install the user double-clicks the .app BEFORE they've
    /// granted Screen Recording or Accessibility. Starting the helper
    /// at that moment makes the system pop the macOS permission sheets
    /// *over* whatever else we surface, which historically meant the
    /// user saw permission prompts before any explanatory UI.
    ///
    /// Behavior:
    ///   - If the onboarding sentinel is absent, we DO NOT call
    ///     `supervisor.start()`. We only spawn the standalone
    ///     Onboarding executable, which owns the permission-request
    ///     UX inside the Permissions slide.
    ///   - We watch the sentinel parent directory with a
    ///     `DispatchSourceFileSystemObject`. The instant the
    ///     Onboarding window's "Get Started" button writes the
    ///     sentinel, the watch fires and the supervisor starts —
    ///     no relaunch required.
    ///
    /// Once the sentinel exists, this method is a plain
    /// `supervisor.start()`.
    @MainActor
    private func startSupervisorOrDeferUntilOnboarded() {
        if OnboardingSentinel.isComplete {
            firstLaunchLogger.info("first-launch: sentinel present → start supervisor immediately")
            supervisor.start()
            return
        }

        guard supervisor.hasOnboarding else {
            firstLaunchLogger.warning("first-launch: no Onboarding binary bundled → start supervisor as fallback")
            supervisor.start()
            return
        }

        firstLaunchLogger.info("first-launch: sentinel absent → spawn onboarding, defer supervisor.start() until it completes")

        // The Onboarding executable is a separate Process (see
        // `ProcessSupervisor.openOnboarding`) so it does not block
        // the menu bar from painting; both happen in parallel.
        _ = supervisor.openOnboarding()

        armOnboardingSentinelWatcher()
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
    /// A low-frequency 2 s poll runs alongside as a belt-and-suspenders
    /// fallback in case the dispatch source misses the event (it has
    /// in the past on network homedirs / FileProvider mounts).
    @MainActor
    func armOnboardingSentinelWatcher() {
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
                        self.supervisor.start()
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
                    self?.supervisor.start()
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
