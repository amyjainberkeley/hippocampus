import AppKit
import Foundation

public protocol BrowserWindowPrivacyChecking: Sendable {
    func permitsPixels(for context: WorkflowContext, capturedWindow: FocusedWindow?) -> Bool
}

/// Chromium exposes normal/incognito mode via its public scripting dictionary.
/// Match the captured window uniquely among ALL browser windows, including
/// private windows. Front-window mode alone cannot authorize queued pixels.
public struct BrowserWindowPrivacyProbe: BrowserWindowPrivacyChecking {
    private let runner: any AppleScriptRunner
    private let focusedWindow: @Sendable () -> FocusedWindow?
    private let cache: WindowListCache
    private let now: @Sendable () -> Date

    /// A busy Chrome answers the window listing in about half a second, so
    /// the former 250 ms budget denied every frame. The listing is cached
    /// briefly: a window opened after it was taken is absent from it, so the
    /// cache can only deny, never authorize, a window it has not seen.
    static let timeoutMs = 1500
    static let cacheTTL: TimeInterval = 1.0
    /// A denial from a listing at least this old is retried with a fresh one.
    static let refreshAfter: TimeInterval = 0.25

    public init() {
        self.init(runner: RealAppleScriptRunner(),
                  focusedWindow: { AXFocusedWindowReader().readFocusedWindowIdentity() })
    }

    internal init(
        runner: any AppleScriptRunner,
        focusedWindow: @escaping @Sendable () -> FocusedWindow?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.focusedWindow = focusedWindow
        self.cache = WindowListCache()
        self.now = now
    }

    internal static let scripts: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ].mapValues { app in
        // Inside the tell block `tab` names the browser's tab class, which
        // coerces to the text "tab"; `character id 9` is the separator.
        """
        tell application "\(app)"
            set sep to character id 9
            set rows to ""
            repeat with w in windows
                set b to bounds of w
                set rows to rows & (mode of w as text) & sep & (item 1 of b as text) & sep & (item 2 of b as text) & sep & (item 3 of b as text) & sep & (item 4 of b as text) & sep & (URL of active tab of w) & linefeed
            end repeat
            return rows
        end tell
        """
    }

    public func permitsPixels(for context: WorkflowContext, capturedWindow: FocusedWindow?) -> Bool {
        guard let bundle = context.appBundleId,
              let script = Self.scripts[bundle],
              let expectedURL = context.url, !expectedURL.isEmpty,
              let capturedWindow, capturedWindow.bundleId == bundle,
              let rect = capturedWindow.axRect, rect.width > 0, rect.height > 0,
              focusedWindow() == capturedWindow
        else { return false }
        if let cached = cache.listing(for: bundle, at: now(), ttl: Self.cacheTTL) {
            if Self.isNormalWindow(.success(cached.rows), expectedURL: expectedURL, capturedRect: rect) {
                return focusedWindow() == capturedWindow
            }
            guard now().timeIntervalSince(cached.taken) >= Self.refreshAfter else { return false }
        }
        let result = runner.run(script, timeoutMs: Self.timeoutMs)
        if case .success(let rows) = result { cache.store(rows, for: bundle, at: now()) }
        guard focusedWindow() == capturedWindow else { return false }
        return Self.isNormalWindow(result, expectedURL: expectedURL, capturedRect: rect)
    }

    internal static func isNormalWindow(_ result: AppleScriptOutcome, expectedURL: String, capturedRect: CGRect) -> Bool {
        guard case .success(let value) = result else { return false }
        guard value.utf8.count <= 65_536,
              let components = URLComponents(string: expectedURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              !SensitiveCaptureDenylist(entries: []).urlIsDenied(expectedURL)
        else { return false }
        var matches: [(mode: String, url: String)] = []
        for row in value.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let left = Double(fields[1]), let top = Double(fields[2]),
                  let right = Double(fields[3]), let bottom = Double(fields[4]),
                  [left, top, right, bottom].allSatisfy(\.isFinite),
                  right > left, bottom > top
            else { return false }
            let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            if bounds == capturedRect { matches.append((String(fields[0]), String(fields[5]))) }
        }
        return matches.count == 1 && matches[0].mode == "normal" && matches[0].url == expectedURL
    }
}

/// The last window listing per browser. Shared by copies of the probe.
final class WindowListCache: @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: (rows: String, taken: Date)] = [:]

    func listing(for bundle: String, at now: Date, ttl: TimeInterval) -> (rows: String, taken: Date)? {
        lock.withLock {
            guard let entry = listings[bundle], now.timeIntervalSince(entry.taken) < ttl,
                  now >= entry.taken else { return nil }
            return entry
        }
    }

    func store(_ rows: String, for bundle: String, at now: Date) {
        lock.withLock { listings[bundle] = (rows, now) }
    }
}
