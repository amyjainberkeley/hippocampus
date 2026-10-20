import AppKit
import CoreServices
import Foundation
import MCICaptureHelperKit

/// Resume's seam to the Mac in the app: `open -a` semantics through
/// NSWorkspace, and nothing else. Tests and renders never reach it.
public struct SystemResumeWorkspace: ResumeWorkspace {
    public init() {}

    public func appURL(bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    public func exists(path: String) -> Bool {
        FileManager.default.fileExists(atPath: folderURL(path: path).path)
    }

    public func folderURL(path: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full: String
        if path == "~" {
            full = home
        } else if path.hasPrefix("~/") {
            full = home + "/" + path.dropFirst(2)
        } else {
            full = path
        }
        return URL(fileURLWithPath: full, isDirectory: true)
    }

    public func open(_ urls: [URL], withApp app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    public func openApp(at app: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}

/// The addresses open in the Chrome family's and Arc's tabs, through
/// AppleScript, only while that browser is running and only as far as macOS
/// allows (SPEC-DELTA 3). It asks for Automation only when told it may (the
/// first Resume that opens tabs in that browser); otherwise a browser
/// Hippocampus may not ask answers nil and its tabs open again. Addresses
/// are compared and dropped; nothing is kept.
///
/// Private windows are never read (SPEC-DELTA 3, PRIVACY.md): each script
/// asks only for the tabs of normal windows. Safari can't tell a script
/// which of its windows are private, so its tabs are never listed and open
/// again.
public actor AppleScriptOpenTabs: OpenTabsReading {
    public static let shared = AppleScriptOpenTabs()

    /// The Chrome family: each window has a `mode`, "normal" or "incognito".
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    /// Arc: each window says whether it is `incognito`.
    static let arc = "company.thebrowser.Browser"

    /// Browsers whose normal windows' tabs AppleScript can list.
    public static var browsers: Set<String> { chromium.union([arc]) }

    public init() {}

    public func openTabs(browser: String, mayAsk: Bool) async -> [String]? {
        guard let source = Self.script(for: browser) else { return nil }
        let running = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: browser).isEmpty
        }
        guard running else { return [] }
        // Asking may wait for the person's answer: never on the main thread.
        let allowed = await Task.detached(priority: .userInitiated) {
            Self.mayAutomate(browser, ask: mayAsk)
        }.value
        guard allowed else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.tabAddresses(source)
        }.value
    }

    /// The script that lists the addresses in `browser`'s normal windows,
    /// or nil when its private windows can't be left out (Safari) or it has
    /// no tabs to list. Built only from the fixed lists above, never from
    /// anything read.
    nonisolated static func script(for browser: String) -> String? {
        let windows: String
        if chromium.contains(browser) {
            windows = "every window whose mode is \"normal\""
        } else if browser == arc {
            windows = "every window whose incognito is false"
        } else {
            return nil
        }
        return "tell application id \"\(browser)\" to get URL of every tab of (\(windows))"
    }

    /// Whether this app may send `browser` Apple Events, asking the person
    /// only when `ask`.
    nonisolated static func mayAutomate(_ browser: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser)
        // The address points into `target`: keep it alive while macOS reads it.
        return withExtendedLifetime(target) {
            guard var address = target.aeDesc?.pointee else { return false }
            return AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, ask) == noErr
        }
    }

    /// The addresses `source` lists, or nil when the script fails.
    nonisolated static func tabAddresses(_ source: String) -> [String]? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        var addresses: [String] = []
        func collect(_ descriptor: NSAppleEventDescriptor) {
            if descriptor.numberOfItems > 0 {
                for index in 1...descriptor.numberOfItems {
                    if let item = descriptor.atIndex(index) { collect(item) }
                }
            } else if let text = descriptor.stringValue {
                addresses.append(text)
            }
        }
        collect(result)
        return addresses
    }
}

public extension ResumeRules {
    /// The rules in the app: the apps and sites Hippocampus never reads,
    /// and the person's own never-read list, read once when the sheet opens.
    static func system(
        userList: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MCI").appendingPathComponent("denylist.toml")
    ) -> ResumeRules {
        let entries = userList
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { try? DenylistTOMLLoader().parse($0) } ?? []
        let denylist = SensitiveCaptureDenylist(entries: entries)
        return ResumeRules(
            isNeverReadApp: { denylist.appIsDenied(bundleId: $0) },
            isNeverReadSite: { denylist.urlIsDenied($0) }
        )
    }
}
