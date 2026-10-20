// SPDX-License-Identifier: Apache-2.0
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

    /// A file of HippocampusKit, by its path inside it.
    private func kit(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/HippocampusKit/\(path)"), encoding: .utf8)
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
        let show = try XCTUnwrap(bar.range(of: "func show(asking question: String? = nil, from opening: AskPanelDismissal.Opening = .menu)"))
        let body = String(bar[show.lowerBound...].prefix(1_600))
        let present = try XCTUnwrap(body.range(of: "present(panel)"))
        let fill = try XCTUnwrap(body.range(of: "fillContext(openID: openID)"))
        XCTAssertLessThan(present.lowerBound, fill.lowerBound)
        XCTAssertTrue(body.contains("supervisor.refreshCaptureStatus()"))
        XCTAssertTrue(bar.contains("Task.detached(priority: .userInitiated)"), "Accessibility is asked off the main thread")
    }

    func testOpeningAskAsksForOneFreshReadOfTheWindowInFront() throws {
        let bar = try source("CommandBar.swift")
        let show = try XCTUnwrap(bar.range(of: "func show(asking question: String? = nil, from opening: AskPanelDismissal.Opening = .menu)"))
        let body = String(bar[show.lowerBound...].prefix(1_600))
        let opening = try XCTUnwrap(body.range(of: "if !panel.isVisible {"))
        let request = try XCTUnwrap(body.range(of: "supervisor.requestFreshRead()"))
        let present = try XCTUnwrap(body.range(of: "present(panel)"))
        XCTAssertLessThan(opening.lowerBound, request.lowerBound, "only when Ask opens, not when it is up already")
        XCTAssertLessThan(request.lowerBound, present.lowerBound)
        XCTAssertEqual(bar.components(separatedBy: "requestFreshRead()").count - 1, 1, "Shift twice and the menu both come here")
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
                        "Ask Hippocampus:", "About you", "Your day", "Copy context", "Thinking on your Mac",
                        "Hippocampus knows what you’re looking at", "Text(\"Hippocampus\")",
                        "\"Overview\"", "\"You\"", "\"Copy for your AI\""] {
            XCTAssertFalse(bar.contains(retired), retired)
        }
        for word in ["\"Sources\"", "\"This window\""] {
            XCTAssertTrue(bar.contains(word), word)
        }
        // The footer's keys are the model's, in words the launch copy check
        // reads (HandoffCopy): the window's places by their new names.
        XCTAssertTrue(bar.contains("ForEach(model.keyHints, id: \\.keys)"))
        let copy = try kit("HandoffCopy.swift")
        for word in ["\"Today\"", "\"About You\"", "\"Copy for Your AI\"", "\"Copy Answer\"", "\"Resume\""] {
            XCTAssertTrue(copy.contains(word), word)
        }
        XCTAssertTrue(bar.contains("Text(model.footerText)"))
        // The row's own words: Resume Now for a pause with an end.
        XCTAssertTrue(bar.contains("Button(model.footerActionTitle ?? action.title) { perform(.status(action)) }"))
    }

    /// ⌘↩ is Ask {Tool} and ⌥↩ resumes (SPEC 5.3.9, SPEC-DELTA 4): the
    /// field's Return reads its modifiers, which it once ignored.
    func testReturnReadsItsModifiers() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("if press.modifiers.contains(.command) {\n                        model.askAITool()"))
        XCTAssertTrue(bar.contains("} else if press.modifiers.contains(.option) {\n                        if let action = model.resumeSelected() { perform(action) }"))
        XCTAssertTrue(bar.contains("} else if let action = model.activate() {"))
    }

    /// Every copy for an AI tool follows the clipboard rules (SPEC 5.3.6),
    /// and the panel stays its six seconds over the tool it opened.
    func testCopiesFollowTheClipboardRulesAndTheNoteStays() throws {
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("guard ClipboardHygiene.copy(text) else {"))
        XCTAssertTrue(bar.contains("case .text(let text): self?.copyForYourAI(text)"))
        XCTAssertTrue(bar.contains("if let noteUntil, Date() < noteUntil { return }"))
        XCTAssertTrue(bar.contains("case .handoff(let plan, let tool):\n            deliver(plan, tool: tool)"))
        let model = try kit("CommandBar/CommandBarModel.swift")
        XCTAssertFalse(model.contains("\"mci_context\""), "⇧⌘C never copies the context tool's JSON")
    }

    /// The launch repair runs once, from launch, off the main thread.
    func testTheAppRepairsTheHooksOnceAtLaunch() throws {
        let app = try source("HippocampusApp.swift")
        XCTAssertEqual(app.components(separatedBy: "SessionContextInstaller.repairOnLaunch()").count - 1, 1)
        let repair = try kit("Handoff/HookRepair.swift")
        XCTAssertTrue(repair.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(repair.contains("installer.repairExistingEntries(movedHere: movedHere)"))
        XCTAssertTrue(SessionContextInstaller.isInstalledToStay(
            executableURL: URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/Hippocampus"),
            bundleURL: URL(fileURLWithPath: "/Applications/Hippocampus.app")))
        XCTAssertFalse(SessionContextInstaller.isInstalledToStay(
            executableURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Hippocampus.app/Contents/MacOS/Hippocampus"),
            bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Hippocampus.app")))
        XCTAssertFalse(SessionContextInstaller.isInstalledToStay(
            executableURL: URL(fileURLWithPath: "/Users/sam/dev/apps/hippocampus/.build/debug/Hippocampus"),
            bundleURL: URL(fileURLWithPath: "/Users/sam/dev/apps/hippocampus/.build/debug")),
            "a build run from elsewhere never points anyone's hooks at itself")
    }

    func testAskTellsOnboardingWhenItShowsAndTheAppWiresItsActions() throws {
        let app = try source("HippocampusApp.swift")
        XCTAssertTrue(app.contains("AskPanelNotice.announceShown(onboardingRunning: supervisor.onboardingIsRunning)"))
        XCTAssertTrue(app.contains("name, object: nil, userInfo: nil, deliverImmediately: true"))
        // Through the app's one way to the window (`WindowRequestRoutingTests`).
        XCTAssertTrue(app.contains("openWindow: { [weak self] tab in self?.openWindow(tab: tab) }"))
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
        // The menu and Preferences are drawn by the same run, after it.
        let status = try source("StatusPreview.swift")
        let prohibited = try XCTUnwrap(renderer.range(of: "setActivationPolicy(.prohibited)"))
        let menus = try XCTUnwrap(renderer.range(of: "StatusPreviewRenderer.render(to: out)"))
        XCTAssertLessThan(prohibited.lowerBound, menus.lowerBound)
        for source in [renderer, status] {
            for onScreen in ["orderFront", "makeKeyAndOrderFront", "NSWindow(", "NSPanel(", ".activate(", "NSApp.run",
                             ".run()", "NSStatusBar", "statusItem(", "runModal", "NSAlert"] {
                XCTAssertFalse(source.contains(onScreen), onScreen)
            }
            XCTAssertTrue(source.contains("hosting.cacheDisplay(in: hosting.bounds, to: rep)"))
        }
    }

    /// The menu's "Ask" is named by `AskShortcut` through `StatusMenuModel`,
    /// whose tests pin the badge and the ⌃⇧Space key equivalent.
    /// Opening `hippocampus://ask`, with or without a question, always
    /// shows Ask; only the key and Esc close it (RULINGS S12). In the
    /// preview install a second link hid Ask and its answer arrived unseen.
    func testALinkAlwaysShowsAskAndOnlyTheKeyClosesIt() throws {
        XCTAssertFalse(AskPanelDismissal.closes(.link, visible: true), "a second link keeps Ask up")
        XCTAssertFalse(AskPanelDismissal.closes(.menu, visible: true))
        XCTAssertTrue(AskPanelDismissal.closes(.key, visible: true))
        XCTAssertFalse(AskPanelDismissal.closes(.key, visible: false))
        // The link activates Hippocampus, which can take the keyboard from
        // Ask just after it shows; that is not a click away.
        XCTAssertFalse(AskPanelDismissal.closesOnResignKey(sinceLinkOpen: 0))
        XCTAssertFalse(AskPanelDismissal.closesOnResignKey(sinceLinkOpen: 0.4))
        XCTAssertTrue(AskPanelDismissal.closesOnResignKey(sinceLinkOpen: 1.5))
        XCTAssertTrue(AskPanelDismissal.closesOnResignKey(sinceLinkOpen: nil))

        let app = try source("HippocampusApp.swift")
        XCTAssertTrue(app.contains("case .ask(let question):"))
        XCTAssertTrue(app.contains("CommandBarController.shared.show(asking: question, from: .link)"))
        let bar = try source("CommandBar.swift")
        XCTAssertTrue(bar.contains("if AskPanelDismissal.closes(.key, visible: panel?.isVisible == true) { hide() } else { show(from: .key) }"))
        XCTAssertTrue(bar.contains("guard AskPanelDismissal.closesOnResignKey(sinceLinkOpen: sinceLink) else {"))
        XCTAssertTrue(bar.contains("if let question { model.ask(question) }"), "with q, it shows and asks")
    }

    func testTheMenuNamesAskByWhatOpensIt() throws {
        let menu = try source("StatusMenuView.swift")
        XCTAssertFalse(menu.contains("Ask Hippocampus…"))
        XCTAssertTrue(menu.contains("askLabel: askKey.label"))
        XCTAssertTrue(menu.contains("NSMenuItemBadge(string: badge)"))
    }

    func testPreferencesGeneralSaysHowTheKeyWorks() throws {
        // General shows the key picker from its own file (WP0, SPEC-DELTA 7),
        // so General's words are those two files together.
        let preferences = try source("PreferencesWindow.swift")
        let general = try preferences + source("AskKeyPicker.swift")
        XCTAssertTrue(preferences.contains("Toggle(\"Open at login\""))
        XCTAssertTrue(preferences.contains("AskKeyPicker(store: store, askKey: askKey)"))
        XCTAssertTrue(general.contains("Picker(\"Open Ask with\", selection: $store.askKey)"))
        XCTAssertTrue(general.contains("AskKeyCaption("))
        XCTAssertTrue(general.contains("Button(\"Open System Settings…\")"))
        for retired in ["Launch at login", "Show menu-bar icon", "Default view when opening recall UI",
                        "Recall popup", "always works", "will start automatically"] {
            XCTAssertFalse(general.contains(retired), retired)
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
