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
        let window = try source("Onboarding/SharedComponents/OnboardingWindow.swift")
        XCTAssertTrue(window.contains(".frame(width: OnboardingTheme.windowWidth, height: OnboardingTheme.windowHeight)"))
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
        XCTAssertTrue(welcome.contains("WelcomeDemoScript.frame(at: Date().timeIntervalSince(start), presses: presses)"))
        // Under Reduce Motion nothing moves: each moment whole, then the next.
        XCTAssertTrue(welcome.contains("guard !reduceMotion else {\n            await playStill()"))
        XCTAssertTrue(welcome.contains("WelcomeDemoScript.finalFrame("))
        XCTAssertTrue(welcome.contains("guard animates, demoFrame == nil else { return }"), "the renderer draws one frame")
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
        XCTAssertTrue(slide.contains("if !rows.contains(where: { $0.state.showsGuidance }) {\n                    Text(OnboardingCopy.permissionsFooter)"))
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
