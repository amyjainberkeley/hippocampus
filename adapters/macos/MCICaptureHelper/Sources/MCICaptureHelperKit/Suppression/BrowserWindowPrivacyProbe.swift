import AppKit
import Foundation

public protocol BrowserWindowPrivacyChecking: Sendable {
    /// True only when the browser says the captured window is private. False
    /// means "not known to be private", and the window is read (RULINGS G8).
    func isPrivate(for context: WorkflowContext, capturedWindow: FocusedWindow?) -> Bool
}

/// Chromium browsers report each window's mode ("normal" or "incognito")
/// through their scripting dictionary. Asking needs Automation, which
/// Hippocampus never requests: the listing runs only when the person already
/// allowed it for that browser (`RealAppleScriptRunner` checks with
/// `askUserIfNeeded: false`). The answer can only add a skip: a window whose
/// bounds match an incognito window is private; anything else, including no
/// answer, leaves the window to the other checks.
public struct BrowserWindowPrivacyProbe: BrowserWindowPrivacyChecking {
    private let runner: any AppleScriptRunner
    private let cache: WindowListCache
    private let now: @Sendable () -> Date

    /// A busy Chrome answers the window listing in about half a second. The
    /// listing is cached briefly, and a window it does not hold is looked up
    /// afresh, so a window opened after the listing is never judged by it.
    static let timeoutMs = 1500
    static let cacheTTL: TimeInterval = 1.0

    public init() {
        self.init(runner: RealAppleScriptRunner())
    }

    internal init(runner: any AppleScriptRunner, now: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.cache = WindowListCache()
        self.now = now
    }

    internal static let scripts: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ].mapValues { app in
        // Each window's mode and bounds, never its address. Inside the tell
        // block `tab` names the browser's tab class, which coerces to the
        // text "tab"; `character id 9` is the separator.
        """
        tell application "\(app)"
            set sep to character id 9
            set rows to ""
            repeat with w in windows
                set b to bounds of w
                set rows to rows & (mode of w as text) & sep & (item 1 of b as text) & sep & (item 2 of b as text) & sep & (item 3 of b as text) & sep & (item 4 of b as text) & linefeed
            end repeat
            return rows
        end tell
        """
    }

    public func isPrivate(for context: WorkflowContext, capturedWindow: FocusedWindow?) -> Bool {
        guard let bundle = context.appBundleId,
              let script = Self.scripts[bundle],
              let capturedWindow, capturedWindow.bundleId == bundle,
              let rect = capturedWindow.axRect, rect.width > 0, rect.height > 0
        else { return false }
        if let cached = cache.listing(for: bundle, at: now(), ttl: Self.cacheTTL),
           let verdict = Self.mode(of: rect, in: cached.rows) {
            return verdict
        }
        guard case .success(let rows) = runner.run(script, target: bundle, timeoutMs: Self.timeoutMs) else {
            return false
        }
        cache.store(rows, for: bundle, at: now())
        return Self.mode(of: rect, in: rows) ?? false
    }

    /// Whether the window with bounds `capturedRect` is private according to
    /// a listing: true when any window with those bounds is not "normal", false
    /// when every one is "normal", nil when the listing holds none or cannot
    /// be read.
    internal static func mode(of capturedRect: CGRect, in listing: String) -> Bool? {
        guard listing.utf8.count <= 65_536 else { return nil }
        var matched = false
        for row in listing.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty,
                  let left = Double(fields[1]), let top = Double(fields[2]),
                  let right = Double(fields[3]), let bottom = Double(fields[4]),
                  [left, top, right, bottom].allSatisfy(\.isFinite),
                  right > left, bottom > top
            else { return nil }
            let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            guard bounds == capturedRect else { continue }
            if fields[0] != "normal" { return true }
            matched = true
        }
        return matched ? false : nil
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
