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
// Deep-hookable bundles (V2-P7/V2-P8b scope per ADR-0032 + §3(f)):
//   - `com.apple.MobileSMS` (Messages.app — V2-P7).
//   - `com.apple.mail` (Mail.app — V2-P8b).
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
    /// Whether the deep-hook toggle should be visible (true only for
    /// bundles V2-P7/V2-P8b have a plugin for).
    public let supportsDeepHook: Bool
    /// True iff the bundle is in the CSO baseline (read-only — the
    /// user-layer cannot remove a baseline entry; UI shows the row
    /// as already-trusted).
    public let isBaselineEntry: Bool

    public init(
        bundleId: String,
        displayName: String,
        posture: AllowlistTogglePosture,
        supportsDeepHook: Bool,
        isBaselineEntry: Bool
    ) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.posture = posture
        self.supportsDeepHook = supportsDeepHook
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

    public static let deepHookableBundles: Set<String> = [
        "com.apple.MobileSMS",
        "com.apple.mail",
    ]

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
        for entry in baseline {
            rows.append(EditorRow(
                bundleId: entry.bundleId,
                displayName: entry.bundleId,
                posture: .captureOnly,
                supportsDeepHook: Self.deepHookableBundles.contains(entry.bundleId),
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
                supportsDeepHook: Self.deepHookableBundles.contains(app.bundleId),
                isBaselineEntry: false
            ))
            seen.insert(app.bundleId)
        }

        // 3. User-layer entries not running right now (still listed so
        //    the user can see + manage them).
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
                displayName: entry.bundleId,
                posture: posture,
                supportsDeepHook: Self.deepHookableBundles.contains(entry.bundleId),
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
        let safeNext: AllowlistTogglePosture
        if next == .captureAndDeepHook && !row.supportsDeepHook {
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
            supportsDeepHook: Self.deepHookableBundles.contains(trimmed),
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
