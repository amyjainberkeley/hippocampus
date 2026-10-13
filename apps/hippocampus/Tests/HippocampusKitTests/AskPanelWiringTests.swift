// SPDX-License-Identifier: TBD-private
//
// How the executable wires Ask and the key. The app target cannot be
// imported, so these read its source, as MenuBarLifecycleTests and
// HiMarkViewTests do; behaviour lives in HippocampusKit and is tested there.

import XCTest
@testable import HippocampusKit

final class AskPanelWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/\(name)"), encoding: .utf8)
    }

    func testThePanelHangsFromTheBarAndCannotBeDragged() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("AskPanelPlacement(screen: screen)"))
        XCTAssertTrue(bar.contains("AskPanelPlacement.screen(\n            containing: NSEvent.mouseLocation"))
        XCTAssertTrue(bar.contains("model?.maxContentHeight = placement.maxContentHeight"))
        XCTAssertTrue(bar.contains(".frame(maxHeight: model.maxContentHeight)"))
        XCTAssertFalse(bar.contains(".frame(maxHeight: 520)"))
        XCTAssertTrue(bar.contains("isMovableByWindowBackground = false"))
        XCTAssertTrue(bar.contains("isMovable = false"))
        XCTAssertFalse(bar.contains("isMovableByWindowBackground = true"))
        XCTAssertFalse(bar.contains("visible.height * 0.22"), "no longer a fifth of the way down")
    }

    func testTheEntranceIsTheShortDropOrAFadeWithReduceMotion() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("animationBehavior = .none"))
        XCTAssertTrue(bar.contains("AskPanelEntrance(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"))
        XCTAssertTrue(bar.contains("panel.setFrame(entrance.start(for: final), display: false)"))
        XCTAssertTrue(bar.contains("panel.alphaValue = 0"))
        XCTAssertTrue(bar.contains("context.duration = entrance.duration"))
        XCTAssertTrue(bar.contains("guard !entering"), "a height that arrives during the entrance waits for it")
    }

    func testClosingAskHidesTheAppOnlyByTheTitledWindowRule() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("AskPanelDismissal.shouldHideApp(appIsActive: NSApp.isActive, otherWindows: others)"))
        XCTAssertFalse(bar.contains("$0.canBecomeMain"), "Preferences can never become main")
    }

    func testTheWindowInFrontIsReadAfterThePanelIsUp() throws {
        let bar = try source("CommandBar.swift")
        let show = try XCTUnwrap(bar.range(of: "func show(asking question: String? = nil)"))
        let body = String(bar[show.lowerBound...].prefix(1_200))
        let present = try XCTUnwrap(body.range(of: "present(panel)"))
        let fill = try XCTUnwrap(body.range(of: "fillContext(openID: openID)"))
        XCTAssertLessThan(present.lowerBound, fill.lowerBound)
        XCTAssertTrue(body.contains("supervisor.refreshCaptureStatus()"))
        XCTAssertTrue(bar.contains("Task.detached(priority: .userInitiated)"), "Accessibility is asked off the main thread")
    }

    func testTheFooterKnowsWhereSetupStands() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertEqual(bar.components(separatedBy: "askPanelStatus()").count - 1, 2,
                       "on show and on every status change")
        XCTAssertFalse(bar.contains("AskPanelStatus(supervisor.menuBarStatus)"))
        XCTAssertFalse(bar.contains("AskPanelStatus($0.menuBarStatus)"))
    }

    func testCopyForAIEndsWithTheOpenItWasPressedIn() throws {
        let bar = try source("CommandBar.swift")
        let hide = try XCTUnwrap(bar.range(of: "func hide() {"))
        let body = String(bar[hide.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("copyForAITask?.cancel()"))
        XCTAssertTrue(bar.contains("case .dropped: break"))
    }

    func testTheMarkFollowsTheMenuBarAndNoSparklesRemain() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("HiMarkView(style: .brand, state: model.status.mark)"))
        XCTAssertFalse(bar.contains("state: .remembering"), "the mark shows the live state")
        XCTAssertFalse(bar.contains("sparkles"))
    }

    func testThePanelDoesOneJob() throws {
        let bar = try source("CommandBar.swift")
        for retired in ["DayCard", "ModelCard", "KindBar", "Suggested for right now", "Ask or search your memory",
                        "Ask Hippocampus:", "About you", "Your day", "Copy context", "⌘↩", "Thinking on your Mac",
                        "Hippocampus knows what you’re looking at", "Text(\"Hippocampus\")"] {
            XCTAssertFalse(bar.contains(retired), retired)
        }
        for hint in ["\"Overview\"", "\"You\"", "\"Copy for your AI\"", "\"Copy Answer\"", "\"Sources\"", "\"This window\""] {
            XCTAssertTrue(bar.contains(hint), hint)
        }
        XCTAssertTrue(bar.contains("Text(model.footerText)"))
        XCTAssertTrue(bar.contains("Button(action.title) { perform(.status(action)) }"))
    }

    func testAskTellsOnboardingWhenItShowsAndTheAppWiresItsActions() throws {
        let app = try source("HippocampusApp.swift")
        XCTAssertTrue(app.contains("AskPanelNotice.announceShown(onboardingRunning: supervisor.onboardingIsRunning)"))
        XCTAssertTrue(app.contains("name, object: nil, userInfo: nil, deliverImmediately: true"))
        XCTAssertTrue(app.contains("openWindow: { tab in supervisor.openRecallUI(initialTab: tab) }"))
        // The footer's buttons run the tested HippocampusKit code, not a copy.
        XCTAssertTrue(app.contains("supervisor.performAskStatusAction(action) { NSWorkspace.shared.open($0) }"))
        XCTAssertFalse(app.contains("private func performAskStatusAction("))
        XCTAssertTrue(app.contains("SoloKeyMonitor.shared.watch.setFallbackRegistered(true)"))
        XCTAssertTrue(app.contains("SoloKeyMonitor.shared.watch.setFallbackRegistered(false)"))
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching("))
        XCTAssertFalse(String(app[launch.lowerBound...].prefix(4_000)).contains("CommandBarPreviewRenderer"),
                       "the renderer no longer runs after the scene exists")
    }

    func testTheRendererReturnsBeforeTheAppExistsAndPutsNothingOnScreen() throws {
        let entry = try source("HippocampusEntryPoint.swift")
        let render = try XCTUnwrap(entry.range(of: "if CommandBarPreviewRenderer.renderIfRequested() { return }"))
        let hook = try XCTUnwrap(entry.range(of: "SessionContextHook.runCLI("))
        let app = try XCTUnwrap(entry.range(of: "HippocampusApp.main()"))
        XCTAssertLessThan(render.lowerBound, hook.lowerBound)
        XCTAssertLessThan(render.lowerBound, app.lowerBound)
        let renderer = try source("CommandBarPreview.swift")
        XCTAssertTrue(renderer.contains("setActivationPolicy(.prohibited)"))
        for onScreen in ["orderFront", "makeKeyAndOrderFront", "NSWindow(", "NSPanel(", ".activate(", "NSApp.run", ".run()",
                         "NSStatusBar"] {
            XCTAssertFalse(renderer.contains(onScreen), onScreen)
        }
        XCTAssertTrue(renderer.contains("hosting.cacheDisplay(in: hosting.bounds, to: rep)"))
    }

    func testTheMenuNamesAskByWhatOpensIt() throws {
        let menu = try source("StatusMenuView.swift")
        XCTAssertFalse(menu.contains("Ask Hippocampus…"))
        XCTAssertTrue(menu.contains("Button(\"Ask\")"))
        XCTAssertTrue(menu.contains("watch.label == AskShortcut.fallbackLabel"))
    }

    func testPreferencesGeneralSaysHowTheKeyWorks() throws {
        let preferences = try source("PreferencesWindow.swift")
        XCTAssertTrue(preferences.contains("Toggle(\"Open at login\""))
        XCTAssertTrue(preferences.contains("Picker(\"Open Ask with\", selection: $store.askKey)"))
        XCTAssertTrue(preferences.contains("AskKeyCaption("))
        XCTAssertTrue(preferences.contains("Button(\"Open System Settings…\")"))
        for retired in ["Launch at login", "Show menu-bar icon", "Default view when opening recall UI",
                        "Recall popup", "always works", "will start automatically"] {
            XCTAssertFalse(preferences.contains(retired), retired)
        }
    }

    func testTheKeyMonitorKeepsTryingAndHearsTheAccessibilityNotice() throws {
        let monitor = try source("SoloKeyMonitor.swift")
        XCTAssertTrue(monitor.contains("AskKeyWatch("))
        XCTAssertTrue(monitor.contains("Notification.Name(\"com.apple.accessibility.api\")"))
        XCTAssertFalse(monitor.contains("guard key != .off, AXIsProcessTrusted() else { return false }"),
                       "the request is no longer dropped without Accessibility")
    }

    // MARK: Onboarding is running (RULINGS X1)

    @MainActor
    func testTheSupervisorKnowsWhenTheOnboardingItStartedIsOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let onboarding = dir.appendingPathComponent("onboarding")
        try "#!/bin/sh\nsleep 0.4\n".write(to: onboarding, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onboarding.path)
        let locator = FakeBinaryLocator()
        locator.onboardingURL = onboarding
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: FakeKeyStore(),
            runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(),
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        XCTAssertFalse(supervisor.onboardingIsRunning)
        XCTAssertTrue(supervisor.openOnboarding())
        XCTAssertTrue(supervisor.onboardingIsRunning)
        var running = true
        for _ in 0..<150 where running {
            try await Task.sleep(for: .milliseconds(20))
            running = supervisor.onboardingIsRunning
        }
        XCTAssertFalse(running, "closed onboarding no longer hears from Ask")
    }
}
