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
    private let quarantineLogger = Logger(
        subsystem: "ai.hippocampus", category: "quarantine"
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
        // FIRST thing on launch, before any pipe / socket / Process /
        // xattr work: mask SIGPIPE.
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
        // QuarantineUnlocker / mci.sqlite / blob store. Mirror of PR
        // #252 + PR #254's no-CSO-sign-off-required pattern. Standard
        // library convention: Rust's `std` masks `SIGPIPE` by default
        // for the same reason.
        signal(SIGPIPE, SIG_IGN)

        // FIRST thing on launch: strip `com.apple.quarantine` from the
        // running .app bundle.
        //
        // CEO-reported (cycles 8.19 and 8.21): after granting a TCC
        // permission during onboarding, the main GUI process vanishes
        // (menu-bar icon disappears) while MCICaptureHelper + mci-agent
        // stay alive (re-parented to launchd). Live triage confirmed
        // `com.apple.quarantine` was still set on the .app, and the
        // verified fix was:
        //
        //     xattr -dr com.apple.quarantine /Applications/Hippocampus.app
        //
        // Notarization + stapling do NOT clear the quarantine attr —
        // it is attached by the downloading browser regardless of
        // signing. While the attr is set, LaunchServices keeps a
        // per-bundle decision record that a single Gatekeeper-adjacent
        // Cancel or a TCC denial can flip to "reject", silently
        // refusing subsequent launches. See QuarantineUnlocker for the
        // full mechanism + §5 protected-set audit.
        //
        // We do this BEFORE `installBrowserHostManifests` and
        // `startSupervisorOrDeferUntilOnboarded` so the strip is
        // committed before any TCC-triggering call sites run.
        let unlocker = QuarantineUnlocker()
        let outcome = unlocker.runIfNeeded()
        quarantineLogger.info(
            "first-launch quarantine outcome: \(String(describing: outcome), privacy: .public)"
        )

        // Seed the bundled Qwen3-1.7B brief-author model from
        // Contents/Resources/Models/qwen3-1.7b-fp16/ into
        // ~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/ so the
        // Rust runtime (`apps/agent/src/brief_worker.rs::default_model_dir`)
        // finds the model at the same path it did before cycle 8.42's
        // bundle-into-DMG fix. Idempotent — no-op if the user already has a
        // copy at the destination (either from a prior seed OR from the
        // pre-bundling HF-download path).
        //
        // Cycle 8.42, EnviousWispr peer-study §5 fix — see
        // docs/research/2026-07-13-enviouswispr-peer-study.md. Prior to this
        // change, first-run onboarding downloaded the model from HuggingFace
        // with no fallback; a HF CDN throttle or 5xx (as EnviousWispr
        // experienced 2026-07-05, killing multiple installs for ~45 min each)
        // hung MCI's first-run at the "Prepare your brain" slide. Bundling
        // the model into the DMG closes that outage class; the download
        // path in `RealModelDownloader` is preserved as a fallback for any
        // future "lite edition" DMG variant that ships without the model.
        //
        // We run this BEFORE `startSupervisorOrDeferUntilOnboarded()` so the
        // supervisor's `mci-agent` spawn (which calls `qwen3_model_present`
        // during brief-worker init) sees the seeded model on the very first
        // launch — no restart, no reopen-menu required.
        let seedOutcome = BriefModelPresence.seedBundledQwen3IfNeeded()
        firstLaunchLogger.info(
            "first-launch Qwen3 seed outcome: \(String(describing: seedOutcome), privacy: .public)"
        )

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
    ///   - The `Window("Download AI Model", id: "model-download")`
    ///     SwiftUI Scene declared in `HippocampusApp.body`, opened by
    ///     `openWindow(id:)` from the "Daily Briefs: Off — Download
    ///     Model…" menu item and closed by
    ///     `closeModelDownloadWindow()`.
    ///   - `NSAlert.runModal()` panels in `StatusMenuView`: About
    ///     (`openAboutWindow`), Reset TCC confirmation, error
    ///     alerts via `showAlert`, `KeyWrapAuditView` sheet.
    ///   - Any future SwiftUI window or sheet attached to the menu.
    ///
    /// Returning `false` here makes the app's lifecycle explicit:
    /// the app only quits via the "Quit Hippocampus" menu item
    /// (`supervisor.stop()` + `NSApp.terminate(nil)`) or
    /// `applicationWillTerminate` from the OS. The menu-bar status
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
