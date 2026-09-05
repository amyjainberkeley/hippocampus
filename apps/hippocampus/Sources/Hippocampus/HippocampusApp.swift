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
    @StateObject private var preferencesStore = PreferencesStore()
    private let updater = SparkleUpdaterService()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(
                supervisor: appDelegate.supervisor,
                modelProvisioner: appDelegate.modelProvisioner,
                loginItemVM: loginItemVM,
                updater: updater,
                preferencesStore: preferencesStore,
                onRequestQuit: { appDelegate.requestQuit() },
                onRequestRestart: { appDelegate.requestRestart() }
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
                // One-shot delayed background poll of the Sparkle appcast.
                // The 10 s delay lets `ProcessSupervisor.start()` finish
                // spinning up MCICaptureHelper + mci-agent before the
                // updater does any network I/O + XML parse work. Gated on
                // the user's opt-in inside `checkForUpdatesInBackground()`
                // — no network call happens if auto-check is OFF.
                updater.scheduleBackgroundCheck(after: 10.0)
                if loginItemVM.shouldPrompt {
                    loginItemVM.markPrompted()
                }
                configurePreferencesController()
            }
        } label: {
            MenuBarIcon(supervisor: appDelegate.supervisor)
        }

    }

    /// Wire the process-wide `PreferencesWindowController.shared` with
    /// the dependencies it needs. Idempotent; safe on every menu open.
    /// The controller only builds the NSPanel on first `show()` — this
    /// merely stashes the store / VM / updater references + the
    /// callbacks the About/Privacy/Advanced sections need to defer
    /// back to the supervisor + recall-UI.
    @MainActor
    private func configurePreferencesController() {
        #if canImport(AppKit)
        let supervisor = appDelegate.supervisor
        PreferencesWindowController.shared.configure(
            store: preferencesStore,
            loginItemVM: loginItemVM,
            updater: updater,
            captureApplier: supervisor,
            supervisor: supervisor,
            dbPath: supervisor.dbPath.path,
            onOpenRecallTab: { tab in
                Task { @MainActor in
                    supervisor.openRecallUI(initialTab: tab)
                }
            },
            onOpenDenylistEditor: {
                Task { @MainActor in
                    _ = supervisor.openOnboarding(initialStep: "trust")
                }
            },
            onOpenAllowlistEditor: {
                Task { @MainActor in
                    _ = supervisor.openOnboarding(initialStep: "allowlist")
                }
            },
            onExportDebugBundle: {
                // Open the logs folder as a debug-bundle proxy — a
                // future PR will produce a proper .zip artefact.
                let logDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/MCI")
                NSWorkspace.shared.open(logDir)
            }
        )
        #endif
    }
}

/// Menu-bar icon rendered as a status light.
///
/// Shares the receipt-backed status used in the menu and Preferences.
struct MenuBarIcon: View {
    @ObservedObject var supervisor: ProcessSupervisor

    var body: some View {
        MenuBarStatusLabel(
            status: supervisor.menuBarStatus
        )
    }
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
    let modelProvisioner = BriefModelProvisioner()

    private let firstLaunchLogger = Logger(
        subsystem: "ai.hippocampus", category: "first-launch"
    )
    private let sentinelLogger = Logger(
        subsystem: "ai.hippocampus", category: "sentinel-watch"
    )
    private var sentinelWatcher: DispatchSourceFileSystemObject?
    private var sentinelWatcherFd: Int32 = -1
    private var sentinelPollTask: Task<Void, Never>?

    /// TCC-revoke pipeline (cycle 8.47 PR #80 follow-up):
    ///   helper stderr → helper.stderr.log → tccStderrTail → sink →
    ///   TCCRevokedNotifier (system notification) + supervisor.tccRevokedSurface
    ///   (menu-bar red pill).
    ///
    /// Owned by AppDelegate so its lifetime matches the app process
    /// (not tied to supervisor.start/stop — the helper crash+respawn
    /// cycle keeps writing to the same log file, and we want to keep
    /// tailing across those transitions).
    private let tccNotifier = TCCRevokedNotifier()
    private var tccStderrTail: TCCHelperStderrTail?
    private let terminationRequests = ApplicationTerminationRequestGate()
    private var terminationTask: Task<Void, Never>?
    private var didCleanUpLifecycle = false
    private lazy var terminationCoordinator = ApplicationTerminationCoordinator(
        supervisor: supervisor,
        restartLauncher: DelayedApplicationRestartLauncher(
            bundlePath: Bundle.main.bundlePath
        ),
        cleanup: { [weak self] in self?.cleanUpLifecycle() },
        onFailure: { [weak self] error in self?.presentShutdownFailure(error) }
    )

