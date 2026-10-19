// SPDX-License-Identifier: Apache-2.0
//
// How the executable wires the status item, the app's commands, Preferences
// and the supervisor's stores (spec-shell S2, S5 and S8; RULINGS S3, S4, S7,
// S10). The app target cannot be imported, so these read its source, as
// AskPanelWiringTests does; the behaviour lives in HippocampusKit and is
// tested there.

import XCTest

final class StatusItemWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.package.appendingPathComponent("Sources/Hippocampus/\(name)"), encoding: .utf8)
    }

    private static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func method(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// An AppKit status item, built from the pure model, that keeps its
    /// place and never quits the app when removed (critique-shell-engineering 13).
    func testTheMenuIsAnAppKitStatusItemBuiltFromTheModel() throws {
        let menu = try source("StatusMenuView.swift")
        XCTAssertTrue(menu.contains("NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)"))
        XCTAssertTrue(menu.contains("statusItem.autosaveName = \"ai.hippocampus.status\""))
        XCTAssertFalse(menu.contains("terminationOnRemoval"))
        XCTAssertTrue(menu.contains("StatusMenuModel.items("))
        XCTAssertTrue(menu.contains("button.image = MenuBarStatusIcon.image(for: status)"))
        XCTAssertTrue(menu.contains("button.toolTip = label"))
        XCTAssertTrue(menu.contains("button.setAccessibilityLabel(label)"))
        XCTAssertTrue(menu.contains("StatusMenuModel.accessibilityLabel("))
        let open = try method("func menuNeedsUpdate(_ menu: NSMenu)", in: menu)
        for chore in ["supervisor.refreshCaptureStatus()", "modelProvisioner.refreshIfMissing()",
                      "supervisor.retryIfPermissionMayBeBack()"] {
            XCTAssertTrue(open.contains(chore), chore)
        }
        // The look comes first, so the menu shows what it started, as the
        // icon does, never "Needs permission" over a helper starting.
        let look = try XCTUnwrap(open.range(of: "supervisor.retryIfPermissionMayBeBack()"))
        let build = try XCTUnwrap(open.range(of: "StatusMenuModel.items("))
        XCTAssertLessThan(look.lowerBound, build.lowerBound)
        for retired in ["Open Recall", "Open Timeline", "Open Daily Brief", "Start Recording", "Stop Recording",
                        "Open Onboarding", "Troubleshoot", "Inspect Key Wrap", "Send Feedback", "MCP Registration",
                        "markPrompted", "startUpdater"] {
            XCTAssertFalse(menu.contains(retired), retired)
        }
    }

    /// ⌘, and ⌘Q work wherever Hippocampus is active, through the scene's
    /// commands and never an app-wide key monitor (RULINGS S7).
    func testCommandQAndCommandCommaAreTheScenesCommands() throws {
        let app = try source("HippocampusApp.swift")
        let boundary = try XCTUnwrap(app.range(of: "final class AppDelegate:"))
        let scene = String(app[..<boundary.lowerBound])
        XCTAssertTrue(scene.contains("Settings { EmptyView() }"))
        XCTAssertTrue(scene.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(scene.contains("CommandGroup(replacing: .appTermination)"))
        XCTAssertTrue(scene.contains("Button(\"Quit Hippocampus\") { appDelegate.requestQuit() }"))
        XCTAssertTrue(scene.contains(".keyboardShortcut(\"q\", modifiers: [.command])"))
        XCTAssertTrue(scene.contains(".keyboardShortcut(\",\", modifiers: [.command])"))
        for source in [app, try source("StatusMenuView.swift"), try source("CommandBar.swift")] {
            XCTAssertFalse(source.contains("addLocalMonitorForEvents(matching: .keyDown)"))
        }
    }

    /// The updater starts at launch, not when the menu first opens (D15).
    func testTheUpdaterStartsAtLaunch() throws {
        let app = try source("HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let task = try XCTUnwrap(launch.range(of: "Task {"))
        let start = try XCTUnwrap(launch.range(of: "self.updater.startUpdater()"))
        let check = try XCTUnwrap(launch.range(of: "self.updater.scheduleBackgroundCheck(after: 10.0)"))
        XCTAssertLessThan(task.lowerBound, start.lowerBound)
        XCTAssertLessThan(start.lowerBound, check.lowerBound)
        XCTAssertTrue(launch.contains("installStatusItem()"))
    }

    /// One performer for the status row's button, wherever it is pressed;
    /// Quit is the app's.
    func testTheStatusButtonRunsTheSupervisorsCodeAndQuitIsTheApps() throws {
        let app = try source("HippocampusApp.swift")
        let perform = try method("func performStatusAction(_ action: CaptureStatusAction)", in: app)
        let quit = try XCTUnwrap(perform.range(of: "requestQuit()"))
        let supervisor = try XCTUnwrap(perform.range(of: "supervisor.performAskStatusAction(action) { NSWorkspace.shared.open($0) }"))
        XCTAssertLessThan(quit.lowerBound, supervisor.lowerBound)
        XCTAssertEqual(app.components(separatedBy: "self?.performStatusAction(action)").count - 1, 3,
                       "the menu, Ask's footer and Preferences")
    }

    /// Stop Sharing and Pause are kept across launches; a failed start the
    /// person asked to see opens Preferences; a permission turned back on is
    /// noticed when the app becomes active.
    func testTheSupervisorKeepsItsNotesAndHandsOverAFailedStart() throws {
        let app = try source("HippocampusApp.swift")
        XCTAssertTrue(app.contains("captureStopNote: UserDefaultsCaptureStopNote(),"))
        XCTAssertTrue(app.contains("pauses: .shared"))
        XCTAssertTrue(app.contains("supervisor.onPresentationBlocked = {"))
        XCTAssertTrue(app.contains("PreferencesWindowController.shared.show(section: .capture)"))
        let active = try method("func applicationDidBecomeActive(", in: app)
        XCTAssertTrue(active.contains("supervisor.retryIfPermissionMayBeBack()"))
    }

    /// Preferences' words (spec-copy S4.4, product critique 9, 10, 11, 16;
    /// RULINGS S10): the facts of NOTICE and LICENSE, no key inspector.
    func testPreferencesSayWhatIsTrue() throws {
        let preferences = try source("PreferencesWindow.swift")
        for kept in ["Toggle(\"Remember my screen\"", "Button(\"Choose Apps…\")", "Button(\"What Is Never Read…\")",
                     "Picker(\"Keep my memory for\"", "\"Anything older is deleted for good.\"",
                     "Button(\"See or Delete What’s Remembered…\")", "Text(\"Troubleshooting\")",
                     "Button(\"Show Logs\")", "Button(\"Reset Permissions…\")",
                     "Button(\"Show Setup Again\")", "Button(\"Restart Hippocampus\")", "Button(\"Check for Updates…\")",
                     "Toggle(\"Check for updates automatically\"", "Text(\"© 2026 Amy Jain\")",
                     "Text(\"Apache License 2.0\")", "PermissionReset.confirmMessage", "item.label = section.label",
                     "CaptureHealthView(supervisor: supervisor, perform: actions.statusAction)"] {
            XCTAssertTrue(preferences.contains(kept), kept)
        }
        for retired in ["Capture screen activity", "Capture area", "Focused window", "Screen capture is",
                        "denylist", "allowlist", "Retention policy", "Keep events for", "Custom database path",
                        "Export debug bundle", "Automatic updates (Sparkle)", "Git SHA", "Memory Context Interface", "License: TBD",
                        "total-recall", "Inspect Key Wrap", "KeyWrapAudit", "Refresh Status", "Open Capture Logs",
                        "audit log", "Open Privacy Dashboard", "Report an issue on GitHub", "License (Apache 2.0)",
                        // It set a flag nothing acts on (ui-1).
                        "Send crash reports"] {
            XCTAssertFalse(preferences.contains(retired), retired)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Self.package.appendingPathComponent("Sources/Hippocampus/KeyWrapAuditView.swift").path
        ), "no key-custody inspector in the interface this round")
    }

    /// The switch reads On while a turn-on is under way, since its helper
    /// may read before the setting is; turning it off then drops the turn-on.
    func testTheSwitchReadsOnWhileTurningOn() throws {
        let preferences = try source("PreferencesWindow.swift")
        XCTAssertTrue(preferences.contains("get: { supervisor.captureEnabled || supervisor.turningOn }"))
    }

    /// One row feeds Preferences too (product critique 11).
    func testPreferencesShowTheMenusStatusRow() throws {
        let health = try source("CaptureHealthView.swift")
        XCTAssertTrue(health.contains("let status = supervisor.menuBarStatus"))
        XCTAssertTrue(health.contains("let row = supervisor.statusRow()"))
        XCTAssertTrue(health.contains("Text(row.title)"))
        XCTAssertTrue(health.contains("Button(action.title) { perform(action) }"))
        for retired in ["storedCountsText", "lastSavedText", "unverified", "No saved memory in the last report",
                        "indicatorColor"] {
            XCTAssertFalse(health.contains(retired), retired)
        }
    }

    /// The AI Tools pane says, once, what Quit does not stop (RULINGS S4),
    /// and names nothing internal (product critique 5).
    func testTheAIToolsPaneSaysWhatQuitDoesNotStop() throws {
        let pane = try source("SessionContextPreferencesView.swift")
        XCTAssertEqual(pane.components(separatedBy: "AIToolsCopy.whileQuit").count - 1, 1)
        XCTAssertTrue(pane.contains("Text(AIToolsCopy.paneTitle)"))
        XCTAssertTrue(pane.contains("Toggle(AIToolsCopy.sessionToggle"))
        for retired in ["AI Context", "MCP", "Register", "provider", "verified", "Enable Session Context"] {
            XCTAssertFalse(pane.contains(retired), retired)
        }
        let connect = try source("ConnectAITools.swift")
        XCTAssertTrue(connect.contains("AIToolConnector(agentURL: agent, baseEnvironment: environment).connect()"))
        XCTAssertTrue(connect.contains("AIToolsCopy.result(report, sessionErrors: sessionErrors)"))
        XCTAssertTrue(connect.contains("NSApp.activate()"), "an alert from a menu-bar app comes to the front")
    }
}
