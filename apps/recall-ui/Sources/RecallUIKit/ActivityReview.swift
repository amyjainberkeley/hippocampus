import Foundation

/// Measured input state over a half-open foreground interval. Never derived from captures.
public struct ActivityInterval: Codable, Equatable, Sendable {
    public let startUs: UInt64
    public let endUs: UInt64
    public let state: String
    public let appBundleId: String?

    public init(startUs: UInt64, endUs: UInt64, state: String, appBundleId: String?) {
        self.startUs = startUs
        self.endUs = endUs
        self.state = state
        self.appBundleId = appBundleId
    }

    enum CodingKeys: String, CodingKey {
        case startUs = "start_us", endUs = "end_us", state, appBundleId = "app_bundle_id"
    }
}

public struct ActivityPage: Codable, Equatable, Sendable {
    public let intervals: [ActivityInterval]
    public let truncated: Bool

    public init(intervals: [ActivityInterval], truncated: Bool) {
        self.intervals = intervals
        self.truncated = truncated
    }
}

public enum ActivityReadError: Error { case unavailable }

public enum MeasuredInputState: String, CaseIterable, Sendable, Identifiable {
    case inputActive = "input_active", inputIdle = "input_idle", unknown
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .inputActive: return "Recent input"
        case .inputIdle: return "No recent input"
        case .unknown: return "Unknown"
        }
    }
}

/// Reconciles a complete page against its requested window. Gaps stay explicitly unmeasured.
public struct ActivitySummary: Equatable, Sendable {
    public struct Segment: Equatable, Sendable, Identifiable {
        public var id: UInt64 { startUs }
        public let startUs: UInt64
        public let endUs: UInt64
        public let state: String
        public let appBundleId: String?
        public let isGap: Bool
        public var inputState: MeasuredInputState { MeasuredInputState(rawValue: state) ?? .unknown }
    }

    public let startUs: UInt64
    public let endUs: UInt64
    public let intervals: [Segment]

    public init?(page: ActivityPage, startUs: UInt64, endUs: UInt64) {
        guard startUs < endUs, !page.truncated, !page.intervals.isEmpty,
              page.intervals.allSatisfy({ $0.startUs < $0.endUs }) else { return nil }
        let rows = page.intervals.filter { $0.endUs > startUs && $0.startUs < endUs }
            .sorted { $0.startUs < $1.startUs }
        guard !rows.isEmpty else { return nil }
        var segments: [Segment] = []
        var cursor = startUs
        for row in rows {
            let start = max(startUs, row.startUs)
            let end = min(endUs, row.endUs)
            guard start >= cursor else { return nil }
            if start > cursor {
                segments.append(Segment(startUs: cursor, endUs: start, state: "unknown", appBundleId: nil, isGap: true))
            }
            let state = MeasuredInputState(rawValue: row.state) ?? .unknown
            segments.append(Segment(startUs: start, endUs: end, state: state.rawValue,
                appBundleId: state == .unknown ? nil : row.appBundleId, isGap: false))
            cursor = end
        }
        if cursor < endUs {
            segments.append(Segment(startUs: cursor, endUs: endUs, state: "unknown", appBundleId: nil, isGap: true))
        }
        self.startUs = startUs
        self.endUs = endUs
        self.intervals = segments
    }

    public func totalUs(for state: MeasuredInputState) -> UInt64 {
        intervals.filter { $0.inputState == state }.reduce(0) { $0 + $1.endUs - $1.startUs }
    }

    public struct AppTotal: Identifiable, Equatable, Sendable {
        public var id: String { appBundleId }
        public let appBundleId: String
        public var totalUs: UInt64
        public var recentInputUs: UInt64
    }

    public struct ForegroundStretch: Identifiable, Equatable, Sendable {
        public var id: UInt64 { startUs }
        public let appBundleId: String
        public let startUs: UInt64
        public var endUs: UInt64
        public var durationUs: UInt64 { endUs - startUs }
    }

    /// Join measured adjacency only. Unknown, missing attribution and gaps end a stretch.
    public var foregroundStretches: [ForegroundStretch] {
        var stretches: [ForegroundStretch] = []
        for interval in intervals {
            guard interval.inputState != .unknown, !interval.isGap,
                  let app = interval.appBundleId, !app.isEmpty else { continue }
            if let last = stretches.last, last.endUs == interval.startUs, last.appBundleId == app {
                stretches[stretches.count - 1].endUs = interval.endUs
            } else {
                stretches.append(ForegroundStretch(appBundleId: app, startUs: interval.startUs, endUs: interval.endUs))
            }
        }
        return stretches
    }

    public var longestForegroundStretch: ForegroundStretch? {
        foregroundStretches.max {
            $0.durationUs == $1.durationUs ? $0.startUs > $1.startUs : $0.durationUs < $1.durationUs
        }
    }

    public var appTotals: [AppTotal] {
        var totals: [String: AppTotal] = [:]
        for interval in intervals where interval.inputState != .unknown {
            guard let app = interval.appBundleId else { continue }
            let duration = interval.endUs - interval.startUs
            var total = totals[app] ?? AppTotal(appBundleId: app, totalUs: 0, recentInputUs: 0)
            total.totalUs += duration
            if interval.inputState == .inputActive { total.recentInputUs += duration }
            totals[app] = total
        }
        return totals.values.sorted {
            $0.totalUs == $1.totalUs ? $0.appBundleId < $1.appBundleId : $0.totalUs > $1.totalUs
        }
    }
}
