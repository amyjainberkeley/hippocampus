import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class BrowserExtensionViewModel: ObservableObject {
    public struct BrowserRow: Identifiable, Sendable, Equatable {
        public let browser: DetectedBrowser
        public var extensionStatus: ExtensionStatus
        /// Set to a non-nil value the first time the user clicks
        /// "Install" for this browser. Drives the slide's inline
        /// 3-step instructions box.
        public var installInstructions: ChromiumInstallInstructions?

        public var id: String { browser.id }

        public init(
            browser: DetectedBrowser,
            extensionStatus: ExtensionStatus = .unknown,
            installInstructions: ChromiumInstallInstructions? = nil
        ) {
            self.browser = browser
            self.extensionStatus = extensionStatus
            self.installInstructions = installInstructions
        }
    }

    /// Slide-side state surfaced under a Chromium row after the user
    /// clicks "Install". The slide reads this to render a 3-step
    /// instructions box ("Toggle Developer mode → Load Unpacked →
    /// select this folder") + a Reveal-in-Finder + Copy-path button.
    public struct ChromiumInstallInstructions: Sendable, Equatable {
        /// Path on disk of the bundled unpacked extension dir. `nil`
        /// when the bundled dir wasn't found (dev build that didn't
        /// run `build-app.sh`).
        public let unpackedDirPath: String?
        /// True iff `open -a <browser> chrome://extensions` exited 0.
        public let didOpenBrowser: Bool
        /// Browser display name for copy.
        public let browserName: String
    }

    @Published public private(set) var rows: [BrowserRow]

    private let detector: any BrowserDetector
    private let extensionLocator: ChromiumExtensionLocator
    private let browserLauncher: BrowserLauncher

    public init(
        detector: any BrowserDetector,
        extensionLocator: ChromiumExtensionLocator = DefaultChromiumExtensionLocator(),
        browserLauncher: BrowserLauncher = DefaultBrowserLauncher()
    ) {
        self.detector = detector
        self.extensionLocator = extensionLocator
        self.browserLauncher = browserLauncher
        self.rows = detector.installedBrowsers().map {
            BrowserRow(browser: $0)
        }
    }

    public var hasBrowsers: Bool { !rows.isEmpty }

    public func checkExtension(for browserId: String) {
        guard let idx = rows.firstIndex(where: { $0.id == browserId }) else { return }
        let status = detector.checkExtensionInstalled(for: rows[idx].browser)
        rows[idx].extensionStatus = status
    }

    public func installAction(for browser: DetectedBrowser) {
        switch browser.kind {
        case .chromium:
            installChromiumExtension(for: browser)
        case .safari:
            #if canImport(AppKit)
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.Safari-Extensions-Preferences"
            ) {
                NSWorkspace.shared.open(url)
            }
            #endif
        }
    }

    /// The Chromium install flow:
    ///
    ///   1. Spawn the right browser at chrome://extensions via
    ///      `/usr/bin/open -a <browser> chrome://extensions`. The
    ///      bare `NSWorkspace.open(URL("chrome://..."))` call does
    ///      NOT work because no app is registered for the chrome
    ///      scheme on macOS — but invoking the browser with the URL
    ///      as a launch arg makes the browser itself interpret it.
    ///
    ///   2. Reveal the bundled unpacked extension dir in Finder so
    ///      the user can drag-drop onto chrome://extensions.
    ///
    ///   3. Set `installInstructions` on the row so the slide
    ///      renders a "Toggle Developer mode → Load Unpacked …"
    ///      inline box.
    private func installChromiumExtension(for browser: DetectedBrowser) {
        let unpackedDir = extensionLocator.bundledChromiumExtensionURL()
        let didOpen = browserLauncher.openInBrowser(
            browserName: browser.name,
            url: "chrome://extensions"
        )
        if let dir = unpackedDir {
            browserLauncher.revealInFinder(dir)
        }
        guard let idx = rows.firstIndex(where: { $0.id == browser.id }) else { return }
        rows[idx].installInstructions = ChromiumInstallInstructions(
            unpackedDirPath: unpackedDir?.path,
            didOpenBrowser: didOpen,
            browserName: browser.name
        )
    }
}

// MARK: - Chromium extension locator (testable seam)

public protocol ChromiumExtensionLocator: Sendable {
    func bundledChromiumExtensionURL() -> URL?
}

public struct DefaultChromiumExtensionLocator: ChromiumExtensionLocator {
    public init() {}

    /// Walk the standard locations the unpacked extension can live
    /// at:
    ///
    ///   - Inside a shipped .app: `<exec dir>/../Resources/
    ///     Extensions/Chromium` (the `build-app.sh` layout).
    ///
    ///   - Under `swift run` in dev: walk up from
    ///     `.build/<profile>/onboarding` to the repo root and hit
    ///     `extensions/chromium/`.
    public func bundledChromiumExtensionURL() -> URL? {
        let argv0 = ProcessInfo.processInfo.arguments.first ?? ""
        let execDir = URL(fileURLWithPath: argv0).deletingLastPathComponent()

        let shipped = execDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Extensions/Chromium")
        if FileManager.default.fileExists(atPath: shipped.path) {
            return shipped
        }

        let devRoot = execDir
            .deletingLastPathComponent()  // .build/<profile>
            .deletingLastPathComponent()  // .build
            .deletingLastPathComponent()  // apps/onboarding
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
        let dev = devRoot.appendingPathComponent("extensions/chromium")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }

        return nil
    }
}

// MARK: - Browser launcher (testable seam)

public protocol BrowserLauncher: Sendable {
    func openInBrowser(browserName: String, url: String) -> Bool
    func revealInFinder(_ url: URL)
}

public struct DefaultBrowserLauncher: BrowserLauncher {
    public init() {}

    public func openInBrowser(browserName: String, url: String) -> Bool {
        #if canImport(AppKit)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", browserName, url]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    public func revealInFinder(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
