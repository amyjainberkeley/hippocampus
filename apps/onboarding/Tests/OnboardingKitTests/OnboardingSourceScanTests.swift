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

    func testBackShowsOnPermissionsAndPromiseOnly() throws {
        let flow = try source("Onboarding/OnboardingFlowView.swift")
        XCTAssertTrue(flow.contains("back: flowVM.canGoBack ? { flowVM.back() } : nil"))
        XCTAssertTrue(try source("OnboardingKit/OnboardingFlowViewModel.swift")
            .contains("screen == .permissions || screen == .promise"))
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
            "OnboardingKit/OnboardingStep.swift",
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
        XCTAssertTrue(try source("Onboarding/OnboardingApp.swift").contains("modelDownloader: StubModelDownloader()"))
    }

    // MARK: - The screens

    func testWelcomeHasNoAppIcon() throws {
        let welcome = try source("Onboarding/Slides/WelcomeSlide.swift")
        XCTAssertFalse(welcome.contains("AppIcon"), "the title names the product")
        XCTAssertFalse(welcome.contains("Image(nsImage:"))
        XCTAssertTrue(welcome.contains("KeycapRow(keycaps: key.keycaps, pressed: pressed)"), "keycaps in the sentence")
        XCTAssertTrue(welcome.contains("for time in key.pulseTimes"))
        XCTAssertTrue(welcome.contains("guard animates, !reduceMotion else { return }"))
    }

    func testOpenItForMeIsALink() throws {
        let tryIt = try source("Onboarding/Slides/TryItSlide.swift")
        XCTAssertTrue(tryIt.contains(
            "Button(OnboardingCopy.openItForMe) { perform(.openItForMe) }\n                .onboardingText("
        ))
        XCTAssertTrue(tryIt.contains("tryIt.willOpenAskForThem()\n            NSWorkspace.shared.open(AppLink.ask)"))
    }

    func testAPanelOpenedFromTryItCoversTheFlowWithoutEndingIt() throws {
        // Replacing the flow would end Try it's reader and start it over.
        let flow = code(try source("Onboarding/OnboardingFlowView.swift")).joined(separator: "\n")
        XCTAssertTrue(flow.contains("ZStack {"))
        XCTAssertTrue(flow.contains(".opacity(panel == nil ? 1 : 0)"))
        XCTAssertTrue(flow.contains(".disabled(panel != nil)"), "its buttons and Return are off underneath")
        XCTAssertFalse(flow.contains("} else {\n                OnboardingWindow"), "the flow stays in the window")
    }

    func testTheOpenAtLoginCheckboxIsShownOnlyBeforeConsent() throws {
        let promise = try source("Onboarding/Slides/PromiseSlide.swift")
        XCTAssertTrue(promise.contains("openAtLogin: flowVM.isReview ? nil : $flowVM.openAtLogin"))
        XCTAssertTrue(promise.contains("Toggle(OnboardingCopy.openAtLogin, isOn: openAtLogin)"))
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
