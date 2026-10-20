import Foundation

/// Where each session sits on Overview's day strip, as fractions of its width
/// from 0 to 1 (spec-recall S2, contract overview.md section 6). The agent
/// sets the strip's span; this places the sessions, the hour ticks and the
/// stretches with nothing saved.
public struct DayStripLayout: Equatable, Sendable {
    public struct Block: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let kind: WorkKind
        /// Its colour and legend word: the strip kind holding most of its time.
        public let stripKind: StripKind
        public let x: Double
        public let width: Double
        /// Starts less than five minutes after the session before it: drawn
        /// with a hairline between them.
        public let touchesPrevious: Bool
        public let inProgress: Bool
    }

    public struct Tick: Equatable, Sendable {
        /// The local hour the tick marks.
        public let atUs: Int64
        public let x: Double
    }

    /// Time on the strip with nothing saved: empty space, "Nothing saved" on
    /// hover (RULINGS W6).
    public struct Span: Equatable, Sendable {
        public let startUs: Int64
        public let endUs: Int64
        public let x: Double
        public let width: Double
    }

    public let startUs: Int64
    public let endUs: Int64
    public let blocks: [Block]
    public let ticks: [Tick]
    public let nothingSaved: [Span]

    /// Nil for a day with no sessions: no strip is drawn. `minimumWidth` is
    /// the narrowest a session may be drawn, as a fraction of the strip
    /// (6 pt over the strip's width). `span`, when given, is the time the
    /// strip covers in place of the agent's: Today widens it to the day's
    /// calendar (`TodayCalendar.span`).
    public init?(overview: DayOverview, minimumWidth: Double = 0, calendar: Calendar = .current, span: DayStrip? = nil) {
        guard let strip = span ?? overview.strip, strip.endUs > strip.startUs, !overview.blocks.isEmpty
        else { return nil }
        startUs = strip.startUs
        endUs = strip.endUs
        let span = Double(strip.endUs - strip.startUs)
        func fraction(_ us: Int64) -> Double {
            min(max(Double(us - strip.startUs) / span, 0), 1)
        }
        let minimum = min(max(minimumWidth, 0), 1)
        blocks = overview.blocks.map { block in
            let x = fraction(block.startUs)
            let width = max(fraction(block.endUs) - x, minimum)
            return Block(id: block.id, kind: block.kind, stripKind: SessionDetail.stripKind(of: block),
                         x: min(x, 1 - width), width: width,
                         touchesPrevious: block.touchesPrevious, inProgress: block.inProgress)
        }
        ticks = Self.ticks(from: strip.startUs, to: strip.endUs, calendar: calendar).map {
            Tick(atUs: $0, x: fraction($0))
        }
        // Today ends at now: the time after it is still to come, not empty.
        let end = overview.isToday ? min(strip.endUs, max(overview.nowUs, strip.startUs)) : strip.endUs
        var spans: [Span] = []
        // Before the first session, unless the day held more moments than the
        // agent reads and its earliest part is missing.
        var cursor = overview.truncated ? overview.blocks[0].startUs : strip.startUs
        for block in overview.blocks {
            if block.startUs > cursor, cursor < end {
                let stop = min(block.startUs, end)
                spans.append(Span(startUs: cursor, endUs: stop, x: fraction(cursor), width: fraction(stop) - fraction(cursor)))
            }
            cursor = max(cursor, block.endUs)
        }
        if cursor < end {
            spans.append(Span(startUs: cursor, endUs: end, x: fraction(cursor), width: fraction(end) - fraction(cursor)))
        }
        nothingSaved = spans
    }

    /// One word of the legend, with the time its sessions held.
    public struct LegendEntry: Equatable, Sendable, Identifiable {
        public let kind: StripKind
        public let heldUs: Int64
        public var id: StripKind { kind }
    }

    /// The legend under the strip, in the sidebar's words and a fixed order
    /// (Code, Documents, Conversations, Web Pages, Calls, Other), each kind
    /// that a session of the day is drawn in.
    public static func legend(_ blocks: [DayBlock]) -> [LegendEntry] {
        var held: [StripKind: Int64] = [:]
        for block in blocks {
            held[SessionDetail.stripKind(of: block), default: 0] += max(0, block.endUs - block.startUs)
        }
        return StripKind.allCases.compactMap { kind in held[kind].map { LegendEntry(kind: kind, heldUs: $0) } }
    }

    /// Local hour starts inside the span, every hour up to 8 hours, every two
    /// up to 16, else every three; a tick every two or three hours falls on
    /// hours that divide by it.
    static func ticks(from start: Int64, to end: Int64, calendar: Calendar) -> [Int64] {
        let hours = Double(end - start) / 3_600_000_000
        let step = hours <= 8 ? 1 : hours <= 16 ? 2 : 3
        let first = Date(timeIntervalSince1970: Double(start) / 1_000_000)
        let last = Date(timeIntervalSince1970: Double(end) / 1_000_000)
        guard var hour = calendar.dateInterval(of: .hour, for: first)?.start else { return [] }
        if hour < first, let next = calendar.date(byAdding: .hour, value: 1, to: hour) {
            hour = next
        }
        var result: [Int64] = []
        while hour <= last {
            if calendar.component(.hour, from: hour) % step == 0 {
                result.append(Int64((hour.timeIntervalSince1970 * 1_000_000).rounded()))
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return result
    }
}
