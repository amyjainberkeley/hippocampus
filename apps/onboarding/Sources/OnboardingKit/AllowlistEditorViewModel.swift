// SPDX-License-Identifier: TBD-private
//
// AllowlistEditorViewModel — drives the V2-P10 onboarding slide.
//
// Surface contract:
//   - Display the CSO baseline read-only (so users see what's already
//     trusted and don't add duplicate entries).
//   - List currently-running apps with toggles: capture OFF / capture
//     ON / capture + deep-hook ON. Deep-hook may only be ON when
//     capture is ON.
//   - Allow expert "add custom bundle id" entry for apps not in the
//     running set.
//   - Per ADR-0017 §3.2: refuse to add a bundle that's already on the
//     CSO baseline (the user would gain nothing; the baseline already
//     gates that bundle).
//   - Persist via `UserAllowlistStore` (atomic write + 0600 perms).
//   - Trigger `FullDiskAccessPermission.requestGrant()` when a deep-
//     hook toggle flips ON for a known-deep-hookable bundle.
//
// Deep-hookable bundles:
//   Wired (deep-hook toggle live):
//     - `com.apple.MobileSMS` (Messages.app — V2-P7, ADR-0032 §2).
//     - `com.apple.mail` (Mail.app — V2-P8b).
//   Scaffold-only (deep-hook toggle visible but disabled, "Coming soon"
//   tooltip — see ADR-0037):
//     - `com.apple.iCal` (Calendar.app — Phase D wire-up cycle 8.60+).
//     - `com.apple.Notes` (Notes.app — Phase D wire-up cycle 8.60+).
//     - `com.apple.reminders` (Reminders.app — Phase D wire-up cycle 8.60+).
//
// Other bundles: deep-hook toggle is hidden (no plugin to enable).

import Foundation

/// Per-app capture posture in the onboarding UI.
public enum AllowlistTogglePosture: Sendable, Equatable {
    case off
    case captureOnly
    case captureAndDeepHook
}

/// Renderable row in the editor UI.
public struct EditorRow: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let displayName: String
    public var posture: AllowlistTogglePosture
    /// Whether the deep-hook toggle should be visible (true for bundles
    /// with a wired plugin OR a scaffold-only plugin).
    public let supportsDeepHook: Bool
    /// True iff the deep-hook plugin is scaffold-only (surface exists but
    /// no reads wired — the toggle is rendered disabled with the
    /// [`deepHookScaffoldTooltip`](AllowlistEditorViewModel/deepHookScaffoldTooltip)
    /// copy). Per ADR-0037 (Calendar / Notes / Reminders — Phase D).
    public let deepHookScaffoldOnly: Bool
    /// True iff the bundle is in the CSO baseline (read-only — the
    /// user-layer cannot remove a baseline entry; UI shows the row
    /// as already-trusted).
    public let isBaselineEntry: Bool

    public init(
        bundleId: String,
        displayName: String,
        posture: AllowlistTogglePosture,
        supportsDeepHook: Bool,
        deepHookScaffoldOnly: Bool = false,
        isBaselineEntry: Bool
    ) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.posture = posture
        self.supportsDeepHook = supportsDeepHook
        self.deepHookScaffoldOnly = deepHookScaffoldOnly
        self.isBaselineEntry = isBaselineEntry
    }
}

public enum AllowlistEditorError: Error, Equatable {
    /// Bundle id is empty or whitespace-only.
    case emptyBundleId
    /// Bundle id is already on the CSO baseline (adding to user-layer
    /// is redundant + would confuse the audit trail).
    case duplicateOfBaseline(bundleId: String)
    /// Bundle id is already in the user-layer (use updatePosture).
    case duplicateOfUserLayer(bundleId: String)
}

@MainActor
public final class AllowlistEditorViewModel: ObservableObject {
    @Published public private(set) var rows: [EditorRow] = []
    @Published public private(set) var baselineEntries: [AllowlistEntry] = []
    @Published public private(set) var fullDiskAccessStatus: FullDiskAccessStatus = .notRequested
    @Published public private(set) var lastError: AllowlistEditorError?

    private let baselineStore: any AllowlistStore
    private let userStore: any UserAllowlistStore
    private let detector: any RunningAppsDetector
    private let fdaPermission: any FullDiskAccessPermission
    private let dateProvider: @Sendable () -> String

