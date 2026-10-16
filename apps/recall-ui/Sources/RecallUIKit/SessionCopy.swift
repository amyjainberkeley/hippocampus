import Foundation

/// "Copy for your AI" for one session or the Right now card: that session's
/// own moments, never a search of everything remembered (RULINGS I13, W5;
/// critique-recall-engineering finding 15).
///
/// The moments are read by time from this Mac's memory (a browse of the
/// session's own range), so the copy holds what was on screen in that
/// session and nothing learned about the person. Each moment carries its
/// whole reading, what the person was reading in that window, not the
/// list's short excerpt (audit product-9). It is the same Markdown the
/// window's other exports write (`VisualMemoryExport`): a title, the plain
/// warning, then each moment's time, app, window and text, with no "Truth
/// status", "Retrieval" or "Generated at" lines.
public enum SessionCopy {
    /// At most this many moments go into one copy (`VisualMemoryExport` caps
    /// an export at the same number).
    public static let maxMoments = VisualMemoryExport.maxMoments
    /// How many moments of the session are read to choose from, newest
    /// first. A session is at most 30 minutes, so this holds a whole one at
    /// a moment a second; fewer would drop the start of a busy session. The
    /// reader allows up to 10,000.
    public static let readLimit = 2_000

    /// The Markdown for the session `title` over `range`, read from `reader`.
    public static func markdown(title: String, range: ClosedRange<Int64>, reader: BrainReader) async throws -> String {
        guard range.lowerBound >= 0 else { return markdown(title: title, moments: []) }
        let options = SearchOptions(text: "", limit: readLimit,
                                    timeFromUs: UInt64(range.lowerBound), timeToUs: UInt64(range.upperBound),
                                    mode: .text, browse: true)
        let hits = try await reader.search(options)
        let chosen = moments(hits, in: range)
        var readings: [UInt64: EventReading] = [:]
        for hit in chosen {
            // A moment whose reading cannot be read keeps its excerpt.
            if let reading = try? await reader.eventReading(eventId: hit.id), reading.matches(hit) {
                readings[hit.id] = reading
            }
        }
        return markdown(title: title, moments: chosen, readings: readings)
    }

    public static func markdown(title: String, moments: [Hit], readings: [UInt64: EventReading] = [:]) -> String {
        VisualMemoryExport.markdown(title: title, hits: moments, readings: readings)
    }

    /// The moments a copy holds, oldest first: those inside `range`, without
    /// the system apps the agent ignores, one per run of the same window (its
    /// newest, which holds the latest text), and at most `limit` of them,
    /// spread evenly over the session with its first and last kept.
    public static func moments(_ hits: [Hit], in range: ClosedRange<Int64>, limit: Int = maxMoments) -> [Hit] {
        var seen = Set<UInt64>()
        let inside = hits
            .filter { hit in
                guard let ts = Int64(exactly: hit.tsUs), range.contains(ts) else { return false }
                return !WhatIsSent.isIgnoredApp(hit.appBundleId) && seen.insert(hit.eventId).inserted
            }
            .sorted { $0.tsUs == $1.tsUs ? $0.eventId < $1.eventId : $0.tsUs < $1.tsUs }
        var runs: [Hit] = []
        for hit in inside {
            if let last = runs.last, last.appBundleId == hit.appBundleId, last.windowTitle == hit.windowTitle {
                runs[runs.count - 1] = hit
            } else {
                runs.append(hit)
            }
        }
        let limit = max(0, limit)
        guard runs.count > limit else { return runs }
        guard limit > 1 else { return limit == 1 ? [runs[runs.count - 1]] : [] }
        let last = runs.count - 1
        return (0..<limit).map { step in
            runs[Int((Double(step) * Double(last) / Double(limit - 1)).rounded())]
        }
    }
}
