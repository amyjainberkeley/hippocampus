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

    public init() {
        runner = RealAppleScriptRunner()
        focusedWindow = { AXFocusedWindowReader().readFocusedWindowIdentity() }
    }

    internal init(runner: any AppleScriptRunner, focusedWindow: @escaping @Sendable () -> FocusedWindow?) {
        self.runner = runner
        self.focusedWindow = focusedWindow
    }

    internal static let scripts: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ].mapValues { app in
        """
        tell application "\(app)"
            set rows to ""
            repeat with w in windows
                set b to bounds of w
                set rows to rows & (mode of w as text) & tab & (item 1 of b as text) & tab & (item 2 of b as text) & tab & (item 3 of b as text) & tab & (item 4 of b as text) & tab & (URL of active tab of w) & linefeed
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
        let result = runner.run(script, timeoutMs: 250)
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
