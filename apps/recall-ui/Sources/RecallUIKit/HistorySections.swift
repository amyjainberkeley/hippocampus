import Foundation

/// One run of History under one heading (spec-recall S3).
public struct HistorySection: Equatable, Sendable, Identifiable {
    public enum Owner: Equatable, Sendable {
        /// The session the moments belong to: a kind dot, its title, "start–end".
        case session(DayBlock)
        /// Moments in no session, under their clock hour ("3 PM").
        case hour(startUs: Int64)
    }

    /// Unique in one grouping, and the same for the same rows.
    public let id: String
    public let owner: Owner
    /// Newest first.
    public let rows: [HistoryRow]
}

/// One row of History: one moment, or several moments in a row of the same
/// window, which open as the newest of them (critique-recall-product finding 6).
public struct HistoryRow: Equatable, Sendable, Identifiable {
    /// Newest first, never empty.
    public let hits: [Hit]

    public var id: UInt64 { hits[0].id }
    /// The moment the row opens.
    public var hit: Hit { hits[0] }
    /// "{n} moments" when more than one.
    public var count: Int { hits.count }
    /// The row's picture: its own moment's screenshot, else the newest
    /// screenshot of its other moments, as the reader lets a moment show its
    /// window's (`screenshot_for_event`): only a moment read off the window
    /// in front (never a window beside it, an import or a message), and only
    /// a screenshot taken at most five minutes before it.
    public var screenshot: Hit? {
        let newest = hits[0]
        if newest.thumbnailURL != nil { return newest }
        guard Self.mayBorrow(newest) else { return nil }
        return hits.dropFirst().first { hit in
            guard hit.thumbnailURL != nil, Self.mayBorrow(hit) else { return false }
            let taken = hit.thumbnailTsUs ?? hit.tsUs
            return taken <= newest.tsUs && newest.tsUs - taken <= Self.screenshotReuseUs
        }
    }

    /// Moments that may show the screenshot their window kept a moment
    /// earlier (the reader's rule). A row from a build that sent no kind is
    /// of an unknown kind, as the reader counts it.
    static let borrowingSources: Set<String> = ["screen_ocr", "browser_page", "browser_page_with_ocr", "unknown"]

    static func mayBorrow(_ hit: Hit) -> Bool {
        borrowingSources.contains(hit.sourceKind ?? "unknown")
    }

    /// How long a window's screenshot stands for its later moments, as the
    /// reader allows (`SCREENSHOT_REUSE_US`).
    static let screenshotReuseUs: UInt64 = 5 * 60 * 1_000_000
}

public enum HistorySections {
    /// Walk `hits` (newest first) and start a section whenever the owner
    /// changes: the session whose time holds the moment, or else the moment's
    /// clock hour. With no sessions every section is an hour. Moments in a
    /// row with the same app and the same window title share one row.
    public static func group(
        hits: [Hit],
        sessions: [DayBlock],
        calendar: Calendar = .current,
        collapsingRepeats: Bool = true
    ) -> [HistorySection] {
        enum Key: Equatable {
            case session(Int64)
            case hour(Int64)
        }
        var sections: [(key: Key, owner: HistorySection.Owner, rows: [[Hit]])] = []
        for hit in hits {
            let owner = Self.owner(of: hit, in: sessions, calendar: calendar)
            let key: Key = switch owner {
            case let .session(block): .session(block.id)
            case let .hour(start): .hour(start)
            }
            if sections.last?.key != key {
                sections.append((key, owner, []))
            }
            let index = sections.count - 1
            if collapsingRepeats, let previous = sections[index].rows.last?.first,
               Self.sameWindow(previous, hit) {
                sections[index].rows[sections[index].rows.count - 1].append(hit)
            } else {
                sections[index].rows.append([hit])
            }
        }
        return sections.map { section in
            let rows = section.rows.map(HistoryRow.init(hits:))
            let prefix = switch section.key {
            case let .session(id): "session-\(id)"
            case let .hour(start): "hour-\(start)"
            }
            return HistorySection(id: "\(prefix)-\(rows[0].id)", owner: section.owner, rows: rows)
        }
    }

    private static func owner(of hit: Hit, in sessions: [DayBlock], calendar: Calendar) -> HistorySection.Owner {
        let ts = Int64(clamping: hit.tsUs)
        if let block = sessions.first(where: { $0.startUs <= ts && ts <= $0.endUs }) {
            return .session(block)
        }
        let date = Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000)
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return .hour(startUs: Int64((hour.timeIntervalSince1970 * 1_000_000).rounded()))
    }

    /// The same window: the same app and the same, non-empty, title, leaving
    /// out a status mark the app puts before it ("✳" and "⠐" while a coding
    /// assistant works are one session).
    private static func sameWindow(_ a: Hit, _ b: Hit) -> Bool {
        let title = Formatters.titleWithoutMarks(a.windowTitle ?? "")
        guard !title.isEmpty else { return false }
        return a.appBundleId == b.appBundleId
            && Formatters.titleWithoutMarks(b.windowTitle ?? "") == title
    }
}
