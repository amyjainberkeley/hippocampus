#if DEBUG
import AppKit
import OnboardingKit
import SwiftUI

/// Debug only: `HIPPOCAMPUS_RENDER_ONBOARDING=<dir>` draws every screen of
/// setup, each permission row state and the tallest pairs of them, each
/// Promise button state, each Try it card, the never-read panel and the
/// browser extension panel, from fixture state, to `<dir>/<name>.png` at
/// 2x, then returns from `main` before setup starts.
///
/// Nothing reaches the screen. `OnboardingEntryPoint.main` calls this
/// first, before the parent watch and `OnboardingApp.main()`, so no scene,
/// window, menu or app delegate exists. The application object is given
/// the `.prohibited` policy (no Dock icon, no menu bar, never active) and
/// is never run. Each state is hosted in an `NSHostingView` that is never
/// put in a window, and drawn into a bitmap allocated at twice the
/// window's size, with solid fills where the materials would be.
///
/// Nothing is read from this Mac: the renderer draws the screens' pure
/// views, never the ones that check permissions, read memory, read the
/// retention file or ask about Apple Intelligence. The key, the clock, the
/// locale and every line of text are fixed below.
@MainActor
enum OnboardingPreviewRenderer {
    static let environmentKey = "HIPPOCAMPUS_RENDER_ONBOARDING"

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

        // Welcome
        add("1-welcome", welcome(.shiftTwice))
        add("1-welcome-right-command", welcome(.rightCommand))
        add("1-welcome-chord", welcome(.chord))

        // Permissions
        let srOn = row(.screenRecording, .granted)
        let axOn = row(.accessibility, .granted)
        add("2-permissions", permissions([row(.screenRecording, .idle), row(.accessibility, .idle)]))
        add("2-permissions-screen-waiting", permissions([
            row(.screenRecording, .waiting), row(.accessibility, .idle, canAllow: false),
        ]))
        add("2-permissions-screen-needs-help", permissions([
            row(.screenRecording, .needsHelp), row(.accessibility, .idle),
        ]))
        add("2-permissions-screen-ask-again", permissions([
            row(.screenRecording, .needsHelp, offersAskAgain: true), row(.accessibility, .idle),
        ]))
        add("2-permissions-accessibility-waiting", permissions([srOn, row(.accessibility, .waiting)]))
        // The tallest pairs: one row turned down, then the other tried.
        add("2-permissions-screen-needs-help-accessibility-waiting", permissions([
            row(.screenRecording, .needsHelp), row(.accessibility, .waiting),
        ]))
        add("2-permissions-screen-waiting-accessibility-needs-help", permissions([
            row(.screenRecording, .waiting), row(.accessibility, .needsHelp),
        ]))
        add("2-permissions-both-need-help", permissions([
            row(.screenRecording, .needsHelp, offersAskAgain: true), row(.accessibility, .needsHelp, offersAskAgain: true),
        ]))
        add("2-permissions-both-on", permissions([srOn, axOn]))
        add("2-permissions-review", permissions([srOn, axOn], review: true))
        add("2-permissions-macos-14", permissions([
            row(.screenRecording, .idle, macOS: 14), row(.accessibility, .idle),
        ]))
        add("2-permissions-chord", permissions([
            row(.screenRecording, .idle), row(.accessibility, .idle, key: .chord),
        ]))

        // Promise
        add("3-promise", promise(keyState: .ready))
        add("3-promise-setting-up", promise(keyState: .generating))
        add("3-promise-key-failed", promise(keyState: .failed("")))
        add("3-promise-review", promise(keyState: .ready, review: true))

        // Try it
        let notes = proof()
        add("4-try-it-turning-on", tryIt(.starting))
        // A browser in front is read like any window: the ordinary card.
        add("4-try-it-waiting", tryIt(.waiting(FrontAppNote(bundleId: "com.apple.Safari", name: "Safari"))))
        add("4-try-it-waiting-system-settings", tryIt(.waiting(.neverRead(app: "System Settings"))))
        add("4-try-it-stalled", tryIt(.stalled(.unknown)))
        add("4-try-it-stalled-permission", tryIt(.stalled(.permissionOff(.screenRecording))))
        add("4-try-it-proof", tryIt(.proof(notes), understanding: .available))
        // No Apple Intelligence and no model on this Mac, before and on macOS 26.
        add("4-try-it-proof-no-model", tryIt(.proof(notes), understanding: .noModel, macOS: 15))
        add("4-try-it-proof-no-model-macos-26", tryIt(.proof(notes), understanding: .noModel, macOS: 26))
        add("4-try-it-proof-preparing", tryIt(.proof(notes), understanding: .preparing))
        // Set to use Apple Intelligence alone.
        add("4-try-it-proof-no-answers", tryIt(.proof(notes), understanding: .turnedOff))
        add("4-try-it-proof-unsupported", tryIt(.proof(notes), understanding: .unsupported))
        add("4-try-it-proof-no-key", tryIt(.proof(notes), keyNow: nothingOpensAsk, understanding: .available))
        add("4-try-it-proof-title-only", tryIt(.proof(proof(lines: false)), understanding: .available))
        add("4-try-it-finished", tryIt(.finished(openedForThem: false)))
        add("4-try-it-finished-for-them", tryIt(.finished(openedForThem: true)))
        add("4-try-it-paused", tryIt(.notRemembering(.paused)))
        add("4-try-it-off", tryIt(.notRemembering(.off)))

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

    private static func welcome(_ key: AskKeyHint) -> some View {
        OnboardingWindow {
            WelcomeSlide(key: key, animates: false)
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

    /// A note read twelve seconds ago, as `ReadProof.choose` makes it from
    /// a stored row. Synthetic text, no real moment.
    private static func proof(lines: Bool = true) -> ReadProof {
        let text = lines
            ? "Launch plan\nBeta ships to forty design partners on October 21.\nOpen question: what does the Team plan cost?\nKeep the pricing page short and plain.\nEdit"
            : "Launch plan\nEdit\nShare"
        let row = ReadRow(
            tsUs: UInt64((now.timeIntervalSince1970 - 12) * 1_000_000),
            appBundleId: "com.apple.Notes",
            windowTitle: "Launch plan",
            text: text,
            sourceKind: "screen_ocr"
        )
        // swiftlint:disable:next force_unwrapping
        return ReadProof.choose(from: [row], lastActivatedApp: "com.apple.Notes", nameFor: { _ in "Notes" })!
    }

    // MARK: - Drawing

    private static func render(_ view: AnyView) -> Data? {
        let root = view
            .environment(\.colorScheme, .light)
            .environment(\.locale, locale)
            .environment(\.onboardingSolidFills, true)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = NSSize(width: OnboardingTheme.windowWidth, height: OnboardingTheme.windowHeight)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
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
