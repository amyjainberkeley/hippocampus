import Foundation

/// A deterministic reading of available samples, never a measure of activity or completion.
public struct DailyReview: Equatable, Sendable {
    public struct ResumePoint: Equatable, Sendable, Identifiable {
        public var id: UInt64 { evidence[0].id }
        public let title: String
        public let detail: String
        public let sourceLabel: String
        public let sampleCount: Int
        public let evidence: [TimelineEvent]
        public var sampleLabel: String {
            "\(sampleCount) saved \(sampleCount == 1 ? "sample" : "samples")"
        }
    }

    public struct Observation: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case lastContext, returnedToApp, captureGap }
        public var id: Kind { kind }
        public let kind: Kind
        public let title: String
        public let detail: String
        public let evidence: [TimelineEvent]
    }

    public let events: [TimelineEvent]
    public let observations: [Observation]
    public var resumePoints: [ResumePoint] {
        struct Source: Hashable {
            let app: String?
            let kind: String?
            let unattributedID: UInt64?
        }
        let grouped = Dictionary(grouping: events) { event in
            Source(app: event.appBundleId, kind: event.sourceKind,
                   unattributedID: event.appBundleId?.isEmpty != false || event.sourceKind == nil ? event.id : nil)
        }
        return grouped.values.compactMap { rows -> ResumePoint? in
            guard let latest = rows.last else { return nil }
            let hydrated = observations.first { $0.kind == .lastContext && $0.evidence.first?.id == latest.id }
            return ResumePoint(title: Formatters.appDisplayName(latest.appBundleId),
                detail: hydrated?.detail ?? Formatters.snippet(Formatters.stripContextHeader(latest.snippet), maxLen: 280),
                sourceLabel: MemorySourceKind.label(latest.sourceKind), sampleCount: rows.count,
                evidence: Array(rows.reversed().prefix(3)))
        }.sorted {
            let left = $0.evidence[0], right = $1.evidence[0]
            return left.tsUs == right.tsUs ? left.id > right.id : left.tsUs > right.tsUs
        }.prefix(4).map { $0 }
    }
    public var textCount: Int {
        events.filter { !Formatters.stripContextHeader($0.snippet).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
    public var imageCount: Int { events.filter(\.hasScreenshot).count }
    public var countLabel: String { "\(textCount) saved text samples / \(imageCount) saved image samples" }
    public static let coverageNote = "Available samples may omit captures. Counts describe saved evidence, not activity time or completed work."
    public var visualEvidence: [TimelineEvent] {
        Self.sample(events.filter(\.hasScreenshot), limit: 6)
    }

    public init(day: MemoryDay, events: some Sequence<TimelineEvent>, latestContextText: EventText? = nil) {
        var seen = Set<UInt64>()
        let sorted = events.filter { day.contains($0.tsUs) }.sorted {
            $0.tsUs == $1.tsUs ? $0.id < $1.id : $0.tsUs < $1.tsUs
        }.filter { seen.insert($0.id).inserted }
        self.events = sorted
        var observations: [Observation] = []
        if let last = sorted.last {
            var detail = Formatters.stripContextHeader(last.snippet)
            if let text = latestContextText, text.eventId == last.id,
               text.tsUs == last.tsUs, text.appBundleId == last.appBundleId {
                let body = Formatters.stripContextHeader(text.text)
                // A bounded read ending inside an internal header has no usable body.
                if !text.text.hasPrefix("[app=") || body != text.text {
                    detail = Formatters.snippet(body, maxLen: 400)
                }
            }
            observations.append(Observation(kind: .lastContext, title: "Last saved context",
                detail: detail, evidence: [last]))
        }

        // Imports and unknown acquisition sources cannot establish screen activity.
        let screen = sorted.filter { $0.sourceKind == "screen_ocr" || $0.sourceKind == "browser_page_with_ocr" }
        var previousByApp: [String: TimelineEvent] = [:]
        var latestReturn: Observation?
        var largestGap: (before: TimelineEvent, after: TimelineEvent)?
        for (index, event) in screen.enumerated() {
            if index > 0 {
                let previous = screen[index - 1]
                if let app = event.appBundleId, !app.isEmpty,
                   let previousApp = previous.appBundleId, !previousApp.isEmpty, previousApp != app,
                   let earlier = previousByApp[app] {
                    latestReturn = Observation(kind: .returnedToApp,
                        title: "Returned to \(Formatters.appDisplayName(app))",
                        detail: "This app appears again after a capture from \(Formatters.appDisplayName(previousApp)).",
                        evidence: [earlier, previous, event])
                }
                let gap = event.tsUs - previous.tsUs
                if gap > 600_000_000,
                   gap > largestGap.map({ $0.after.tsUs - $0.before.tsUs }) ?? 0 {
                    largestGap = (previous, event)
                }
            }
            if let app = event.appBundleId, !app.isEmpty { previousByApp[app] = event }
        }
        if let latestReturn { observations.append(latestReturn) }
        if let gap = largestGap {
            observations.append(Observation(kind: .captureGap, title: "Capture gap",
                detail: "More than 10 minutes between these available capture samples. Activity between them is unknown.",
                evidence: [gap.before, gap.after]))
        }
        self.observations = observations
    }

    static func sample<T>(_ values: [T], limit: Int) -> [T] {
        guard values.count > limit else { return values }
        return (0..<limit).map { values[$0 * (values.count - 1) / (limit - 1)] }
    }
}

public enum DailyHandoffError: LocalizedError {
    case evidenceChanged

    public var errorDescription: String? {
        "The saved evidence changed. Review the updated preview before copying or exporting."
    }
}
