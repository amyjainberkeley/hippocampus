import Foundation

@MainActor
public final class StubBrowserDetector: BrowserDetector, @unchecked Sendable {
    public var stubbedBrowsers: [DetectedBrowser]
    public var stubbedStatuses: [String: ExtensionStatus] = [:]
    public private(set) var checkCallCount = 0

    public init(browsers: [DetectedBrowser] = []) {
        self.stubbedBrowsers = browsers
    }

    public func installedBrowsers() -> [DetectedBrowser] {
        stubbedBrowsers
    }

    public func checkExtensionInstalled(for browser: DetectedBrowser) -> ExtensionStatus {
        checkCallCount += 1
        return stubbedStatuses[browser.id] ?? .unknown
    }
}
