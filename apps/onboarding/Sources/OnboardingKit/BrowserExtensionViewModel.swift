import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class BrowserExtensionViewModel: ObservableObject {
    public struct BrowserRow: Identifiable, Sendable, Equatable {
        public let browser: DetectedBrowser
        public var extensionStatus: ExtensionStatus

        public var id: String { browser.id }

        public init(browser: DetectedBrowser, extensionStatus: ExtensionStatus = .unknown) {
            self.browser = browser
            self.extensionStatus = extensionStatus
        }
    }

    @Published public private(set) var rows: [BrowserRow]

    private let detector: any BrowserDetector

    public init(detector: any BrowserDetector) {
        self.detector = detector
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
            guard let url = URL(string: "chrome://extensions") else { return }
            openURL(url)
        case .safari:
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.Safari-Extensions-Preferences"
            ) else { return }
            openURL(url)
        }
    }

    private func openURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
