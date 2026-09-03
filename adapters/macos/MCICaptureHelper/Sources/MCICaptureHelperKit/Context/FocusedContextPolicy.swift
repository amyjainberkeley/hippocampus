// SPDX-License-Identifier: TBD-private

/// Prevents independently sampled metadata from being attached to pixels from
/// another application's focused-window generation.
public enum FocusedContextPolicy {
    public static func admittedWindowTitle(
        snapshotBundleId: String?,
        effectiveBundleId: String?,
        snapshotFocusGeneration: UInt64?,
        effectiveFocusGeneration: UInt64?,
        windowTitle: String?
    ) -> String? {
        guard let effectiveBundleId, !effectiveBundleId.isEmpty else { return nil }
        guard snapshotBundleId == effectiveBundleId,
              snapshotFocusGeneration == effectiveFocusGeneration,
              snapshotFocusGeneration != nil
        else {
            return nil
        }
        return windowTitle
    }
}
