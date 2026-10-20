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

/// The addresses open in Safari's and the Chrome family's tabs, through
/// AppleScript, only while that browser is running and only as far as macOS
/// allows (SPEC-DELTA 3). It asks for Automation only when told it may (the
/// first Resume that opens tabs in that browser); otherwise a browser
/// Hippocampus may not ask answers nil and its tabs open again. Addresses
/// are compared and dropped; nothing is kept.
public actor AppleScriptOpenTabs: OpenTabsReading {
    public static let shared = AppleScriptOpenTabs()

    /// Browsers whose tabs AppleScript can list.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
    ]

    public init() {}

    public func openTabs(browser: String, mayAsk: Bool) async -> [String]? {
        guard Self.browsers.contains(browser) else { return nil }
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
            Self.tabAddresses(browser)
        }.value
    }

    /// Whether this app may send `browser` Apple Events, asking the person
    /// only when `ask`.
    nonisolated static func mayAutomate(_ browser: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser)
        guard var address = target.aeDesc?.pointee else { return false }
        let status = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, ask)
        return status == noErr
    }

    /// Every tab's address in every window, or nil when the script fails.
    nonisolated static func tabAddresses(_ browser: String) -> [String]? {
        let source = "tell application id \"\(browser)\" to get URL of every tab of every window"
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