    override init() {
        // `ProcessSupervisor.init` is `@MainActor`; this class is too
        // (declared above) so the call site is in actor context.
        // `NSApplicationDelegateAdaptor` constructs the delegate on
        // the main thread during the SwiftUI App init.
        self.supervisor = ProcessSupervisor(
            locator: BundleBinaryLocator(),
            keyStore: KeychainKeyStore.defaultDatabaseKey
        )
        super.init()
    }

    /// Called by AppKit immediately after the app finishes launching —
    /// strictly BEFORE the user can interact with anything, including
    /// opening the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // Hard fail-fast for Intel / Rosetta hosts. Hippocampus's local-AI
        // path (Core ML brief-author + CPU-pinned embeddings) is
        // Apple Silicon-only; on Intel it silently degrades or crashes.
        // Cycle 8.44 product-readiness audit polish gap. See
        // `MciBootGuards.hostIsAppleSilicon()` for the host-CPU check
        // (which correctly ignores Rosetta translation of the running
        // process). No env override — Intel is unsupported, period.
        guard MciBootGuards.hostIsAppleSilicon() else {
            Self.presentUnsupportedArchitectureAlert()
            requestQuit()
            return
        }

        // Mask SIGPIPE before any pipe, socket, or child-process work.
        //
        // CEO-reported (cycle 8.23, 2026-05-29): even after PR #254 shipped
        // the `applicationShouldTerminateAfterLastWindowClosed = false`
        // override, the main `Hippocampus` GUI process STILL exited cleanly
        // within minutes of launch on a fresh install of `9fbfe352…`. The
        // helper + agent stayed alive (re-parented to launchd via the
        // supervisor's child re-spawn path), but the menu-bar status item
        // — owned by SwiftUI's `MenuBarExtra` scene inside the main
        // process — disappeared again. CEO accumulated 5 helper+agent
        // orphan pairs from 5 successive main-GUI deaths. No
        // `DiagnosticReports/*.ips` was generated, confirming the exit
        // was NOT a crash and NOT a signal that the kernel reports as
        // a crash (SIGSEGV/SIGABRT/SIGBUS would all produce `.ips`).
        //
        // Root cause: `SafariInboxReader.writeToSocket` (the bridge from
        // the Safari App Group inbox to `mci-agent`'s
        // `page_content.sock` Unix-domain socket) uses raw
        // `Darwin.write(fd, ...)` on a `SOCK_STREAM` socket with NO
        // `SO_NOSIGPIPE` socket option, NO `MSG_NOSIGNAL` send flag,
        // AND no process-wide `signal(SIGPIPE, SIG_IGN)` mask anywhere
        // in the binary. The `ProcessSupervisor` retry loop unbinds
        // and rebinds `page_content.sock` every time the helper or
        // agent exits (helper-exit cascades to `stop()` which kills the
        // agent → its listener socket is `close()`d → `unlink()`-on-next-
        // `bind()` of a new agent). During that brief window any
        // SafariInboxReader drain that has already `connect()`ed and is
        // mid-`write()` receives `EPIPE` AND `SIGPIPE`. The default
        // disposition of `SIGPIPE` is process termination with a clean
        // exit (no `.ips` report) — exactly the observed signature.
        //
        // PR #254 (F1) closed the window-close termination path but
        // left this signal path open. This `signal(SIGPIPE, SIG_IGN)`
        // is the process-wide defense; `SafariInboxReader` also sets
        // `SO_NOSIGPIPE` on its socket fd as the surgical defense at
        // the offending call site (belt + suspenders).
        //
        // §5 audit: `SIG_IGN` on `SIGPIPE` is the standard POSIX-server
        // hardening; it does NOT touch capture / OCR cascade /
        // redaction / sensitive-app denylist / wire framing / known-
        // safe-apps / entitlements / notarization / Gatekeeper /
        // mci.sqlite / blob store. Mirror of PR
        // #252 + PR #254's no-CSO-sign-off-required pattern. Standard
        // library convention: Rust's `std` masks `SIGPIPE` by default
        // for the same reason.
        signal(SIGPIPE, SIG_IGN)

