// SPDX-License-Identifier: Apache-2.0
//
// OnboardingStateStore — persist the user's current onboarding slide
// so that quitting the Onboarding window mid-flow and reopening it
// resumes at the same slide instead of starting over.
//
// Owner dogfood 2026-05-26: "when I quit and reopen the onboarding
// doesn't open again unless I touch the icon. Then when I touch it
// it starts from scratch not where we left off."
//
// The auto-spawn half landed in PR #200 (launch logic moved to
// `AppDelegate.applicationDidFinishLaunching`). This file is the
// "where we left off" half.
//
// Storage layout: `~/Library/Application Support/MCI/.onboarding-state`
// — a one-line text file holding a route name ("permissions"). Lives
// next to the existing `.onboarding-complete` sentinel so the wipe
// procedure (rm -rf the MCI dir) clears it for free.
//
// The file used to hold the step's number. Numbers named different
// screens in the old thirteen-step flow (an old "3" was Permissions, and
// would resume at Try it), so a file holding only digits loads as nothing
// and the flow starts where a fresh one would. So does the route of a
// step that is gone ("retention").

import Foundation

public protocol OnboardingStateStore: Sendable {
    /// Best-effort: the saved route name. `nil` on fresh installs, on any
    /// read failure and for the old numeric format (we fall back to the
    /// first screen in the caller — there is no error surface worth showing).
    func loadRoute() -> String?

    /// Persist a route name. Silently swallows write errors — a stale state
    /// file is a worse failure mode than no state file, but neither
    /// is worth surfacing to the user during the flow itself.
    func saveRoute(_ route: String)

    /// Clear any persisted state. Called when onboarding completes
    /// (the sentinel is the source of truth for "done"; the resume
    /// file is just a hint and should not outlive a successful flow).
    func clear()

    /// The permissions setup asked macOS for and was waiting on, so that
    /// after Quit & Reopen the row that came on can show its checkmark
    /// appearing once (SPEC 7.7). Empty when none, and on any read failure.
    func loadAsked() -> Set<PermissionSurface>

    /// Keep the permissions setup is waiting on. Errors are swallowed, as
    /// for the route: the checkmark is a nicety.
    func saveAsked(_ surfaces: Set<PermissionSurface>)
}

extension OnboardingStateStore {
    /// The saved screen, or nil when the file names none.
    public func loadScreen() -> OnboardingScreen? {
        loadRoute().flatMap(OnboardingScreen.init(launchRoute:))
    }

    public func save(_ screen: OnboardingScreen) {
        saveRoute(screen.routeName)
    }
}

public struct FileOnboardingStateStore: OnboardingStateStore {
    private let path: URL

    public static let defaultURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MCI/.onboarding-state")

    public init(path: URL = FileOnboardingStateStore.defaultURL) {
        self.path = path
    }

    public func loadRoute() -> String? {
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        return Self.route(fromFile: raw)
    }

    public func saveRoute(_ route: String) {
        guard let route = Self.route(fromFile: route) else { return }
        // Ensure parent dir exists — on first launch the MCI dir may
        // not have been created by anyone else yet.
        let parent = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        let payload = "\(route)\n"
        try? PrivateFileWriter.write(Data(payload.utf8), to: path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: askedPath)
    }

    /// Beside the resume file, which keeps its one line: the permissions
    /// asked for, one name a line ("screenRecording").
    var askedPath: URL {
        path.deletingLastPathComponent().appendingPathComponent(".onboarding-asked")
    }

    public func loadAsked() -> Set<PermissionSurface> {
        guard let raw = try? String(contentsOf: askedPath, encoding: .utf8) else { return [] }
        return Set(raw.split(whereSeparator: \.isNewline).compactMap {
            PermissionSurface(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    public func saveAsked(_ surfaces: Set<PermissionSurface>) {
        guard !surfaces.isEmpty else {
            try? FileManager.default.removeItem(at: askedPath)
            return
        }
        try? FileManager.default.createDirectory(
            at: askedPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let lines = PermissionSurface.allCases.filter(surfaces.contains).map(\.rawValue)
        try? PrivateFileWriter.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: askedPath)
    }

    /// A route is lowercase letters and dashes ("try-it"). Anything else,
    /// the old step numbers included, is not a route.
    static func route(fromFile raw: String) -> String? {
        let route = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard route.range(of: "^[a-z][a-z-]{0,63}$", options: .regularExpression) != nil else {
            return nil
        }
        return route
    }
}

public struct InMemoryOnboardingStateStore: OnboardingStateStore {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var route: String?
        var asked: Set<PermissionSurface> = []
    }
    private let box = Box()

    public init(route: String? = nil, asked: Set<PermissionSurface> = []) {
        box.route = route
        box.asked = asked
    }

    public func loadRoute() -> String? { box.lock.withLock { box.route } }
    public func saveRoute(_ route: String) { box.lock.withLock { box.route = route } }
    public func clear() {
        box.lock.withLock {
            box.route = nil
            box.asked = []
        }
    }
    public func loadAsked() -> Set<PermissionSurface> { box.lock.withLock { box.asked } }
    public func saveAsked(_ surfaces: Set<PermissionSurface>) { box.lock.withLock { box.asked = surfaces } }
}
