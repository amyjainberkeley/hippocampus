// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The words for pictures of the windows beside the one in front (SPEC 6.7
/// and 9, rows 145 to 150): Preferences' switch under Remembering, its
/// budget and usage, and forgetting them. Every string passes
/// `SidePicturesCopyTests`' rules and `scripts/check-launch-copy.sh`.
public enum SidePicturesCopy {
    /// Row 145: the switch.
    public static let toggle = "Keep screenshots of windows beside the one you’re using"
    /// Row 146: under it. Calls and video are told by app and by title, and
    /// private windows by their markers (`SideWindowPicturePolicy`), so the
    /// line says "it recognizes", not "never".
    public static let explanation = "When their text changes, Hippocampus keeps a picture of other windows you can "
        + "see, encrypted like the rest. None is kept of a call, a video or a private window it recognizes."
    /// Row 147: the budget.
    public static let useAtMost = "Use at most:"

    /// Row 147: a budget choice, "1 GB", "2 GB" or "5 GB".
    public static func budget(megabytes: Int) -> String {
        size(Int64(megabytes) * 1_000_000)
    }

    /// Row 147: "Using 640 MB."
    public static func using(bytes: Int64) -> String {
        "Using \(size(bytes))."
    }

    /// Row 148: the budget is full. "Using 2 GB of 2 GB. Older pictures are
    /// thinned out first."
    public static func full(bytes: Int64, budgetBytes: Int64) -> String {
        "Using \(size(bytes)) of \(size(budgetBytes)). Older pictures are thinned out first."
    }

    /// Row 148: below the disk floor.
    public static let lowOnSpace = "Paused: the Mac is low on space."

    /// Row 149: when off.
    public static let forgetButton = "Forget Pictures of Other Windows…"
    public static let forgetTitle = "Forget pictures of other windows?"
    public static let forgetMessage = "Their text stays. Only the pictures are deleted from this Mac for good."
    /// Row 114: the confirmation's buttons; Cancel is the default.
    public static let forget = "Forget"
    public static let cancel = "Cancel"

    /// Row 150: What's New, for people who already use Hippocampus.
    public static let whatsNew = "Hippocampus can now keep pictures of the other windows you can see, not just the "
        + "one you’re using. It’s off until you turn it on."
    public static let whatsNewButton = "Turn On…"

    /// Every string above, filled with typical sizes, for the copy tests.
    public static var allStrings: [String] {
        [toggle, explanation, useAtMost, lowOnSpace, forgetButton, forgetTitle, forgetMessage, forget, cancel,
         whatsNew, whatsNewButton, using(bytes: 640_000_000), full(bytes: 2_000_000_000, budgetBytes: 2_000_000_000)]
            + SidePictureSettings.budgetChoicesMB.map { budget(megabytes: $0) }
    }

    /// Sizes as the Mac shows them: decimal, in MB and GB.
    public static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
