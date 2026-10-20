import XCTest
@testable import OnboardingKit

/// Rules that live in the view files, which tests cannot import.
final class OnboardingSourceScanTests: XCTestCase {
    private let sourcesRoot = onboardingPackageRoot.appendingPathComponent("Sources")

    private func sources() throws -> [(name: String, text: String)] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The lines of `text` that are code, not comments.
    private func code(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Opening Hippocampus while setup is open brings setup forward: the app
    /// activates this process. A minimized setup stayed in the Dock, since
    /// only this process can bring its window back out, so nothing appeared.
    func testSetupComesBackOutOfTheDockWhenItIsBroughtForward() throws {
        let app = try source("Onboarding/OnboardingApp.swift")
        let start = try XCTUnwrap(app.range(of: "func applicationDidBecomeActive(_ notification: Notification) {"))
        let body = app[start.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("for window in NSApp.windows where window.isMiniaturized"))
        XCTAssertTrue(body.contains("window.deminiaturize(nil)"))
    }

    func testSetupNeverAsksForCalendarOrContacts() throws {
        for (name, text) in try sources() {
            for call in ["EKEventStore", "CNContactStore", "requestFullAccessToEvents", "requestAccess(for:"] {
                XCTAssertFalse(text.contains(call), "\(name) mentions \(call)")
            }
        }
    }

    func testKeySetupStartsWhenPermissionsAppears() throws {
        let slide = try source("Onboarding/Slides/PermissionsSlide.swift")
        XCTAssertTrue(slide.contains(".task {\n            await prepareBrainVM.generateKey()\n        }"))
    }

    func testViewModelsKeepTheirStoresInMemoryUnlessSetupPassesTheFiles() throws {
        let model = try source("OnboardingKit/OnboardingFlowViewModel.swift")
        XCTAssertTrue(model.contains("stateStore: any OnboardingStateStore = InMemoryOnboardingStateStore()"))
        XCTAssertTrue(model.contains("consentStore: any OnboardingConsentStore = InMemoryOnboardingConsentStore()"))
        XCTAssertFalse(model.contains("= FileOnboardingStateStore()"), "a default that writes the person's file")
        let app = try source("Onboarding/OnboardingApp.swift")
        XCTAssertTrue(
            app.contains("stateStore: launch.usesResumeFile ? FileOnboardingStateStore() : InMemoryOnboardingStateStore()"),
            "setup keeps its place; a panel never moves it"
        )
        XCTAssertTrue(app.contains("let consentStore = FileOnboardingConsentStore()"))
        XCTAssertTrue(app.contains("consentStore: consentStore,"))
    }

    func testNoTestWritesADefaultsSuite() throws {
        // A suite leaves a file in the person's ~/Library/Preferences, and
        // CFFIXED_USER_HOME does not move it.
        let needle = "UserDefaults(" + "suiteName"
        let root = onboardingPackageRoot.appendingPathComponent("Tests")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(needle), url.lastPathComponent)
        }
    }

    func testClosingTheWindowEndsSetup() throws {
        let app = try source("Onboarding/OnboardingApp.swift")
        XCTAssertTrue(app.contains(
            "func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        true\n    }"
        ))
    }

    func testOnlyAChildProcessAsksForScreenRecording() throws {
        for (name, text) in try sources() where name != "OnboardingEntryPoint.swift" {
            XCTAssertFalse(code(text).contains { $0.contains("CGRequestScreenCaptureAccess(") }, name)
        }
    }

    // MARK: - The window

    func testSetupIsOneWindow760By560WithItsTitleBarHidden() throws {
        let app = code(try source("Onboarding/OnboardingApp.swift")).joined(separator: "\n")
        XCTAssertTrue(app.contains("Window(\"Hippocampus\", id: \"setup\")"), "a single window")
        XCTAssertFalse(app.contains("WindowGroup"), "⌘N would open a second one")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .newItem) {}"))
        XCTAssertTrue(app.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertTrue(app.contains(".preferredColorScheme(.light)"))
        let theme = try source("Onboarding/SharedComponents/OnboardingTheme.swift")
        XCTAssertTrue(theme.contains("static let windowWidth: CGFloat = 760"))
        XCTAssertTrue(theme.contains("static let windowHeight: CGFloat = 560"))
        // 760 by 560, shorter only on a screen too short for it (SPEC 7.7);
        // `SetupWindowFitTests` hold the sizes.
        let window = try source("Onboarding/SharedComponents/OnboardingWindow.swift")
        XCTAssertTrue(window.contains(
            ".frame(width: OnboardingTheme.windowWidth, height: min(OnboardingTheme.windowHeight, windowHeight))"
        ))
        XCTAssertTrue(app.contains("private let windowHeight = SetupWindow.fittedHeight()"))
        XCTAssertTrue(app.contains(".environment(\\.onboardingWindowHeight, windowHeight)"))
    }

    /// SPEC 7.7: setup opens centred on the display with the pointer, and
    /// joins the Space the person is on, over a full-screen app too, so it
    /// never pulls them to another Space.
    func testSetupOpensWhereThePersonIsAndOnTheirSpace() throws {
        let app = code(try source("Onboarding/OnboardingApp.swift")).joined(separator: "\n")
        XCTAssertTrue(app.contains(".background(SetupWindowReader { SetupWindow.place($0) })"))
        let window = code(try source("Onboarding/SharedComponents/SetupWindow.swift")).joined(separator: "\n")
        XCTAssertTrue(window.contains("window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])"))
        XCTAssertTrue(window.contains("let pointer = NSEvent.mouseLocation"))
        XCTAssertTrue(window.contains("SetupWindowFit.display(pointer: (pointer.x, pointer.y), screens: screens)"))
        XCTAssertTrue(window.contains("SetupWindowFit.origin(width: size.width, height: size.height, in: visible)"))
        XCTAssertTrue(window.contains("height: CGFloat(SetupWindowFit.height(visibleHeight: visible.height)))"),
                      "the same height the window's content is given")
    }

    /// SPEC 7.4: Done fades setup out in 200 ms, then it quits and the app
    /// opens the window.
    func testDoneFadesSetupOutThenQuits() throws {
        let flow = code(try source("Onboarding/OnboardingFlowView.swift")).joined(separator: "\n")
        XCTAssertTrue(flow.contains("flowVM.clearResumeState()\n            SetupWindow.fadeOutAndQuit()"))
        let window = code(try source("Onboarding/SharedComponents/SetupWindow.swift")).joined(separator: "\n")
        XCTAssertTrue(window.contains("context.duration = SetupExitMotion.fadeOut"))
        XCTAssertTrue(window.contains("for window in windows { window.animator().alphaValue = 0 }"))
        XCTAssertEqual(SetupExitMotion.fadeOut, 0.2)
    }

    func testTheOnboardingMenusAreGone() throws {
        for (name, text) in try sources() {
            let lines = code(text)
            XCTAssertFalse(lines.contains { $0.contains("CommandMenu(") }, "\(name): no Troubleshoot menu")
            XCTAssertFalse(lines.contains { $0.contains("stepLabel") }, "\(name): the dots say where you are")
        }
    }

    func testEveryScreenAfterWelcomePutsItsTitleInTheSamePlace() throws {
        // Welcome centres its hero; the four screens after it lay out from
        // the top, so the title stays put as the person moves on.
        let screens = ["WhatYouGetSlide", "PermissionsSlide", "PromiseSlide", "TryItSlide"]
        for screen in screens {
            let lines = code(try source("Onboarding/Slides/\(screen).swift"))
            XCTAssertTrue(lines.contains { $0.hasSuffix("SlideContainer {") }, "\(screen) lays out from the top")
            XCTAssertFalse(lines.contains { $0.contains("SlideContainer(alignment:") }, "\(screen) moves its title")
            XCTAssertTrue(lines.contains { $0.contains("ScreenHeader(title:") }, "\(screen) titles itself as the others do")
        }
    }

    func testBackShowsOnWhatYouGetPermissionsAndPromiseOnly() throws {
        let flow = try source("Onboarding/OnboardingFlowView.swift")
        XCTAssertTrue(flow.contains("back: flowVM.canGoBack ? { flowVM.back() } : nil"))
        XCTAssertTrue(try source("OnboardingKit/OnboardingFlowViewModel.swift")
            .contains("screen == .whatYouGet || screen == .permissions || screen == .promise"))
    }

    // MARK: - What the switch removed

    func testTheRetiredScreensAndTheirSupportAreGone() {
        let retired = [
            "Onboarding/Slides/HowItWorksSlide.swift", "Onboarding/Slides/TrustSlide.swift",
            "Onboarding/Slides/PrimaryHotkeySlide.swift", "Onboarding/Slides/LivePreviewSlide.swift",
            "Onboarding/Slides/RetentionSlide.swift", "Onboarding/Slides/PrepareBrainSlide.swift",
            "Onboarding/Slides/ConnectClaudeCodeSlide.swift", "Onboarding/Slides/DoneSlide.swift",
            "Onboarding/SharedComponents/TCCPreflightOverview.swift", "Onboarding/KeyWrapAuditView.swift",
            "Onboarding/RealModelDownloader.swift", "Onboarding/SimulatedModelDownloader.swift",
            "OnboardingKit/ModelDownloader.swift", "OnboardingKit/OnboardingStep.swift",
        ]
        for path in retired {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourcesRoot.appendingPathComponent(path).path), path)
        }
    }

    func testTheRewindLineAndItsDeadCodeAreGone() throws {
        for (name, text) in try sources() {
            for word in ["Rewind", "MigrationSource", "migrationSource", "applyLaunchURL", "onOpenURL", "onboarding://"] {
                XCTAssertFalse(text.contains(word), "\(name) mentions \(word)")
            }
        }
    }

    func testSetupOffersNoModelDownload() throws {
        // Every screen and panel is in the Onboarding target.
        let screens = sourcesRoot.appendingPathComponent("Onboarding")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: screens, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = code(try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(lines.contains { $0.contains("startDownload(") || $0.contains("Download (") },
                           url.lastPathComponent)
        }
        // No downloader is left to call, in either target (ui-1).
        for (name, text) in try sources() {
            for word in ["ModelDownloader", "startDownload", "downloadState"] {
                XCTAssertFalse(code(text).contains { $0.contains(word) }, "\(name) mentions \(word)")
            }
        }
        XCTAssertTrue(try source("Onboarding/OnboardingApp.swift")
            .contains("PrepareBrainViewModel(keyGenerator: LocalKeyGenerator())"))
    }

    // MARK: - The screens

    func testWelcomeDrawsTheHiMarkAndPlaysTheDemoFromItsScript() throws {
        let welcome = try source("Onboarding/Slides/WelcomeSlide.swift")
        // The mark is drawn from the icon's own geometry, never a bitmap.
        XCTAssertTrue(welcome.contains("HiMarkTile("), "the hi mark at the top")
        XCTAssertFalse(welcome.contains("AppIcon"))
        XCTAssertFalse(welcome.contains("Image(nsImage:"))
        // The keycaps are in the sentence and press as Ask opens in the demo,
        // as many times as the key is pressed.
        XCTAssertTrue(welcome.contains("KeycapRow(keycaps: key.keycaps, pressed: pressed"), "keycaps in the sentence")
        XCTAssertTrue(welcome.contains("let presses = key.pulseTimes.count"))
        // The script decides every frame, through the playback's own clock;
        // under Reduce Motion each moment shows whole, then the next
        // (`WelcomeDemoScript.stillFrame`), and the keycaps never press.
        XCTAssertTrue(welcome.contains("let next = playback.frame(presses: presses, reduceMotion: reduceMotion)"))
        XCTAssertTrue(welcome.contains("let down = !reduceMotion && next.keyDown"))
        XCTAssertTrue(welcome.contains("WelcomeDemoScript.finalFrame("))
        XCTAssertTrue(welcome.contains("guard animates, demoFrame == nil else { return }"), "the renderer draws one frame")
    }

    /// SPEC 7.3: the demo pauses while the pointer is over it, while setup's
    /// window is not the key window and once the person has moved past
    /// Welcome, and while paused no task runs for it.
    func testWelcomesDemoPausesWhileReadOrUnseenAndCostsNothingThen() throws {
        let welcome = try source("Onboarding/Slides/WelcomeSlide.swift")
        XCTAssertTrue(welcome.contains(".onHover { playback.hovering = $0 }"))
        XCTAssertTrue(welcome.contains(".onChange(of: activeState) { _, state in playback.windowIsKey = state == .key }"))
        XCTAssertTrue(welcome.contains(".onDisappear { playback.onWelcome = false }"))
        XCTAssertTrue(welcome.contains("DemoTaskID(key: key, reduceMotion: reduceMotion, playing: playback.isPlaying)"),
                      "pausing ends the task")
        XCTAssertTrue(welcome.contains("guard playback.isPlaying else {"), "a paused demo starts no loop")
    }

    func testTheDemoAndTheRendersShowOnlyMadeUpData() throws {
        // Welcome's demo and What you get draw `OnboardingCopy.Demo` only:
        // they read no memory and list no window.
        var files = ["Onboarding/Slides/WelcomeSlide.swift", "Onboarding/Slides/WhatYouGetSlide.swift",
                     "Onboarding/OnboardingPreviewRenderer.swift"]
        let demo = sourcesRoot.appendingPathComponent("Onboarding/Demo")
        let names = try FileManager.default.contentsOfDirectory(atPath: demo.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty)
        files += names.map { "Onboarding/Demo/\($0)" }
        for file in files {
            let lines = code(try source(file))
            for call in ["LastReadProbe", "AgentReaderLauncher", "WindowServerFrontWindowSource", "CGWindowList",
                         "PersonExclusions.load", "SecureTextEntry.isOn", "UnderstandingProbe", "DiskRetentionStore"] {
                XCTAssertFalse(lines.contains { $0.contains(call) }, "\(file) uses \(call)")
            }
        }
    }

    func testAnAppLaunchServicesCannotFindShowsMacOSsOwnAppIcon() throws {
        // Never a dashed placeholder: Try it names the app it read, and a
        // missing icon must still look like an app.
        let icons = code(try source("Onboarding/Demo/ProductMiniatures.swift"))
        XCTAssertTrue(icons.contains { $0.contains("?? NSWorkspace.shared.icon(for: .applicationBundle)") })
        XCTAssertFalse(icons.contains { $0.contains("\"app.dashed\"") })
    }

    func testTryItReadsTheRealWindowInFrontUnderTheSameRules() throws {
        let tryIt = code(try source("Onboarding/Slides/TryItSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(tryIt.contains("let windows = WindowServerFrontWindowSource()"))
        XCTAssertTrue(tryIt.contains("frontWindow: { windows.frontWindow() }"))
        XCTAssertTrue(tryIt.contains("rules: ReadRules(excludedApps: PersonExclusions.load())"))
        XCTAssertTrue(tryIt.contains("passwordFieldInUse: { SecureTextEntry.isOn() }"))
        // A window brought forward is read at once, as opening Ask reads it.
        XCTAssertTrue(tryIt.contains("requestFreshRead: { SetupReadRequest.post() }"))
        XCTAssertTrue(tryIt.contains("probe: AgentLastReadProbe(launcher: AgentReaderLauncher())"))
    }

    func testGreyTextIsTheWindowsOwnGreyNotMacOSsLighterOne() throws {
        // `OnboardingDesign.Palette.secondaryText` keeps 4.5:1; macOS's
        // secondary label renders under 4:1 on setup's surfaces.
        for (name, text) in try sources() {
            let lines = code(text)
            XCTAssertFalse(lines.contains { $0.contains("foregroundStyle(.secondary)") }, "\(name) uses .secondary")
            XCTAssertFalse(lines.contains { $0.contains("Color.secondary)") || $0.contains("= .secondary") },
                           "\(name) uses .secondary")
        }
    }

    func testWarningColoursMarkIconsNeverText() throws {
        // Orange or red text on white reads at about 2:1 to 4:1; a warning
        // shows its colour on an icon, beside text in the normal colours.
        let panel = code(try source("Onboarding/Slides/BrowserExtensionSlide.swift"))
        for (index, line) in panel.enumerated() where line.contains("Text(OnboardingCopy.extensionFolderMissing)") {
            let style = panel[index...].prefix(4).joined(separator: "\n")
            XCTAssertFalse(style.contains("Palette.attention"), "the missing-folder line is orange text")
            XCTAssertTrue(style.contains(".foregroundStyle(.primary)"))
        }
        XCTAssertTrue(panel.contains { $0.contains("Text(OnboardingCopy.extensionFolderMissing)") })
    }

    func testTheOnlyGradientIsTheAppIconsTile() throws {
        // Backdrops stay the native material; the hi mark's tile carries the
        // icon's own white-to-grey fall.
        for (name, text) in try sources() where name != "HiMarkTile.swift" {
            XCTAssertFalse(code(text).contains { $0.range(of: "gradient", options: .caseInsensitive) != nil },
                           "\(name) draws a gradient")
        }
        let tile = try source("Onboarding/SharedComponents/HiMarkTile.swift")
        XCTAssertTrue(tile.contains("OnboardingHiMark.tileTopRGB"))
        XCTAssertTrue(tile.contains("OnboardingHiMark.tileBottomRGB"))
    }

    func testTryItsKeycapsPressOnlyLiveAndNeverUnderReduceMotion() throws {
        let tryIt = code(try source("Onboarding/Slides/TryItSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(tryIt.contains("guard now == nil, !reduceMotion, presentation.keyPresses > 0 else { return }"))
        XCTAssertTrue(tryIt.contains("KeycapRow(keycaps: presentation.keycaps, pressed: keyDown, size: 13)"))
        XCTAssertTrue(tryIt.contains("AskKeyHint.pulseTimes(presses: presentation.keyPresses)"), "Welcome's times")
    }

    func testOpenItForMeIsALink() throws {
        let tryIt = try source("Onboarding/Slides/TryItSlide.swift")
        XCTAssertTrue(tryIt.contains(
            "Button(OnboardingCopy.openItForMe) { perform(.openItForMe) }\n                .onboardingText("
        ))
        XCTAssertTrue(tryIt.contains("tryIt.willOpenAskForThem()\n            NSWorkspace.shared.open(AppLink.ask)"))
    }

    func testTryItSendsNobodyToTheExtensionPanel() throws {
        // Browsers are read like every other window (RULINGS G8), so Try
        // it has no "Add Extension" and the flow opens no panel over itself.
        let tryIt = code(try source("Onboarding/Slides/TryItSlide.swift")).joined(separator: "\n")
        XCTAssertFalse(tryIt.contains("openPanel"))
        XCTAssertFalse(tryIt.contains(".browserExtension"))
        let flow = code(try source("Onboarding/OnboardingFlowView.swift")).joined(separator: "\n")
        XCTAssertFalse(flow.contains("OnboardingPanelView("), "panels open by route, after consent")
    }

    func testTheOpenAtLoginCheckboxIsShownOnlyBeforeConsent() throws {
        let promise = try source("Onboarding/Slides/PromiseSlide.swift")
        XCTAssertTrue(promise.contains("openAtLogin: flowVM.isReview ? nil : $flowVM.openAtLogin"))
        XCTAssertTrue(promise.contains("Toggle(OnboardingCopy.openAtLogin, isOn: openAtLogin)"))
    }

    func testThePromiseShowsItsFactsOneSentenceALine() throws {
        let promise = code(try source("Onboarding/Slides/PromiseSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(promise.contains("ForEach(OnboardingCopy.sentences(text), id: \\.self)"))
    }

    func testAWaitingPermissionRowShowsOneStepALine() throws {
        let row = code(try source("Onboarding/Slides/PermissionsSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(row.contains("ForEach(OnboardingCopy.sentences(OnboardingCopy.waitingHint(row.surface)), id: \\.self)"))
        XCTAssertEqual(OnboardingCopy.sentences(OnboardingCopy.waitingHint(.screenRecording)), [
            "Choose Open System Settings, then turn on Hippocampus.", "If macOS offers Quit & Reopen, choose Later.",
        ])
    }

    func testThePromiseIsTitledByMode() throws {
        let promise = code(try source("Onboarding/Slides/PromiseSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(promise.contains("title: OnboardingCopy.promiseTitle(isReview: flowVM.isReview)"))
        XCTAssertTrue(promise.contains("ScreenHeader(title: title, intro: intro)"))
        XCTAssertFalse(promise.contains("ScreenHeader(title: OnboardingCopy.promiseTitle,"), "one title for both modes")
    }

    func testTryItTakesRememberingAndThePermissionsFromTheFlowWhenItNeedsThem() throws {
        let flow = code(try source("Onboarding/OnboardingFlowView.swift")).joined(separator: "\n")
        // A first run is on whatever the app said at spawn.
        XCTAssertTrue(flow.contains("remembering: flowVM.rememberingForTryIt(environment: ProcessInfo.processInfo.environment)"))
        XCTAssertFalse(flow.contains("RememberingState(environment:"))
        // Checked when nothing was read, not what was seen at consent.
        XCTAssertTrue(flow.contains("permissionsOn: { [flowVM] in await flowVM.permissionsStillOn() }"))
        XCTAssertFalse(flow.contains("Permission.status == .granted"))
    }

    func testThePermissionsFooterMakesRoomForARowThatSaysWhatToDo() throws {
        let slide = code(try source("Onboarding/Slides/PermissionsSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(slide.contains(
            "if !rows.contains(where: { $0.state.showsGuidance }) {\n                        Text(rows.allSatisfy { $0.state == .granted } ? OnboardingCopy.bothOn : OnboardingCopy.permissionsFooter)"
        ), "the footer says both are on once they are (SPEC 7.2)")
        XCTAssertFalse(slide.contains(".frame(maxWidth: 480"), "the help line takes the row's width")
    }

    func testTheBrowserExtensionPanelTakesEveryWordFromTheCopyFile() throws {
        // Preferences opens it, so its words are held by the copy tests
        // like the five screens'.
        let panel = code(try source("Onboarding/Slides/BrowserExtensionSlide.swift"))
        let literalWords = try NSRegularExpression(pattern: #"(Text|Button|title:|body:)\(?\s*"[A-Za-z]"#)
        for line in panel {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(literalWords.firstMatch(in: line, range: range), line)
            for mark in ["→", "—", "SectionChip("] {
                XCTAssertFalse(line.contains(mark), line)
            }
        }
        XCTAssertTrue(panel.contains { $0.contains("BrowserExtensionScreen(") }, "a screen the renderer draws")
        let renderer = try source("Onboarding/OnboardingPreviewRenderer.swift")
        XCTAssertTrue(renderer.contains("add(\"panel-browser-extension\""))
    }

    // MARK: - Moving between screens (SPEC 7.1)

    func testEveryScreenArrivesFromTheWaySetupMovesAndTheTitleFirst() throws {
        let flow = code(try source("Onboarding/OnboardingFlowView.swift")).joined(separator: "\n")
        XCTAssertTrue(flow.contains(".transition(OnboardingDesign.Motion.screen(move, reduceMotion: reduceMotion))"))
        XCTAssertTrue(flow.contains("move = ScreenMove(from: old, to: new)"))
        XCTAssertTrue(flow.contains("withAnimation(OnboardingDesign.Motion.screenAnimation(reduceMotion: reduceMotion))"))
        let design = code(try source("Onboarding/SharedComponents/OnboardingDesign.swift")).joined(separator: "\n")
        XCTAssertTrue(design.contains("insertion: .opacity.combined(with: .offset(x: transition.incomingOffset))"))
        XCTAssertTrue(design.contains("removal: .opacity.combined(with: .offset(x: transition.outgoingOffset))"))
        // The title arrives first and the content 60 ms after it, on every
        // screen after Welcome as on Welcome.
        for screen in ["WelcomeSlide", "WhatYouGetSlide", "PermissionsSlide", "PromiseSlide", "TryItSlide"] {
            XCTAssertTrue(code(try source("Onboarding/Slides/\(screen).swift")).contains { $0.contains(".arrivesAfterTitle()") },
                          screen)
        }
    }

    func testVoiceOverAndTheKeyboardMoveWithTheScreen() throws {
        // SPEC 7.1, 7.7: each title is a heading and takes VoiceOver's focus
        // when its screen arrives; full keyboard access lands on the
        // primary button, and Return presses it.
        let window = try source("Onboarding/SharedComponents/OnboardingWindow.swift")
        XCTAssertTrue(window.contains(".accessibilityAddTraits(.isHeader)\n        .arrivalFocus()"))
        XCTAssertTrue(window.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(window.contains(".onChange(of: screen) { primaryFocused = true }"))
        XCTAssertTrue(window.contains(".accessibilityHint(primaryDisabledReason ?? \"\")"), "an off button says why")
        let welcome = try source("Onboarding/Slides/WelcomeSlide.swift")
        XCTAssertTrue(welcome.contains(".accessibilityAddTraits(.isHeader)\n                    .arrivalFocus()"))
        let arrival = try source("Onboarding/SharedComponents/ScreenArrival.swift")
        XCTAssertTrue(arrival.contains(".accessibilityFocused($focused)"))
        let flow = try source("Onboarding/OnboardingFlowView.swift")
        XCTAssertTrue(flow.contains("return flowVM.bothGranted ? nil : OnboardingCopy.turnOnBothFirst"))
    }

    func testTheButtonKeepsItsWidthAndTheDotsAndFadesFollowTheTokens() throws {
        let window = code(try source("Onboarding/SharedComponents/OnboardingWindow.swift")).joined(separator: "\n")
        XCTAssertTrue(window.contains("Text(label).hidden()"), "the widest label holds the width")
        XCTAssertTrue(window.contains(".opacity(primaryEnabled ? 1 : PrimaryButtonMotion.disabledOpacity)"))
        XCTAssertTrue(window.contains(".animation(animation(PrimaryButtonMotion.enableFade), value: primaryEnabled)"))
        XCTAssertTrue(window.contains(".animation(animation(PrimaryButtonMotion.labelCrossfade), value: primaryLabel)"))
        let dots = code(try source("Onboarding/SharedComponents/ProgressDots.swift")).joined(separator: "\n")
        XCTAssertTrue(dots.contains("index == current ? ProgressDotsMotion.activeWidth : ProgressDotsMotion.dotWidth"))
        XCTAssertTrue(dots.contains("ProgressDotsMotion.animationDuration(reduceMotion: reduceMotion)"))
    }

    func testIncreaseContrastMakesCardsSolidAndHairlinesStrong() throws {
        let card = code(try source("Onboarding/SharedComponents/GlassCard.swift")).joined(separator: "\n")
        XCTAssertTrue(card.contains(": reduceTransparency || solidFills || increasedContrast"))
        let window = code(try source("Onboarding/SharedComponents/OnboardingWindow.swift")).joined(separator: "\n")
        XCTAssertTrue(window.contains(".fill(increasedContrast ? Color.primary.opacity(0.45) : Color.primary.opacity(0.1))"))
        let promise = code(try source("Onboarding/Slides/PromiseSlide.swift"))
        XCTAssertFalse(promise.contains { $0.contains("Divider()") }, "the Promise's lines follow Increase Contrast")
    }

    // MARK: - The key that opens Ask (SPEC-DELTA 7)

    func testSetupsKeyPickerOpensFromTheAccessibilityRowAndTakesFnOnlyOnAClick() throws {
        let slide = code(try source("Onboarding/Slides/PermissionsSlide.swift")).joined(separator: "\n")
        XCTAssertTrue(slide.contains("Button(OnboardingCopy.AskKey.change, action: changeKey)"))
        XCTAssertTrue(slide.contains("stored: AskShortcutLabel.storedValue(), facts: .thisMac,"))
        XCTAssertTrue(slide.contains("SetupAskKeyWriter.chooseOnThisMac(chosen, accepting: accepted)"))
        let sheet = code(try source("Onboarding/Slides/AskKeySheet.swift")).joined(separator: "\n")
        XCTAssertTrue(sheet.contains("Button(model.confirmLabel, action: confirm)"), "Use Fn when something else uses it")
        XCTAssertTrue(sheet.contains("Button(OnboardingCopy.AskKey.cancel, action: cancel)"))
        XCTAssertTrue(sheet.contains("model.recheck()"), "back from Keyboard settings, it looks again")
        // Only the sheet writes the choice, through the writer.
        for (name, text) in try sources() where name != "AskKeyChoice.swift" {
            XCTAssertFalse(code(text).contains { $0.contains("CFPreferencesSetAppValue") }, name)
        }
    }

    func testTheRenderersKeyPickerReadsNothingOnThisMac() throws {
        let renderer = code(try source("Onboarding/OnboardingPreviewRenderer.swift"))
        for call in ["FnKeyFacts.thisMac", "facts: .thisMac", "MacFacts.", "acceptedOnThisMac", "chooseOnThisMac"] {
            XCTAssertFalse(renderer.contains { $0.contains(call) }, "the renderer uses \(call)")
        }
    }

    func testTheKeyMonitorNeverAsksForInputMonitoring() throws {
        // Keyboards are read from the I/O Registry's properties; none is
        // opened for input, which would raise macOS's Input Monitoring prompt.
        let choice = code(try source("OnboardingKit/AskKeyChoice.swift")).joined(separator: "\n")
        XCTAssertTrue(choice.contains("IOServiceGetMatchingServices"))
        for call in ["IOHIDManagerOpen", "IOHIDDeviceOpen", "IOHIDRequestAccess", "CGEventTapCreate", "addGlobalMonitorForEvents"] {
            XCTAssertFalse(choice.contains(call), call)
        }
    }

    // MARK: - The preview renderer

    func testThePreviewRendererDrawsNothingOnScreen() throws {
        let renderer = try source("Onboarding/OnboardingPreviewRenderer.swift")
        XCTAssertTrue(renderer.hasPrefix("#if DEBUG\n"), "debug builds only")
        XCTAssertTrue(renderer.contains("NSApplication.shared.setActivationPolicy(.prohibited)"))
        for call in ["NSWindow", "orderFront", "makeKey", ".run()", "activate(", "NSStatusBar", "NSSound"] {
            XCTAssertFalse(code(renderer).contains { $0.contains(call) }, "the renderer must not use \(call)")
        }
        // It runs first, before the parent watch and the app.
        let entry = code(try source("Onboarding/OnboardingEntryPoint.swift")).joined(separator: "\n")
        let render = try XCTUnwrap(entry.range(of: "OnboardingPreviewRenderer.renderIfRequested()"))
        let watch = try XCTUnwrap(entry.range(of: "ParentProcessWatch {"))
        let app = try XCTUnwrap(entry.range(of: "OnboardingApp.main()"))
        XCTAssertLessThan(render.lowerBound, watch.lowerBound)
        XCTAssertLessThan(render.lowerBound, app.lowerBound)
        XCTAssertTrue(entry.contains("if OnboardingPreviewRenderer.renderIfRequested() { return }"))
    }
}
