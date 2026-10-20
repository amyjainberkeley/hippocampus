import Foundation

/// Rows picked in History or one of its lenses (SPEC 3.4): ⌘-click and
/// ⇧-click pick several, and the detail sums them up. A row of one window
/// holds its whole run, so a selection is counted in saved moments, the same
/// number the note says after forgetting them.
public struct MomentSelection: Equatable, Sendable {
    /// The picked rows, newest first, as the list shows them.
    public let rows: [HistoryRow]

    /// The rows of `rows` whose ids are in `picked`, in the list's order.
    public init(picked: Set<UInt64>, in rows: [HistoryRow]) {
        self.rows = rows.filter { picked.contains($0.id) }
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Every moment the picked rows hold, newest first.
    public var momentIds: [UInt64] {
        rows.flatMap { $0.hits.map(\.id) }
    }

    /// How many saved moments the picked rows hold.
    public var momentCount: Int {
        rows.reduce(0) { $0 + $1.count }
    }

    /// What each picked row was about, newest first, each said once:
    /// "Reading “Rounding half to even” · Chatting in #launch".
    public var captions: [String] {
        var seen: Set<String> = []
        return rows.map { MomentRowText.headline($0.hit) }.filter { seen.insert($0).inserted }
    }

    /// The pictures under the summary: each row's screenshot, or its moment
    /// for the app's tile, at most six.
    public var pictures: [Hit] {
        rows.prefix(Self.maxPictures).map { $0.screenshot ?? $0.hit }
    }

    public static let maxPictures = 6
}

public extension HistorySections {
    /// The hour a heading stands for, as an hour heading's Forget asks for
    /// it: from the hour's start to the last microsecond before the next.
    static func hour(startingAt startUs: Int64, calendar: Calendar) -> ClosedRange<Int64> {
        let start = Date(timeIntervalSince1970: Double(startUs) / 1_000_000)
        let next = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
        let endUs = Int64((next.timeIntervalSince1970 * 1_000_000).rounded()) - 1
        return startUs...max(startUs, endUs)
    }
}
