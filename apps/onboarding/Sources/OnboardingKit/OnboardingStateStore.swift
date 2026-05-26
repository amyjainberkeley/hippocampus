// SPDX-License-Identifier: TBD-private
//
// OnboardingStateStore — persist the user's current onboarding slide
// so that quitting the Onboarding window mid-flow and reopening it
// resumes at the same slide instead of starting over.
//
// CEO dogfood 2026-05-26: "when I quit and reopen the onboarding
// doesn't open again unless I touch the icon. Then when I touch it
// it starts from scratch not where we left off."
//
// The auto-spawn half landed in PR #200 (launch logic moved to
// `AppDelegate.applicationDidFinishLaunching`). This file is the
// "where we left off" half.
//
// Storage layout: `~/Library/Application Support/MCI/.onboarding-state`
// — a one-line text file holding the OnboardingStep raw value. Lives
// next to the existing `.onboarding-complete` sentinel so the wipe
// procedure (rm -rf the MCI dir) clears it for free.

import Foundation

public protocol OnboardingStateStore: Sendable {
    /// Best-effort: returns the persisted step. `nil` on fresh
    /// installs or any read/parse failure (we fall back to .welcome
    /// in the caller — there is no error surface worth showing).
    func load() -> OnboardingStep?

    /// Persist `step`. Silently swallows write errors — a stale state
    /// file is a worse failure mode than no state file, but neither
    /// is worth surfacing to the user during the flow itself.
    func save(_ step: OnboardingStep)

    /// Clear any persisted state. Called when onboarding completes
    /// (the sentinel is the source of truth for "done"; the resume
    /// file is just a hint and should not outlive a successful flow).
    func clear()
}

public struct FileOnboardingStateStore: OnboardingStateStore {
    private let path: URL

    public static let defaultURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MCI/.onboarding-state")

    public init(path: URL = FileOnboardingStateStore.defaultURL) {
        self.path = path
    }

    public func load() -> OnboardingStep? {
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed),
              let step = OnboardingStep(rawValue: value) else {
            return nil
        }
        return step
    }

    public func save(_ step: OnboardingStep) {
        // Ensure parent dir exists — on first launch the MCI dir may
        // not have been created by anyone else yet.
        let parent = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        let payload = "\(step.rawValue)\n"
        try? payload.write(to: path, atomically: true, encoding: .utf8)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: path)
    }
}

public struct InMemoryOnboardingStateStore: OnboardingStateStore {
    private final class Box: @unchecked Sendable {
        var value: OnboardingStep?
    }
    private let box = Box()

    public init(initial: OnboardingStep? = nil) {
        box.value = initial
    }

    public func load() -> OnboardingStep? { box.value }
    public func save(_ step: OnboardingStep) { box.value = step }
    public func clear() { box.value = nil }
}
