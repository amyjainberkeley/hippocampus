#if DEBUG
import AppKit
import OnboardingKit
import SwiftUI

/// Debug only: `HIPPOCAMPUS_RENDER_ONBOARDING=<dir>` draws every screen of
/// setup, Welcome's demo at each of its moments and on the way through them,
/// each permission row state and the tallest pairs of them, each Promise
/// button state, each Try it state, the never-read panel and the browser
/// extension panel, from fixture state, to `<dir>/<name>.png` at 2x, then
/// returns from `main` before setup starts.
///
/// Nothing reaches the screen. `OnboardingEntryPoint.main` calls this
/// first, before the parent watch and `OnboardingApp.main()`, so no scene,
/// window, menu or app delegate exists. The application object is given
/// the `.prohibited` policy (no Dock icon, no menu bar, never active) and
/// is never run. Each state is hosted in an `NSHostingView` that is never
/// put in a window, and drawn into a bitmap allocated at twice the
/// window's size, with solid fills where the materials would be.
///
/// With `HIPPOCAMPUS_RENDER_DEMO_STEP=<seconds>` as well, it also draws
/// Welcome once every that many seconds through one loop of the demo, at 1x,
/// to `<dir>/demo/<milliseconds>.png`, so the demo's pace can be seen frame
/// by frame. The frames are the script's; SwiftUI's fades between them are
/// not drawn.
///
/// Nothing is read from this Mac: the renderer draws the screens' pure
/// views, never the ones that check permissions, read memory, list windows,
/// read the retention file or ask about Apple Intelligence. The key, the
/// clock, the locale, every window and every line of text are fixed below
/// and made up.
@MainActor
enum OnboardingPreviewRenderer {
    static let environmentKey = "HIPPOCAMPUS_RENDER_ONBOARDING"
    static let demoStepKey = "HIPPOCAMPUS_RENDER_DEMO_STEP"

