// TimelineEventFormatting.swift
//
// Display formatting for `TimelineEvent`. Pure string work, no SwiftUI.
//
// These two helpers used to live as statics on `TimelineEventCard` in the
// `RecallUI` executable target. `RecallUIKitTests` depends on `RecallUIKit`
// only, so it could not see them and the whole test file failed to compile.
// Neither function touches SwiftUI, so the fix is to keep the logic in the
// library and leave only the view in the app target.

import Foundation

/// Display formatting for timeline rows.
public enum TimelineEventFormatting {
    /// Wall-clock `HH:mm` in the local timezone, from a microsecond epoch.
    public static func timeLabel(for tsUs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(tsUs) / 1_000_000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// `com.apple.Safari` → `Safari`. Falls back to the raw string.
    public static func shortAppName(_ bundle: String) -> String {
        bundle.split(separator: ".").last.map(String.init) ?? bundle
    }
}
