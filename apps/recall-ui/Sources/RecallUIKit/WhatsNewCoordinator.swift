// WhatsNewCoordinator.swift — decides *when* to show the "What's new"
// modal after a Sparkle auto-update, and remembers the version the
// user last dismissed so we never re-show it.
//
// # Contract
//
//   - On app boot, `shouldShow(currentVersion:)` compares the current
//     `CFBundleShortVersionString` with `lastShownVersion` in
//     UserDefaults. If they differ, we show. With the key unset this is
//     the first launch: nothing is new to the person yet, and a modal of
//     release notes would cover their first window, so the boot records
//     the version quietly and the next update shows what changed (Oct 18).
//   - `markShown(version:)` writes the current version back. Called
//     by the modal when the user closes it — NOT when the modal is
//     merely presented, so a startup crash mid-modal-render doesn't
//     silently swallow the note.
//   - `showOnDemand()` bypasses the check — used by the ⌘⇧N shortcut
//     and the About-window "See changelog" button.
//
// # UserDefaults key
//
// `MCILastShownWhatsNewVersion` — string, e.g. `"1.0.0"`. Persisted in
// UserDefaults.standard (not the brain — non-sensitive, per mission
// constraints). Suite is default because the recall-ui and the
// menu-bar Hippocampus.app share the same suite via the `ai.hippocampus`
// bundle prefix.

import Foundation
import SwiftUI

@MainActor
public final class WhatsNewCoordinator: ObservableObject {
    public static let lastShownKey = "MCILastShownWhatsNewVersion"

    /// True when the modal should be presented right now.
    @Published public var isVisible: Bool = false

    /// The release currently loaded into the modal. `nil` while the
    /// modal is closed OR when the current build isn't in the shipped
    /// CHANGELOG (dev build) — the modal renders a distinct empty
    /// state in the latter case.
    @Published public var currentRelease: ChangelogRelease?

    /// Whether we resolved a release. Distinct from `currentRelease
    /// != nil` because a dev-build path presents the modal with a
    /// specific "no notes available" message rather than silently
    /// no-op-ing.
    @Published public var isDevBuild: Bool = false

    private let defaults: UserDefaults
    private let bundle: Bundle
    /// The version the modal was presented for, recorded when it closes.
    private var presentedVersion: String?

    public init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.bundle = bundle
    }

    // MARK: - Decision logic (pure, headless-testable)

    /// True when the caller should show the modal for `currentVersion`: only
    /// after an update, when another version was seen before. Split from
    /// side-effects so tests can pin the decision without touching
    /// UserDefaults directly.
    public func shouldShow(currentVersion: String) -> Bool {
        guard !currentVersion.isEmpty, let last = defaults.string(forKey: Self.lastShownKey) else { return false }
        return last != currentVersion
    }

    /// Record that the modal was shown + dismissed for `version`. The
    /// next boot on the same version is silent.
    public func markShown(version: String) {
        defaults.set(version, forKey: Self.lastShownKey)
    }

    // MARK: - Trigger paths

    /// Boot-time trigger. If the current version has notes and hasn't
    /// been seen, presents the modal. Called once from the recall-ui
    /// `.task` closure. Safe to call multiple times — idempotent while
    /// `isVisible` is already true.
    public func maybeShowOnBoot() {
        maybeShow(onBootOf: currentBundleVersion())
    }

    /// The boot decision for `version`. The first launch records it and
    /// shows nothing, so the first window is never covered; a later launch
    /// of another version shows what changed, once.
    public func maybeShow(onBootOf version: String) {
        guard !isVisible, !version.isEmpty else { return }
        guard defaults.string(forKey: Self.lastShownKey) != nil else {
            markShown(version: version)
            return
        }
        guard shouldShow(currentVersion: version) else { return }
        present(forVersion: version)
    }

    /// On-demand trigger — ⌘⇧N and About-window "See changelog".
    /// Always presents, regardless of last-shown state.
    public func showOnDemand() {
        present(forVersion: currentBundleVersion())
    }

    /// Dismissal handler. Marks the current release version as shown
    /// (so it doesn't reappear on the next boot) and hides the modal.
    public func dismiss() {
        if let release = currentRelease {
            markShown(version: release.version)
        } else {
            // Dev build path — still record the bundle version so we
            // don't nag on every launch just because the bundled
            // CHANGELOG lags a step.
            markShown(version: presentedVersion ?? currentBundleVersion())
        }
        presentedVersion = nil
        isVisible = false
    }

    // MARK: - Private

    private func present(forVersion version: String) {
        presentedVersion = version
        let source = loadChangelogSource()
        if let source, let release = ChangelogParser.release(forVersion: version, in: source) {
            currentRelease = release
            isDevBuild = false
        } else {
            currentRelease = nil
            isDevBuild = true
        }
        isVisible = true
    }

    /// Read `CHANGELOG.md` from the app bundle. Nil on any I/O failure
    /// — the modal renders the dev-build fallback in that case.
    private func loadChangelogSource() -> String? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func currentBundleVersion() -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}