    /// True when it rendered; `main` then returns.
    static func renderIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let dir = environment[environmentKey], !dir.isEmpty else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, view) in states() {
            if let png = render(view) {
                try? png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        if let step = environment[demoStepKey].flatMap(Double.init), step >= 0.02 {
            let frames = out.appendingPathComponent("demo", isDirectory: true)
            try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            for time in stride(from: 0, to: WelcomeDemoScript.cycle, by: step) {
                let frame = WelcomeDemoScript.frame(at: time)
                if let png = render(AnyView(welcome(.shiftTwice, frame)), scale: 1) {
                    let name = String(format: "%05d.png", Int((time * 1000).rounded()))
                    try? png.write(to: frames.appendingPathComponent(name))
                }
            }
        }
        return true
    }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_791_234_567)
    private static let locale = Locale(identifier: "en_US")
    private static let kept = OnboardingCopy.kept(policy: .ninetyDays, customDays: nil, needsReview: false)
    private static let shiftTwiceNow = AskKeyNow(
        effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: nil
    )
    private static let nothingOpensAsk = AskKeyNow(effectiveLabel: "", effectivePhrase: "", stored: nil)

    private static func states() -> [(String, AnyView)] {
        var states: [(String, AnyView)] = []
        func add<V: View>(_ name: String, _ view: V) { states.append((name, AnyView(view))) }

        // Welcome: each moment whole, and on the way through it.
        add("1-welcome", welcome(.shiftTwice, WelcomeDemoScript.finalFrame(.ask)))
        add("1-welcome-ask-writing", welcome(.shiftTwice, WelcomeDemoScript.frame(.ask, at: 0.4)))
        add("1-welcome-ask-key-down", welcome(.shiftTwice, WelcomeDemoScript.frame(.ask, at: 0.75)))
        add("1-welcome-ask-typing", welcome(.shiftTwice, WelcomeDemoScript.frame(.ask, at: 2)))
        add("1-welcome-overview-filling", welcome(.shiftTwice, WelcomeDemoScript.frame(.overview, at: 0.9)))
        add("1-welcome-overview", welcome(.shiftTwice, WelcomeDemoScript.finalFrame(.overview)))
        add("1-welcome-ai-starting", welcome(.shiftTwice, WelcomeDemoScript.frame(.ai, at: 1.9)))
        add("1-welcome-ai", welcome(.shiftTwice, WelcomeDemoScript.finalFrame(.ai)))
        add("1-welcome-right-command", welcome(.rightCommand, WelcomeDemoScript.finalFrame(.ask)))
        add("1-welcome-chord", welcome(.chord, WelcomeDemoScript.finalFrame(.ask)))

        // What you get
        add("2-what-you-get", OnboardingWindow {
            WhatYouGetSlide()
        } bar: {
            BottomBar(screen: .whatYouGet, back: {}, primaryLabel: OnboardingCopy.continueLabel, primary: {})
        })

        // Permissions
        let srOn = row(.screenRecording, .granted)
        let axOn = row(.accessibility, .granted)
        add("3-permissions", permissions([row(.screenRecording, .idle), row(.accessibility, .idle)]))
        add("3-permissions-screen-on", permissions([srOn, row(.accessibility, .idle)]))
        add("3-permissions-screen-waiting", permissions([
            row(.screenRecording, .waiting), row(.accessibility, .idle, canAllow: false),
        ]))
        add("3-permissions-screen-needs-help", permissions([
            row(.screenRecording, .needsHelp), row(.accessibility, .idle),
        ]))
        add("3-permissions-screen-ask-again", permissions([
            row(.screenRecording, .needsHelp, offersAskAgain: true), row(.accessibility, .idle),
        ]))
        add("3-permissions-accessibility-waiting", permissions([srOn, row(.accessibility, .waiting)]))
        // The tallest pairs: one row turned down, then the other tried.
        add("3-permissions-screen-needs-help-accessibility-waiting", permissions([
            row(.screenRecording, .needsHelp), row(.accessibility, .waiting),
        ]))
        add("3-permissions-screen-waiting-accessibility-needs-help", permissions([
            row(.screenRecording, .waiting), row(.accessibility, .needsHelp),
        ]))
        add("3-permissions-both-need-help", permissions([
            row(.screenRecording, .needsHelp, offersAskAgain: true), row(.accessibility, .needsHelp, offersAskAgain: true),
        ]))
        add("3-permissions-both-on", permissions([srOn, axOn]))
        add("3-permissions-review", permissions([srOn, axOn], review: true))
        add("3-permissions-macos-14", permissions([
            row(.screenRecording, .idle, macOS: 14), row(.accessibility, .idle),
        ]))
        add("3-permissions-chord", permissions([
            row(.screenRecording, .idle), row(.accessibility, .idle, key: .chord),
        ]))

        // Promise: privacy at a glance, then consent
        add("4-promise", promise(keyState: .ready))
        add("4-promise-setting-up", promise(keyState: .generating))
        add("4-promise-key-failed", promise(keyState: .failed("")))
        add("4-promise-review", promise(keyState: .ready, review: true))

        // Try it: the window in front, read or skipped.
        let pricing = FrontWindow(bundleId: "com.apple.Safari", appName: "Safari", title: "Pricing | Stripe")
        let finder = FrontWindow(bundleId: "com.apple.finder", appName: "Finder", title: "Applications")
        // Apps every Mac has, or that this one does, so their own icons show.
        let passwords = FrontWindow(bundleId: "com.apple.Passwords", appName: "Passwords", title: "All")
        let incognito = FrontWindow(bundleId: "com.google.Chrome", appName: "Google Chrome", title: "New Incognito Tab")
        let messages = FrontWindow(bundleId: "com.apple.MobileSMS", appName: "Messages", title: nil)
        let read = proof()
        add("5-try-it-turning-on", tryIt(.starting))
        add("5-try-it-reading", tryIt(.reading(pricing)))
        add("5-try-it-proof", tryIt(.proof(read), understanding: .available))
        add("5-try-it-proof-long-name", tryIt(.proof(longProof()), understanding: .noModel, macOS: 26))
        add("5-try-it-skipped-password-app", tryIt(.skipped(.neverRead, passwords)))
        add("5-try-it-skipped-private", tryIt(.skipped(.privateWindow, incognito)))
        add("5-try-it-skipped-excluded", tryIt(.skipped(.excluded, messages)))
        add("5-try-it-skipped-password-field", tryIt(.skipped(.passwordField, pricing)))
        add("5-try-it-nothing-to-show", tryIt(.nothingToShow(finder)))
        add("5-try-it-no-window", tryIt(.noWindow))
        add("5-try-it-stalled", tryIt(.stalled(.unknown)))
        add("5-try-it-stalled-permission", tryIt(.stalled(.permissionOff(.screenRecording))))
        // No Apple Intelligence and no model on this Mac, before and on macOS 26.
        add("5-try-it-proof-no-model", tryIt(.proof(read), understanding: .noModel, macOS: 15))
        add("5-try-it-proof-no-model-macos-26", tryIt(.proof(read), understanding: .noModel, macOS: 26))
        add("5-try-it-proof-preparing", tryIt(.proof(read), understanding: .preparing))
        // Set to use Apple Intelligence alone.
        add("5-try-it-proof-no-answers", tryIt(.proof(read), understanding: .turnedOff))
        add("5-try-it-proof-unsupported", tryIt(.proof(read), understanding: .unsupported))
        add("5-try-it-proof-no-key", tryIt(.proof(read), keyNow: nothingOpensAsk, understanding: .available))
        add("5-try-it-finished", tryIt(.finished(openedForThem: false)))
        add("5-try-it-finished-for-them", tryIt(.finished(openedForThem: true)))
        add("5-try-it-paused", tryIt(.notRemembering(.paused)))
        add("5-try-it-off", tryIt(.notRemembering(.off)))

        // The panel Preferences opens for what is never read.
        add("panel-never-read", OnboardingPanelView(panel: .neverRead, keptForPreview: kept) {})

        // The browser extension panel, which Preferences opens.
        let safari = DetectedBrowser(id: "com.apple.Safari", name: "Safari", kind: .safari)
        let chrome = DetectedBrowser(id: "com.google.Chrome", name: "Chrome", kind: .chromium)
        let arc = DetectedBrowser(id: "company.thebrowser.Browser", name: "Arc", kind: .chromium)
        let folder = "/Applications/Hippocampus.app/Contents/Resources/Extensions/Chromium"
        func steps(_ browser: DetectedBrowser, path: String?, opened: Bool) -> BrowserExtensionViewModel.BrowserRow {
            BrowserExtensionViewModel.BrowserRow(
                browser: browser, extensionStatus: .notInstalled,
                installInstructions: .init(unpackedDirPath: path, didOpenBrowser: opened, browserName: browser.name)
            )
        }
        add("panel-browser-extension", browserExtension([
            .init(browser: safari, extensionStatus: .notInstalled), .init(browser: chrome),
            .init(browser: arc, extensionStatus: .notInstalled),
        ]))
        add("panel-browser-extension-steps", browserExtension(
            [.init(browser: safari, extensionStatus: .notInstalled), steps(chrome, path: folder, opened: true)],
            askedAboutAutomation: true
        ))
        add("panel-browser-extension-open-it-yourself", browserExtension(
            [steps(chrome, path: folder, opened: false)]
        ))
        add("panel-browser-extension-folder-missing", browserExtension(
            [steps(chrome, path: nil, opened: true)]
        ))
        add("panel-browser-extension-automation-off", browserExtension(
            [.init(browser: safari, extensionStatus: .notInstalled)], automation: .denied, askedAboutAutomation: true
        ))
        add("panel-browser-extension-on", browserExtension(
            [.init(browser: safari, extensionStatus: .installed), .init(browser: chrome, extensionStatus: .installed)],
            automation: .granted
        ))
        add("panel-browser-extension-none", browserExtension([]))
        return states
    }

    private static func browserExtension(
        _ rows: [BrowserExtensionViewModel.BrowserRow],
        automation: TCCStatus = .notRequested,
        askedAboutAutomation: Bool = false
    ) -> some View {
        OnboardingWindow {
            BrowserExtensionScreen(
                rows: rows, automation: automation, didAttemptSafariAutomation: askedAboutAutomation, perform: { _ in }
            )
        } bar: {
            BottomBar(primaryLabel: OnboardingCopy.done, primary: {})
        }
    }

    private static func welcome(_ key: AskKeyHint, _ frame: DemoFrame) -> some View {
        OnboardingWindow {
            WelcomeSlide(key: key, animates: false, demoFrame: frame)
        } bar: {
            BottomBar(screen: .welcome, primaryLabel: OnboardingCopy.getStarted, primary: {})
        }
    }

    private static func row(
        _ surface: PermissionSurface,
        _ state: PermissionRowState,
        canAllow: Bool = true,
        offersAskAgain: Bool = false,
        key: AskKeyHint = .shiftTwice,
        macOS: Int = 26
    ) -> PermissionRowModel {
        PermissionRowModel(
            surface: surface, key: key, state: state, canAllow: canAllow && state == .idle,
            offersAskAgain: offersAskAgain, macOSMajorVersion: macOS
        )
    }

    private static func permissions(_ rows: [PermissionRowModel], review: Bool = false) -> some View {
        OnboardingWindow {
            PermissionsScreen(
                intro: OnboardingCopy.permissionsBody(isReview: review), rows: rows, perform: { _, _ in }
            )
        } bar: {
            BottomBar(
                screen: .permissions, back: {}, primaryLabel: OnboardingCopy.continueLabel,
                primaryEnabled: rows.allSatisfy { $0.state == .granted }, primary: {}
            )
        }
    }

    private static func promise(keyState: PrepareBrainViewModel.KeyState, review: Bool = false) -> some View {
        OnboardingWindow {
            PromiseScreen(
                title: OnboardingCopy.promiseTitle(isReview: review),
                intro: OnboardingCopy.promiseBody(isReview: review),
                kept: kept,
                openAtLogin: review ? nil : .constant(true),
                keyFailed: !review && keyState != .ready && keyState != .generating
            )
        } bar: {
            BottomBar(
                screen: .promise, back: {},
                primaryLabel: OnboardingCopy.promisePrimary(isReview: review, keyState: keyState),
                primaryEnabled: review || keyState == .ready, primary: {}
            )
        }
    }

    private static func tryIt(
        _ card: TryItViewModel.Card,
        keyNow: AskKeyNow = shiftTwiceNow,
        understanding: UnderstandingAvailability? = nil,
        macOS: Int = 26
    ) -> some View {
        OnboardingWindow {
            TryItScreen(
                presentation: TryItPresentation(
                    card: card, keyNow: keyNow, understanding: understanding, macOSMajorVersion: macOS
                ),
                now: now,
                locale: locale,
                perform: { _ in }
            )
        } bar: {
            BottomBar(screen: .tryIt, primaryLabel: OnboardingCopy.done, primary: {})
        }
    }

    /// A pricing page read twelve seconds ago, as `ReadProof.choose` makes
    /// it from a stored row. Synthetic text, no real moment.
    private static func proof() -> ReadProof {
        proof(
            app: "com.apple.Safari", name: "Safari", title: "Pricing | Stripe",
            text: "Pricing | Stripe\nStart with per-seat pricing for each user on your team.\nVolume pricing charges the same price for every unit.\nTiered pricing lowers the price as more seats are added.\nContact sales"
        )
    }

    /// The longest a proof gets: a long app name in the title, a long
    /// window title on the card, and a line shortened to fit. Made up.
    private static func longProof() -> ReadProof {
        proof(
            app: "com.microsoft.Powerpoint", name: "Microsoft PowerPoint",
            title: "Team and Business pricing for next year, final review before the board meeting",
            text: "Team moves to eighteen dollars a seat, billed once a year, for every new customer from January onward.\nBusiness keeps volume pricing for teams over fifty seats.\nAsk finance to confirm the discount before Friday."
        )
    }

    private static func proof(app: String, name: String, title: String, text: String) -> ReadProof {
        let row = ReadRow(
            tsUs: UInt64((now.timeIntervalSince1970 - 12) * 1_000_000),
            appBundleId: app,
            windowTitle: title,
            text: text,
            sourceKind: "screen_context"
        )
        // swiftlint:disable:next force_unwrapping
        return ReadProof.choose(from: [row], lastActivatedApp: app, nameFor: { _ in name })!
    }

    // MARK: - Drawing

    private static func render(_ view: AnyView, scale: CGFloat = 2) -> Data? {
        let root = view
            .environment(\.colorScheme, .light)
            .environment(\.locale, locale)
            .environment(\.onboardingSolidFills, true)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = NSSize(width: OnboardingTheme.windowWidth, height: OnboardingTheme.windowHeight)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
