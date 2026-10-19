// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Structural checks for the executable's lifecycle; route behavior is tested
/// separately without launching the app or touching owner preferences.
final class PreferencesRoutingLifecycleTests: XCTestCase {
    func testParentRegistersPreferencesReceiverBeforeAsyncStartup() throws {
        let app = try source("HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let receiver = try XCTUnwrap(launch.range(of: "installPreferencesReceiver()"))
        let task = try XCTUnwrap(launch.range(of: "Task {"))
        XCTAssertLessThan(receiver.lowerBound, task.lowerBound)
        XCTAssertTrue(app.contains("PreferencesOpenRequest(arguments: Array(CommandLine.arguments.dropFirst()))"))
        let cleanup = try method("private func cleanUpLifecycle()", in: app)
        XCTAssertTrue(cleanup.contains("DistributedNotificationCenter.default().removeObserver(self)"))
    }

    func testDistributedRequestOnlyShowsAPaneThenAcknowledges() throws {
        let app = try source("HippocampusApp.swift")
        let handler = try method("private func receivePreferencesRequest(", in: app)
        let show = try XCTUnwrap(handler.range(of: "PreferencesWindowController.shared.show(section: request.section)"))
        let acknowledge = try XCTUnwrap(handler.range(of: "request.acknowledge(from: executable)"))
        XCTAssertLessThan(show.lowerBound, acknowledge.lowerBound)
        XCTAssertFalse(handler.contains("Task {"))
        XCTAssertFalse(handler.contains("setCaptureEnabled("))
        XCTAssertFalse(handler.contains("installSessionContext"))
        XCTAssertFalse(handler.contains("supervisor.start()"))
    }

    func testParentLeaseIsAcquiredBeforeGUIButNotForSessionHook() throws {
        let entry = try source("HippocampusEntryPoint.swift")
        let hook = try XCTUnwrap(entry.range(of: "SessionContextHook.runCLI("))
        let lease = try XCTUnwrap(entry.range(of: "ParentApplicationLease.acquire("))
        let gui = try XCTUnwrap(entry.range(of: "withExtendedLifetime(lease) { HippocampusApp.main() }"))
        XCTAssertLessThan(hook.lowerBound, lease.lowerBound)
        XCTAssertLessThan(lease.lowerBound, gui.lowerBound)
        XCTAssertTrue(entry.contains("PreferencesOpenRequest(arguments: arguments)?.post(to: executable)"))
    }

    func testPreferencesLaunchDoesNotOpenASecondRecallWindowAtStartup() throws {
        let app = try source("HippocampusApp.swift")
        let start = try method("private func startSupervisorOrDeferUntilOnboarded()", in: app)
        // Only a launch by the person opens the window: not Preferences, a
        // quiet relaunch, a login or a link (spec-shell S7). `AppOpening`
        // decides from the launch's reason; `AppOpeningTests` holds every
        // reason to it.
        XCTAssertTrue(start.contains("AppOpening.atLaunch("))
        XCTAssertTrue(start.contains("launchReason, setupFinished: OnboardingSentinel.isComplete"))
        XCTAssertEqual(start.components(separatedBy:
            "if opening == .window { supervisor.openRecallWhenReady(initialLaunch: true) }")
            .count - 1, 1)
        XCTAssertEqual(start.components(separatedBy: "openRecallWhenReady(").count - 1, 1)
    }

    /// At login nothing else opens the window: the only other calls are the
    /// first window after setup closes, which only setup's sentinel watcher
    /// starts, and opening the app again while it runs (07fedaf). Opening it
    /// again shows setup while setup is unfinished, and otherwise the window.
    func testOnlyTheGuardedLaunchSetupAndReopenOpenTheWindow() throws {
        let app = try source("HippocampusApp.swift")
        XCTAssertEqual(app.components(separatedBy: "openRecallWhenReady(").count - 1, 2)
        XCTAssertEqual(app.components(separatedBy: "reopenWindow()").count - 1, 1)
        let finishLaunching = try method("func applicationDidFinishLaunching(", in: app)
        // Ask's actions name the window in closures; none opens it at launch.
        XCTAssertFalse(finishLaunching.contains("openRecallWhenReady"))
        XCTAssertFalse(finishLaunching.contains("reopenWindow"))
        XCTAssertTrue(try method("private func openWindowWhenSetupCloses()", in: app)
            .contains("openRecallWhenReady(initialLaunch: true)"))
        let reopen = try method("func applicationShouldHandleReopen(", in: app)
        XCTAssertTrue(reopen.contains("AppOpening.atReopen("))
        XCTAssertTrue(reopen.contains("case .setup: supervisor.showOnboarding()"))
        XCTAssertTrue(reopen.contains("case .window: supervisor.reopenWindow()"))
        // Setup closing opens the window only after the sentinel appears,
        // which the watcher armed on a first run waits for.
        let afterSetup = try method("private func startCaptureAfterOnboarding()", in: app)
        XCTAssertTrue(afterSetup.contains("openWindowWhenSetupCloses()"))
        XCTAssertEqual(app.components(separatedBy: "startCaptureAfterOnboarding()").count - 1, 3,
                       "declared once, called only by the sentinel watcher and its poll")
        let start = try method("private func startSupervisorOrDeferUntilOnboarded()", in: app)
        XCTAssertFalse(start.contains("startCaptureAfterOnboarding"))
    }

    private func source(_ name: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/\(name)"), encoding: .utf8)
    }

    private func method(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    func testPreferencesDependenciesHaveOneAppDelegateOwnerSharedWithMenu() throws {
        let app = try source("HippocampusApp.swift")
        let boundary = try XCTUnwrap(app.range(of: "final class AppDelegate:"))
        let delegate = String(app[boundary.lowerBound...])
        let scene = String(app[..<boundary.lowerBound])
        for constructor in ["PreferencesStore()", "LoginItemViewModel(service: SMLoginItemService())", "SparkleUpdaterService()"] {
            XCTAssertEqual(app.components(separatedBy: constructor).count - 1, 1, constructor)
            XCTAssertTrue(delegate.contains(constructor), constructor)
            XCTAssertFalse(scene.contains(constructor), constructor)
        }
        // The menu-bar item is the delegate's; the scene carries commands only.
        XCTAssertTrue(delegate.contains("StatusItemController("))
        XCTAssertTrue(scene.contains("Settings {"))
        XCTAssertFalse(scene.contains("MenuBarExtra"))
        XCTAssertFalse(scene.contains("configurePreferencesController()"))
    }

    func testPreferencesConfigureSynchronouslyAtLaunchBeforeAsyncWork() throws {
        let app = try source("HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let configure = try XCTUnwrap(launch.range(of: "configurePreferencesController()"))
        let task = try XCTUnwrap(launch.range(of: "Task {"))
        XCTAssertLessThan(configure.lowerBound, task.lowerBound)
    }

    func testColdPreferencesRouteConfiguresBeforeShowingOnlyRequestedPane() throws {
        let app = try source("HippocampusApp.swift")
        let handler = try method("func application(_ application: NSApplication, open urls: [URL])", in: app)
        let start = try XCTUnwrap(handler.range(of: "case .openPreferences(let section):"))
        let end = try XCTUnwrap(handler.range(of: "\n            case ", range: start.upperBound..<handler.endIndex))
        let branch = String(handler[start.upperBound..<end.lowerBound])
        XCTAssertEqual(branch.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }, [
            "configurePreferencesController()",
            "PreferencesWindowController.shared.show(section: section)",
        ])
    }

    func testControllerConfigurationIsOneShotAndDoesNotRunConsentActions() throws {
        let app = try source("HippocampusApp.swift")
        let configure = try method("private func configurePreferencesController()", in: app)
        XCTAssertTrue(configure.contains("guard !preferencesControllerConfigured else { return }"))
        XCTAssertTrue(configure.contains("preferencesControllerConfigured = true"))
        XCTAssertTrue(configure.contains("PreferencesWindowController.shared.configure("))
        XCTAssertFalse(configure.contains("startUpdater()"))
        XCTAssertFalse(configure.contains("markPrompted()"))
        XCTAssertFalse(configure.contains("installSessionContext"))
        XCTAssertFalse(configure.contains("setCaptureEnabled("))
    }

    func testSourcesKeepsExistingConsentViewAndSingleSectionType() throws {
        let window = try source("PreferencesWindow.swift")
        XCTAssertTrue(window.contains("case .sources: SessionContextPreferencesView(supervisor: supervisor,"))
        XCTAssertFalse(window.contains("enum PreferencesSection:"))
        XCTAssertTrue(window.contains("extension PreferencesSection {"))
    }

    /// The crash-report switch set a flag no build acts on: nothing sends a
    /// report without an upload address, and the app has none (ui-1).
    func testPreferencesOffersNoSwitchThatDoesNothing() throws {
        let preferences = try source("PreferencesWindow.swift")
        XCTAssertFalse(preferences.lowercased().contains("crash"))
    }
}
