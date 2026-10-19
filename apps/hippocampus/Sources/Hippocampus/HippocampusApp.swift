// SPDX-License-Identifier: Apache-2.0
import Combine
import SwiftUI
import HippocampusKit
import UserNotifications
import os
#if canImport(AppKit)
import AppKit
#endif

struct HippocampusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// The menu-bar item is AppKit's (`StatusItemController`, made by the
    /// delegate at launch). This scene carries only the app's commands, so
    /// ⌘, and ⌘Q work wherever Hippocampus is active, with no key monitor
    /// (RULINGS S7, critique-shell-engineering 12).
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences…") { appDelegate.showPreferences() }
                        .keyboardShortcut(",", modifiers: [.command])
                }
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Hippocampus") { appDelegate.requestQuit() }
                        .keyboardShortcut("q", modifiers: [.command])
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Supervisor is owned by AppDelegate (not the SwiftUI App's
    /// `@StateObject`) so the launch lifecycle hooks below can drive
    /// it at the right moment — `applicationDidFinishLaunching` fires
    /// on app launch, whereas a `.task` attached to a menu only fires
    /// when the menu OPENS. The owner regression of "onboarding doesn't
    /// open until I click the menu-bar icon" (2026-05-26) traces
    /// straight to that older shape — the previous code parked the
    /// launch logic in `StatusMenuView.task`.
    let supervisor: ProcessSupervisor
    let modelProvisioner = BriefModelProvisioner()
    let loginItemVM = LoginItemViewModel(service: SMLoginItemService())
    let preferencesStore = PreferencesStore()
    private var askKeyObservation: AnyCancellable?
    let updater = SparkleUpdaterService()
    private var statusItem: StatusItemController?
    private var preferencesControllerConfigured = false
    private let initialPreferencesRequest = PreferencesOpenRequest(arguments: Array(CommandLine.arguments.dropFirst()))
    /// Why this launch happened; only `.user` opens the window (spec-shell S7).
    private var launchReason = LaunchReason.user
    /// A link was handed to the app before it read why it launched: the link
    /// launched it. Such a link arrives before `applicationDidFinishLaunching`.
    private var linkOpenedAtLaunch = false
    private var launchReasonRead = false
    /// This copy is quitting so the one in Applications can open: nothing
    /// else opens from here.
    private var leavingForApplications = false

    private let firstLaunchLogger = Logger(
        subsystem: "ai.hippocampus", category: "first-launch"
    )
    private let sentinelLogger = Logger(
        subsystem: "ai.hippocampus", category: "sentinel-watch"
    )
    private var sentinelWatcher: DispatchSourceFileSystemObject?
    private var sentinelWatcherFd: Int32 = -1
    private var sentinelPollTask: Task<Void, Never>?
    /// Opens the window once setup closes (onboarding-app contract section 6).
    private var setupClosedTask: Task<Void, Never>?

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
    private var terminateSignalSource: DispatchSourceSignal?
    private var didCleanUpLifecycle = false
    private lazy var terminationCoordinator = ApplicationTerminationCoordinator(
        supervisor: supervisor,
        restartLauncher: DelayedApplicationRestartLauncher(
            bundlePath: Bundle.main.bundlePath
        ),
        stopExtras: { [weak self] in await self?.stopExtrasForQuit() },
        afterStop: { [weak self] in await self?.sweepAfterQuit() },
        cleanup: { [weak self] in self?.cleanUpLifecycle() },
        onFailure: { [weak self] error in self?.presentShutdownFailure(error) }
    )
    private let quitLogger = Logger(subsystem: "ai.hippocampus", category: "quit")

    override init() {
        // `ProcessSupervisor.init` is `@MainActor`; this class is too
        // (declared above) so the call site is in actor context.
        // `NSApplicationDelegateAdaptor` constructs the delegate on
        // the main thread during the SwiftUI App init.
        // Stop Sharing and Pause are kept across launches (spec-shell S5).
        self.supervisor = ProcessSupervisor(
            locator: BundleBinaryLocator(),
            keyStore: KeychainKeyStore.defaultDatabaseKey,
            captureStopNote: UserDefaultsCaptureStopNote(),
            pauses: .shared,
            orphanSweeper: CaptureOrphanSweep(bundleURL: Bundle.main.bundleURL)
        )
        super.init()
    }

    /// Share launch-owned dependencies with every preferences entry point.
    /// A cold-launch URL can arrive before applicationDidFinishLaunching.
    private func configurePreferencesController() {
        guard !preferencesControllerConfigured else { return }
        let supervisor = self.supervisor
        PreferencesWindowController.shared.configure(
            store: preferencesStore,
            loginItemVM: loginItemVM,
            updater: updater,
            captureApplier: supervisor,
            supervisor: supervisor,
            actions: PreferencesActions(
                statusAction: { [weak self] action in self?.performStatusAction(action) },
                openWindow: { tab in supervisor.openRecallUI(initialTab: tab) },
                neverRead: { _ = supervisor.openOnboarding(initialStep: "never-read") },
                chooseApps: { _ = supervisor.openOnboarding(initialStep: "app-access") },
                connectAITools: { done in
                    ConnectAITools.shared.run(supervisor: supervisor) { _ in done() }
                },
                restart: { [weak self] in self?.requestRestart() },
                showSetup: { _ = supervisor.openOnboarding() }
            )
        )
        preferencesControllerConfigured = true
    }

    /// A click on a permission notification can be what launches the app,
    /// and macOS hands that click over only to a delegate set before the app
    /// finishes launching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called by AppKit immediately after the app finishes launching —
    /// strictly BEFORE the user can interact with anything, including
    /// opening the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mask SIGPIPE before any pipe, socket, or child-process work.
        //
        // Owner-reported (cycle 8.23, 2026-05-29): even after PR #254 shipped
        // the `applicationShouldTerminateAfterLastWindowClosed = false`
        // override, the main `Hippocampus` GUI process STILL exited cleanly
        // within minutes of launch on a fresh install of `9fbfe352…`. The
        // helper + agent stayed alive (re-parented to launchd via the
        // supervisor's child re-spawn path), but the menu-bar status item
        // — owned by SwiftUI's `MenuBarExtra` scene inside the main
        // process — disappeared again. Owner accumulated 5 helper+agent
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
        // #252 + PR #254's no-security-review-required pattern. Standard
        // library convention: Rust's `std` masks `SIGPIPE` by default
        // for the same reason.
        signal(SIGPIPE, SIG_IGN)

        // Why Hippocampus was opened, read while the launch's Apple event is
        // still the current one (spec-shell S7). The raw event is logged so a
        // login can be told from a launch with no event at all.
        let launch = LaunchReason.read(preferencesRequested: initialPreferencesRequest != nil, linkOpened: linkOpenedAtLaunch)
        launchReason = launch.reason
        launchReasonRead = true
        firstLaunchLogger.info(
            "launch: reason=\(launch.reason.rawValue, privacy: .public) event=\(launch.event?.logDescription ?? "none", privacy: .public)"
        )

        // A Quit from outside the menu (a script, the installer, Homebrew,
        // logout) arrives as kAEQuitApplication. Under SwiftUI it is not
        // visible as `currentAppleEvent` inside `applicationShouldTerminate`,
        // so it read as lifecycle noise and was silently cancelled. Route it
        // into the deliberate quit instead.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
        // The capture helper and Recall share this bundle identifier, so a
        // Quit addressed by bundle ID can land on them instead. SIGTERM to
        // this process (the installer, `brew uninstall`) is a deliberate
        // quit too, through the same bounded path.
        signal(SIGTERM, SIG_IGN)
        let terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal.setEventHandler { [weak self] in
            // Not from inside this GCD block: a pending terminate spins a
            // nested run loop that cannot drain the main queue the
            // termination coordinator needs, so the quit would deadlock.
            RunLoop.main.perform { self?.requestQuit() }
        }
        terminateSignal.resume()
        terminateSignalSource = terminateSignal
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(workspaceBecameAvailable(_:)), name: name, object: nil
            )
        }
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

        // Opened from the disk image or a translocated copy: offer to move to
        // Applications before anything starts, so no hook, memory server,
        // browser host or login item points at a path that won't last
        // (launch plan item 3, D6). This copy quits when the person moves it.
        if MoveToApplicationsPrompt.run() {
            leavingForApplications = true
            requestQuit()
            return
        }

        configurePreferencesController()
        installPreferencesReceiver()
        installSetupReadReceiver()
        if let request = initialPreferencesRequest {
            PreferencesWindowController.shared.show(section: request.section)
        }
        installStatusItem()
        // A start the person asked to see failed: Preferences shows the
        // reason and the fix (spec-shell S5, D9).
        supervisor.onPresentationBlocked = {
            PreferencesWindowController.shared.show(section: .capture)
        }

        Task { @MainActor in
            let supervisor = self.supervisor
            CommandBarController.shared.configure(
                model: CommandBarModel(launch: { assist in supervisor.memorySessionLaunch(assist: assist) }),
                supervisor: supervisor,
                openEvent: { eventId in supervisor.openRecallUI(initialTab: "search", focusEventId: eventId) },
                openWindow: { tab in supervisor.openRecallUI(initialTab: tab) },
                statusAction: { [weak self] action in self?.performStatusAction(action) },
                announceShown: {
                    AskPanelNotice.announceShown(onboardingRunning: supervisor.onboardingIsRunning) { name in
                        DistributedNotificationCenter.default().postNotificationName(
                            name, object: nil, userInfo: nil, deliverImmediately: true
                        )
                    }
                }
            )
            let hotkeyResult = GlobalHotkeyManager.shared.registerDefault {
                CommandBarController.shared.toggle()
            }
            if case .osError(let status) = hotkeyResult {
                self.firstLaunchLogger.error(
                    "global Ask hotkey registration failed: \(status)"
                )
                SoloKeyMonitor.shared.watch.setFallbackRegistered(false)
            } else {
                SoloKeyMonitor.shared.watch.setFallbackRegistered(true)
            }
            self.watchAskKey()
            self.installBrowserHostManifests()
            self.armTCCStderrTail()
            // The person's own launch asks for the window first: it opens as
            // soon as there is memory to read, while the sweep below runs.
            self.requestTheWindowIfThePersonOpenedHippocampus()
            // A helper left by a crash or Force Quit may still be reading the
            // screen; end it before starting (spec-shell S6.4). Off the main
            // thread, and quick when there is nothing to end.
            await self.supervisor.sweepOrphans(.launch)
            self.startSupervisorOrDeferUntilOnboarded()
            // The updater starts at launch, not when the menu first opens
            // (spec-shell S2, D15). Its first check waits until remembering
            // has started; it does nothing unless the person opted in.
            self.updater.startUpdater()
            self.updater.scheduleBackgroundCheck(after: 10.0)
            // Custom builds may include the optional Qwen model. Seed it on a
            // utility task without delaying the default extractive brief path.
            self.modelProvisioner.startIfNeeded()
        }
    }

    /// The menu-bar icon and its short menu (spec-shell S2).
    private func installStatusItem() {
        let supervisor = self.supervisor
        statusItem = StatusItemController(
            supervisor: supervisor,
            modelProvisioner: modelProvisioner,
            askKey: SoloKeyMonitor.shared.watch,
            actions: StatusItemController.Actions(
                perform: { [weak self] action in self?.performStatusAction(action) },
                ask: { CommandBarController.shared.show() },
                openWindow: { supervisor.openRecallUI() },
                aiTools: { [weak self] connected in
                    if connected {
                        self?.showPreferences(section: .sources)
                    } else {
                        ConnectAITools.shared.run(supervisor: supervisor) { tools in
                            if !tools.isEmpty { self?.statusItem?.noteAIToolsConnected() }
                        }
                    }
                },
                preferences: { [weak self] in self?.showPreferences() },
                quit: { [weak self] in self?.requestQuit() }
            )
        )
    }

    /// The status row's button, from the menu, Ask's footer or Preferences.
    /// Quit is the app's; everything else is the supervisor's.
    func performStatusAction(_ action: CaptureStatusAction) {
        if action == .quit {
            requestQuit()
            return
        }
        supervisor.performAskStatusAction(action) { NSWorkspace.shared.open($0) }
    }

    func showPreferences(section: PreferencesSection? = nil) {
        configurePreferencesController()
        PreferencesWindowController.shared.show(section: section)
    }

    private func installPreferencesReceiver() {
        guard let executable = Bundle.main.executableURL else { return }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivePreferencesRequest(_:)),
            name: PreferencesOpenRequest.notificationName,
            object: executable.resolvingSymlinksInPath().path, suspensionBehavior: .deliverImmediately)
    }

    /// Setup's Try it asks for one fresh read of the window the person
    /// brought forward, as opening Ask does (`SetupReadRequest`). Honoured
    /// only after consent and while setup is open; the supervisor asks the
    /// helper only while remembering, and the helper reads under every rule.
    private func installSetupReadReceiver() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receiveSetupReadRequest(_:)),
            name: SetupReadRequest.notificationName, object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func receiveSetupReadRequest(_ notification: Notification) {
        guard SetupReadRequest.honours(
            consentGiven: OnboardingSentinel.isComplete, setupOpen: supervisor.onboardingIsRunning
        ) else { return }
        supervisor.requestFreshRead()
    }

    @objc private func receivePreferencesRequest(_ notification: Notification) {
        guard let executable = Bundle.main.executableURL,
              let request = PreferencesOpenRequest(notification: notification, executableURL: executable)
        else { return }
        configurePreferencesController()
        PreferencesWindowController.shared.show(section: request.section)
        request.acknowledge(from: executable)
    }

    @objc private func workspaceBecameAvailable(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await self?.supervisor.recoverAfterWorkspaceWake()
        }
    }

    /// Arm the helper-stderr TCC tail (cycle 8.47 PR #80 follow-up).
    ///
    /// Arm before the helper starts so its initial permission verdict cannot
    /// be skipped. The tail also handles a log created after observation begins.
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
        // A fresh helper that has every permission never reports one
        // restored: once remembering starts, the notification goes.
        let notifier = tccNotifier
        supervisor.onRememberingStarted = {
            Task { await notifier.withdrawAll() }
        }

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
        alert.messageText = "Hippocampus needs a Mac with Apple silicon"
        alert.informativeText = "This Mac has an Intel processor, so Hippocampus can’t run on it."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    func requestQuit() {
        requestTermination(.quit)
    }

    @objc private func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        requestQuit()
    }

    func requestRestart() {
        requestTermination(.restart)
    }

    private func requestTermination(_ intent: ApplicationTerminationIntent) {
        terminationRequests.request(intent)
        // Nothing in the menu acts while it stops; the icon follows the
        // supervisor and reaches Off by itself (RULINGS S7).
        statusItem?.setQuitting(true)
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
        // Apple scopes the current event to its synchronous handler.
        terminationRequests.requestQuitIfAppleEvent(
            NSAppleEventManager.shared().currentAppleEvent
        )
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

    /// What the supervisor does not own, stopped while it stops: Ask's two
    /// sessions and the windows, each waited for (spec-shell S6.2, S6.3).
    private func stopExtrasForQuit() async {
        let supervisor = self.supervisor
        let ask = Task { @MainActor in await CommandBarController.shared.shutdown() }
        let windows = Task { @MainActor in await supervisor.stopWindowsForQuit(timeout: 1) }
        await ask.value
        await windows.value
    }

    /// Once the supervisor has stopped: end every capture process still
    /// running from this bundle, including one of ours that survived.
    private func sweepAfterQuit() async {
        guard let outcome = await supervisor.sweepOrphans(.quit) else { return }
        if outcome.remaining == 0 {
            quitLogger.info("quit: nothing left running (swept \(outcome.ended))")
        } else {
            quitLogger.error("quit: \(outcome.remaining) capture processes still running")
        }
    }

    private func cleanUpLifecycle() {
        guard !didCleanUpLifecycle else { return }
        didCleanUpLifecycle = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        cancelSentinelWatcher()
        setupClosedTask?.cancel()
        setupClosedTask = nil
        tccStderrTail?.stop()
        tccStderrTail = nil
        GlobalHotkeyManager.shared.unregister()
        SoloKeyMonitor.shared.stop()
        askKeyObservation = nil
        supervisor.closeRecallUI()
        supervisor.closeOnboarding()
    }

    /// Open Ask on a tap of the chosen key, and follow the preference.
    private func watchAskKey() {
        askKeyObservation = preferencesStore.$askKey.removeDuplicates().sink { key in
            SoloKeyMonitor.shared.start(key: key) { CommandBarController.shared.toggle() }
        }
    }

    /// Accessibility may have been allowed while the app was in the
    /// background; the key starts listening as soon as it is.
    func applicationDidBecomeActive(_ notification: Notification) {
        SoloKeyMonitor.shared.recheck()
        // A permission may have been turned back on in System Settings.
        supervisor.retryIfPermissionMayBeBack()
    }

    /// Only a restart can fail: Quit always stops (spec-shell S6.8). The
    /// menu acts again, since Hippocampus stays open.
    private func presentShutdownFailure(_ error: Error) {
        statusItem?.setQuitting(false)
        let alert = NSAlert()
        alert.messageText = "Couldn’t restart"
        alert.informativeText = "Something is still running, so Hippocampus stayed open. Try again."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Defensive override against AppKit's default "terminate after
    /// last window closed" behavior — the load-bearing reason the
    /// menu-bar `NSStatusItem` survives transient window closes.
    ///
    /// Owner-reported (cycle 8.22, 2026-05-29): on a fresh install of
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
    ///   - Preferences, and its Reset Permissions… alerts.
    ///   - `NSAlert.runModal()` panels from Connect AI Tools….
    ///   - Any future SwiftUI window or sheet.
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
    /// Mirror of PR #252's no-security-review-required pattern.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // A link that launches the app comes first: the launch is the link's,
        // and keeps Hippocampus in the menu bar (spec-shell S7).
        if !launchReasonRead { linkOpenedAtLaunch = true }
        guard !leavingForApplications else { return }
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
            case .openPreferences(let section):
                configurePreferencesController()
                PreferencesWindowController.shared.show(section: section)
            case .showOnboarding:
                // Cycle 8.48 — the cycle 8.46 Action Panel "Show
                // Onboarding" command now works end-to-end. Re-opens
                // the Onboarding executable so users can revisit the
                // flow (e.g. to try the Ask key again after
                // configuring Alfred/SetApp, or to review the trust
                // panel). No sentinel change — reopening is safe
                // even after first-run has completed.
                Task { @MainActor in
                    _ = supervisor.openOnboarding()
                }
            case .ask(let question):
                // A link always shows Ask, and asks when it carries a
                // question (RULINGS S12).
                CommandBarController.shared.show(asking: question, from: .link)
            case .restartRemembering:
                // Setup's "Try Again": the menu's Try Again, in place, which
                // presses a Turn On that did not take again. Not before
                // consent, and that press only for the setup that is open.
                supervisor.restartFromSetup(setupFinished: OnboardingSentinel.isComplete, setupOpen: supervisor.onboardingIsRunning)
            case .unknown:
                continue
            }
        }
    }

    /// Only the person's own launch, once setup is done, opens the window:
    /// not a login, a quiet relaunch, a link or Preferences (spec-shell S7,
    /// 07fedaf). Asking before the launch's orphan sweep lets it open as soon
    /// as the key is checked, alongside the sweep, which can wait up to 15 s
    /// on a writer a crash left; opening the window starts no capture.
    @MainActor
    private func requestTheWindowIfThePersonOpenedHippocampus() {
        let opening = AppOpening.atLaunch(
            launchReason, setupFinished: OnboardingSentinel.isComplete, hasSetup: supervisor.hasOnboarding
        )
        if opening == .window { supervisor.openRecallWhenReady(initialLaunch: true) }
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
    /// Once the sentinel exists, start the supervisor, and show the window
    /// as soon as there is memory to read when the person opened the app.
    @MainActor
    private func startSupervisorOrDeferUntilOnboarded() {
        let opening = AppOpening.atLaunch(
            launchReason, setupFinished: OnboardingSentinel.isComplete, hasSetup: supervisor.hasOnboarding
        )
        guard opening != .setup else {
            firstLaunchLogger.info("first-launch: sentinel absent → spawn onboarding, defer supervisor.start() until it completes")
            // The Onboarding executable is a separate Process (see
            // `ProcessSupervisor.openOnboarding`) so it does not block
            // the menu bar from painting; both happen in parallel.
            _ = supervisor.openOnboarding()
            armOnboardingSentinelWatcher()
            return
        }

        if OnboardingSentinel.isComplete {
            firstLaunchLogger.info("first-launch: sentinel present → start supervisor immediately")
        } else {
            firstLaunchLogger.warning("first-launch: no Onboarding binary bundled → start supervisor as fallback")
        }
        // The person's own launch asked for the window before the sweep
        // (`requestTheWindowIfThePersonOpenedHippocampus`).
        supervisor.start()
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

        // Belt + suspenders: every 2 s for 10 minutes, then every 15 s, so
        // finishing onboarding later (after a break, or a restart for a
        // permission) still starts capture. Cancelled once it does.
        sentinelPollTask = Task { @MainActor [weak self] in
            for attempt in 0... {
                try? await Task.sleep(nanoseconds: attempt < 300 ? 2_000_000_000 : 15_000_000_000)
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
        // The login item follows setup's checkbox, read once (RULINGS O8).
        loginItemVM.applySetupChoice(opensAtLogin: OnboardingSentinel.opensAtLogin())
        openWindowWhenSetupCloses()
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

    /// Consent is written on the Promise screen, and Try it follows it: the
    /// window opens once setup closes, so it never covers Try it
    /// (onboarding-app contract section 6).
    @MainActor
    private func openWindowWhenSetupCloses() {
        setupClosedTask?.cancel()
        setupClosedTask = Task { @MainActor [weak self] in
            while self?.supervisor.onboardingIsRunning == true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            self?.supervisor.openRecallWhenReady(initialLaunch: true)
        }
    }

    /// Opening Hippocampus while it runs (Finder, Spotlight, the Dock, `open`)
    /// always shows something: setup while it is unfinished, otherwise the
    /// window, whatever remembering is doing (Oct 18).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if leavingForApplications { return false }
        switch AppOpening.atReopen(setupFinished: OnboardingSentinel.isComplete, hasSetup: supervisor.hasOnboarding) {
        case .nothing: break
        case .setup: supervisor.showOnboarding()
        case .window: supervisor.reopenWindow()
        }
        return false
    }
}

/// The permission notifications ("Click to open System Settings."): a click
/// on one, or on its Open System Settings button, is the status row's Open
/// System Settings… (`TCCRevokedNotificationActionHandler`).
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Shown while Hippocampus is the active app too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let surface = content.userInfo[TCCRevokedNotifierRequestBuilder.userInfoSurfaceKey] as? String
        _ = await MainActor.run {
            TCCRevokedNotificationActionHandler.handle(
                categoryIdentifier: category, actionIdentifier: action, surface: surface,
                supervisor: supervisor, setupFinished: OnboardingSentinel.isComplete
            ) { NSWorkspace.shared.open($0) }
        }
    }
}