        Task { @MainActor in
            let hotkeyResult = GlobalHotkeyManager.shared.registerDefault { [weak self] in
                self?.supervisor.openRecallUI(openPopup: true)
            }
            if case .osError(let status) = hotkeyResult {
                self.firstLaunchLogger.error(
                    "global Recall hotkey registration failed: \(status)"
                )
            }
            self.installBrowserHostManifests()
            self.startSupervisorOrDeferUntilOnboarded()
            self.armTCCStderrTail()
            // Custom builds may include the optional Qwen model. Seed it on a
            // utility task without delaying the default extractive brief path.
            self.modelProvisioner.startIfNeeded()
        }
    }

    /// Arm the helper-stderr TCC tail (cycle 8.47 PR #80 follow-up).
    ///
    /// The tail is armed AFTER `startSupervisorOrDeferUntilOnboarded`
    /// so the helper's stderr log file has (usually) been created;
    /// however it also works if the file doesn't exist yet — the
    /// dispatch source watches the parent directory and picks up the
    /// file's first appearance.
    ///
    /// Also registers the notification category so the "Open Settings"
    /// action button on the actionable TCC-revoke notification renders
    /// when the notifier's `add(_:)` fires.
    @MainActor
    private func armTCCStderrTail() {
        let sink = TCCNotifierAndSupervisorSink(
            notifier: tccNotifier,
            supervisor: supervisor
        )
        let tail = TCCHelperStderrTail(sink: sink)
        tail.start()
        tccStderrTail = tail

        // Fire-and-forget category registration; safe to call on every
        // launch (setNotificationCategories replaces).
        Task { @MainActor in
            await tccNotifier.registerCategory()
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

    /// Shown at boot when the host is not Apple Silicon. Modal so the
    /// user sees it before `NSApp.terminate` tears the process down.
    /// Single "Quit" button — no bypass path.
    static func presentUnsupportedArchitectureAlert() {
        let alert = NSAlert()
        alert.messageText = "Hippocampus requires Apple Silicon"
        alert.informativeText = """
            This Mac appears to use an Intel processor. Hippocampus's \
            bundled local models and native components currently support \
            Apple Silicon only. Intel Macs are not supported.

            Learn more at https://hippocampus-swart.vercel.app
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    func requestQuit() {
        requestTermination(.quit)
    }

    func requestRestart() {
        requestTermination(.restart)
    }

    private func requestTermination(_ intent: ApplicationTerminationIntent) {
        terminationRequests.request(intent)
        NSApp.terminate(nil)
    }

    @objc
    private func workspaceWillPowerOff(_ notification: Notification) {
        terminationRequests.request(.quit)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if terminationCoordinator.hasVerifiedShutdown { return .terminateNow }
        if terminationTask != nil { return .terminateLater }
        guard let intent = terminationRequests.takeRequestedIntent() else {
            return .terminateCancel
        }

        terminationTask = Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let didTerminate = await self.terminationCoordinator.terminate(
                intent: intent,
                reply: { sender.reply(toApplicationShouldTerminate: $0) }
            )
            if !didTerminate {
                self.terminationTask = nil
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanUpLifecycle()
    }

    private func cleanUpLifecycle() {
        guard !didCleanUpLifecycle else { return }
        didCleanUpLifecycle = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cancelSentinelWatcher()
        tccStderrTail?.stop()
        tccStderrTail = nil
        GlobalHotkeyManager.shared.unregister()
        supervisor.closeRecallUI()
    }

    private func presentShutdownFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hippocampus could not quit safely"
        alert.informativeText = "A capture process is still running. Hippocampus will stay open so you can try again.\n\n\(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Defensive override against AppKit's default "terminate after
    /// last window closed" behavior — the load-bearing reason the
    /// menu-bar `NSStatusItem` survives transient window closes.
    ///
    /// CEO-reported (cycle 8.22, 2026-05-29): on a fresh install of
    /// the cycle 8.22 DMG (`f634b5dc…`), after onboarding completed
    /// and recording started (helper-health.jsonl confirmed 128
    /// frames over 31 s, brain captured 102 events), the main
    /// `Hippocampus` GUI process exited cleanly with no
    /// `DiagnosticReports/*.ips`. `MCICaptureHelper` + `mci-agent`
    /// stayed alive (re-parented to launchd via the supervisor's
    /// child re-spawn path), but the menu-bar icon — owned by the
    /// `NSStatusItem` that SwiftUI's `MenuBarExtra` scene creates
    /// inside the main process — disappeared with the process. The
    /// app was effectively invisible until `open
    /// /Applications/Hippocampus.app` was run manually, which brought
    /// the GUI back without re-installing or re-onboarding.
    ///
    /// Root cause: `NSApplication.applicationShouldTerminateAfterLastWindowClosed`
    /// returns `true` by default. `LSUIElement=true` in Info.plist
    /// makes the app dockless on launch but does NOT change this
    /// AppKit predicate; once a window has been created and then
    /// closed, AppKit checks "any windows left?" and quits if not.
    /// The Hippocampus main process has multiple window-creating
    /// surfaces:
    ///
    ///   - `NSAlert.runModal()` panels in `StatusMenuView`: About
    ///     (`openAboutWindow`), Reset TCC confirmation, error
    ///     alerts via `showAlert`, `KeyWrapAuditView` sheet.
    ///   - Any future SwiftUI window or sheet attached to the menu.
    ///
    /// Returning `false` here makes the app's lifecycle explicit:
    /// the app only quits through AppKit's terminate-later lifecycle,
    /// which awaits verified helper + agent shutdown before replying.
    /// The menu-bar status
    /// item is the entire product surface on the user's machine —
    /// losing the main process means losing the product, even though
    /// the helper + agent keep recording.
    ///
    /// §5 audit: pure UX-flow override. Does not touch capture / OCR
    /// cascade / redaction / sensitive-app denylist / wire / known-
    /// safe-apps / entitlements / notarization / Gatekeeper rules.
    /// Mirror of PR #252's no-CSO-sign-off-required pattern.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = HippocampusURLRoute.parse(url) else { continue }
            switch route {
            case .openRecall(let tab, let focusEventId, let openPopup):
                // Per Brief Viewer spec: `hippocampus://recall?tab=brief`
                // deep-links the Brief tab. Unknown tab values fall
                // through to the recall-ui's default tab.
                Task { @MainActor in
                    supervisor.openRecallUI(
                        initialTab: tab,
                        focusEventId: focusEventId,
                        openPopup: openPopup
                    )
                }
            case .showOnboarding:
                // Cycle 8.48 — the cycle 8.46 Action Panel "Show
                // Onboarding" command now works end-to-end. Re-opens
                // the Onboarding executable so users can revisit the
                // flow (e.g. to re-run the ⇧⌘Space live-try after
                // configuring Alfred/SetApp, or to review the trust
                // panel). No sentinel change — reopening is safe
                // even after first-run has completed.
                Task { @MainActor in
                    _ = supervisor.openOnboarding()
                }
            case .unknown:
                continue
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
    /// Once the sentinel exists, start the supervisor and present Recall
    /// once the verified topology is ready.
    @MainActor
    private func startSupervisorOrDeferUntilOnboarded() {
        if OnboardingSentinel.isComplete {
            firstLaunchLogger.info("first-launch: sentinel present → start supervisor immediately")
            supervisor.openRecallWhenReady(initialLaunch: true)
            supervisor.start()
            return
        }

        guard supervisor.hasOnboarding else {
            firstLaunchLogger.warning("first-launch: no Onboarding binary bundled → start supervisor as fallback")
            supervisor.openRecallWhenReady(initialLaunch: true)
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
                        "sentinel-watch: sentinel appeared → enabling first-run capture"
                    )
                    self.cancelSentinelWatcher()
                    self.startCaptureAfterOnboarding()
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
                        "sentinel-watch: poll caught sentinel → enabling first-run capture"
                    )
                    self?.cancelSentinelWatcher()
                    self?.startCaptureAfterOnboarding()
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

    /// Completing the first-run flow is the user's explicit capture opt-in.
    /// Persist and launch that state as one verified supervisor transition so
    /// the Done screen cannot lead to an inert capture-disabled process tree.
    @MainActor
    private func startCaptureAfterOnboarding() {
        supervisor.openRecallWhenReady(initialLaunch: true)
        if supervisor.captureEnabled {
            supervisor.start()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.supervisor.applyCaptureEnabled(true)
                self.firstLaunchLogger.info(
                    "first-launch: onboarding consent persisted; capture topology ready"
                )
            } catch {
                self.firstLaunchLogger.error(
                    "first-launch: could not enable capture after onboarding: \(error.localizedDescription)"
                )
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !OnboardingSentinel.isComplete && supervisor.hasOnboarding {
            _ = supervisor.openOnboarding()
            return false
        }
        supervisor.openRecallWhenReady()
        if !supervisor.state.isActive && supervisor.state != .starting {
            supervisor.start()
        }
        return false
    }
}