    /// Bundles whose deep-hook plugin is wired end-to-end (toggle is live).
    public static let deepHookableBundles: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.mail",
    ]

    /// Bundles whose deep-hook plugin is scaffold-only per ADR-0037 —
    /// surface exists (the row appears with the deep-hook toggle
    /// visible-but-disabled) but no reads are wired yet. Wire-up lands
    /// cycle 8.60+ behind CSO sign-off (see ADR-0037 §3).
    public static let deepHookScaffoldBundles: Set<String> = [
        "com.apple.iCal",
        "com.apple.Notes",
        "com.apple.reminders",
    ]

    /// Tooltip copy for the disabled deep-hook toggle on scaffold-only
    /// rows. Kept short to fit the AppKit tooltip cap while explaining
    /// the deferred wire state honestly.
    public static let deepHookScaffoldTooltip: String =
        "Coming soon — deep-hook wire-up for this app is deferred to a later release " +
        "(macOS Automation permission gate pending review). Capture-only is available today."

    /// Whether the deep-hook toggle should be visible for the given bundle.
    /// Union of the wired set and the scaffold-only set — both render the
    /// toggle; only the wired set has it enabled + interactive.
    public static func showsDeepHookToggle(bundleId: String) -> Bool {
        deepHookableBundles.contains(bundleId)
            || deepHookScaffoldBundles.contains(bundleId)
    }

    public init(
        baselineStore: any AllowlistStore,
        userStore: any UserAllowlistStore,
        detector: any RunningAppsDetector,
        fdaPermission: any FullDiskAccessPermission,
        dateProvider: @escaping @Sendable () -> String = AllowlistEditorViewModel.defaultDateProvider
    ) {
        self.baselineStore = baselineStore
        self.userStore = userStore
        self.detector = detector
        self.fdaPermission = fdaPermission
        self.dateProvider = dateProvider
    }

    public static let defaultDateProvider: @Sendable () -> String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    public func load() async {
        let baseline = await baselineStore.entries()
        let userEntries = await userStore.load()
        let detected = await detector.detect()
        let baselineIds = Set(baseline.map { $0.bundleId })
        let userById = Dictionary(
            uniqueKeysWithValues: userEntries.map { ($0.bundleId, $0) }
        )

        var rows: [EditorRow] = []
        var seen: Set<String> = []

        // 1. Baseline rows (read-only, always "captureOnly" since baseline
        //    doesn't carry per-app deep-hook state — that's user-layer-only).
        //    Resolve a human-friendly display name (`com.apple.MobileSMS`
        //    → `Messages`) so the UI never shows a raw bundle id. See
        //    `BundleDisplayNameResolver` for the local-only NSWorkspace
        //    + static-table + prettify ladder.
        for entry in baseline {
            rows.append(EditorRow(
                bundleId: entry.bundleId,
                displayName: BundleDisplayNameResolver.displayName(
                    for: entry.bundleId
                ),
                posture: .captureOnly,
                supportsDeepHook: Self.showsDeepHookToggle(bundleId: entry.bundleId),
                deepHookScaffoldOnly: Self.deepHookScaffoldBundles.contains(entry.bundleId),
                isBaselineEntry: true
            ))
            seen.insert(entry.bundleId)
        }

        // 2. Detected (running) apps not already in baseline.
        for app in detected where !seen.contains(app.bundleId) {
            let user = userById[app.bundleId]
            let posture: AllowlistTogglePosture
            if let u = user {
                if u.deepHookEnabled {
                    posture = .captureAndDeepHook
                } else if u.captureEnabled {
                    posture = .captureOnly
                } else {
                    posture = .off
                }
            } else {
                posture = .off
            }
            rows.append(EditorRow(
                bundleId: app.bundleId,
                displayName: app.displayName,
                posture: posture,
                supportsDeepHook: Self.showsDeepHookToggle(bundleId: app.bundleId),
                deepHookScaffoldOnly: Self.deepHookScaffoldBundles.contains(app.bundleId),
                isBaselineEntry: false
            ))
            seen.insert(app.bundleId)
        }

        // 3. User-layer entries not running right now (still listed so
        //    the user can see + manage them). Resolve display name the
        //    same way as baseline — the running-apps case above already
        //    has a name from NSWorkspace via the detector.
        for entry in userEntries where !seen.contains(entry.bundleId) {
            let posture: AllowlistTogglePosture
            if entry.deepHookEnabled {
                posture = .captureAndDeepHook
            } else if entry.captureEnabled {
                posture = .captureOnly
            } else {
                posture = .off
            }
            rows.append(EditorRow(
                bundleId: entry.bundleId,
                displayName: BundleDisplayNameResolver.displayName(
                    for: entry.bundleId
                ),
                posture: posture,
                supportsDeepHook: Self.showsDeepHookToggle(bundleId: entry.bundleId),
                deepHookScaffoldOnly: Self.deepHookScaffoldBundles.contains(entry.bundleId),
                isBaselineEntry: false
            ))
            seen.insert(entry.bundleId)
        }

        self.baselineEntries = baseline
        self.rows = rows
        self.fullDiskAccessStatus = await fdaPermission.status()
    }

    /// Update a row's posture. Persists immediately, refreshes FDA
    /// status if the toggle flipped into `.captureAndDeepHook` for a
    /// deep-hookable bundle.
    public func setPosture(
        for bundleId: String,
        to next: AllowlistTogglePosture
    ) async {
        guard let idx = rows.firstIndex(where: { $0.bundleId == bundleId }) else { return }
        var row = rows[idx]
        // Baseline rows are read-only.
        guard !row.isBaselineEntry else { return }
        // Deep-hook implies capture-on; refuse the contradictory state.
        // Also refuse a scaffold-only deep-hook (per ADR-0037): the row is
        // rendered with the toggle disabled and the tooltip explains why,
        // but a stale call site could still try to flip it — clamp here
        // so the model layer honours the same invariant as the UI.
        let safeNext: AllowlistTogglePosture
        if next == .captureAndDeepHook && !row.supportsDeepHook {
            safeNext = .captureOnly
        } else if next == .captureAndDeepHook && row.deepHookScaffoldOnly {
            safeNext = .captureOnly
        } else {
            safeNext = next
        }
        row.posture = safeNext
        rows[idx] = row

        await persist()

        if safeNext == .captureAndDeepHook && row.supportsDeepHook {
            await fdaPermission.requestGrant()
            self.fullDiskAccessStatus = await fdaPermission.status()
        }
    }

    /// Add a custom bundle id from the expert UI. Returns nil on success
    /// or surfaces the error in `lastError` and returns the error.
    @discardableResult
    public func addCustomBundle(
        bundleId: String,
        rationale: String? = nil
    ) async -> AllowlistEditorError? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let err = AllowlistEditorError.emptyBundleId
            self.lastError = err
            return err
        }
        let baselineIds = Set(baselineEntries.map { $0.bundleId })
        if baselineIds.contains(trimmed) {
            let err = AllowlistEditorError.duplicateOfBaseline(bundleId: trimmed)
            self.lastError = err
            return err
        }
        if rows.contains(where: { !$0.isBaselineEntry && $0.bundleId == trimmed }) {
            let err = AllowlistEditorError.duplicateOfUserLayer(bundleId: trimmed)
            self.lastError = err
            return err
        }
        let row = EditorRow(
            bundleId: trimmed,
            displayName: trimmed,
            posture: .captureOnly,
            supportsDeepHook: Self.showsDeepHookToggle(bundleId: trimmed),
            deepHookScaffoldOnly: Self.deepHookScaffoldBundles.contains(trimmed),
            isBaselineEntry: false
        )
        rows.append(row)
        self.lastError = nil
        await persist(extraRationale: [trimmed: rationale])
        return nil
    }

    /// Remove a user-layer row (baseline rows cannot be removed).
    public func removeUserEntry(bundleId: String) async {
        guard let idx = rows.firstIndex(where: { $0.bundleId == bundleId }) else { return }
        guard !rows[idx].isBaselineEntry else { return }
        rows.remove(at: idx)
        await persist()
    }

    /// Snapshot the current user-layer rows + persist via `userStore`.
    private func persist(
        extraRationale: [String: String?] = [:]
    ) async {
        let today = dateProvider()
        let existing = await userStore.load()
        let existingByBundle = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.bundleId, $0) }
        )

        let entries: [UserAllowlistEntry] = rows
            .filter { !$0.isBaselineEntry }
            .map { row in
                let prior = existingByBundle[row.bundleId]
                let rationale = extraRationale[row.bundleId].flatMap { $0 }
                    ?? prior?.rationale
                let captureEnabled = row.posture != .off
                let deepHookEnabled = row.posture == .captureAndDeepHook
                return UserAllowlistEntry(
                    bundleId: row.bundleId,
                    captureEnabled: captureEnabled,
                    deepHookEnabled: deepHookEnabled,
                    addedAt: prior?.addedAt ?? today,
                    rationale: rationale
                )
            }
        try? await userStore.save(entries)
    }
}
