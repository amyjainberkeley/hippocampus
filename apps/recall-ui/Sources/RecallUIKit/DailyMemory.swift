import Combine
import Foundation

/// A local calendar day, expressed as the inclusive microsecond range the FFI accepts.
public struct MemoryDay: Equatable, Sendable {
    public let dateLocal: String
    public let startUs: UInt64
    public let endUs: UInt64

    public init(date: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        startUs = UInt64(max(0, start.timeIntervalSince1970 * 1_000_000))
        endUs = UInt64(max(1, end.timeIntervalSince1970 * 1_000_000)) - 1
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        dateLocal = formatter.string(from: start)
    }

    public func contains(_ timestamp: UInt64) -> Bool {
        timestamp >= startUs && timestamp <= endUs
    }
}

public extension TimelineEvent {
    /// IDs may be reused after deletion. Match acquisition identity before showing new content.
    func matches(_ hit: Hit) -> Bool {
        id == hit.id && tsUs == hit.tsUs && appBundleId == hit.appBundleId && sourceKind == hit.sourceKind
    }

    var hasScreenshot: Bool {
        !(thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public extension Episode {
    func evidence(from events: [TimelineEvent]) -> [TimelineEvent] {
        var seen = Set<UInt64>()
        return events.filter { $0.appBundleId == appBundleId && $0.tsUs >= tsStartUs && $0.tsUs <= tsEndUs }
            .sorted { $0.tsUs == $1.tsUs ? $0.id < $1.id : $0.tsUs < $1.tsUs }
            .filter { seen.insert($0.id).inserted }
    }
}

/// Groups available screenshot observations, without inferring activity between long gaps.
public struct VisualMemoryEpisode: Identifiable, Equatable, Sendable {
    public var id: UInt64 { events[0].id }
    public let events: [TimelineEvent]
    public var appBundleId: String? { events[0].appBundleId }
    public var observedSeconds: Double {
        Double(events[events.count - 1].tsUs - events[0].tsUs) / 1_000_000
    }

    public static func group(_ events: some Sequence<TimelineEvent>) -> [Self] {
        let screenshots = events.filter(\.hasScreenshot).sorted {
            $0.tsUs == $1.tsUs ? $0.id < $1.id : $0.tsUs < $1.tsUs
        }
        var groups: [[TimelineEvent]] = []
        for event in screenshots {
            if let previous = groups.last?.last,
               previous.appBundleId == event.appBundleId,
               event.tsUs - previous.tsUs <= 600_000_000 {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        return groups.map { Self(events: $0) }
    }

    public static func durationLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Single observation" }
        if seconds < 60 { return "\(Int(seconds))s observed" }
        if seconds < 3600 { return "\(Int(seconds / 60))m observed" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m observed"
    }
}

@MainActor
public final class DailyMemoryViewModel: ObservableObject {
    @Published public var selectedDate: Date {
        didSet {
            if day != MemoryDay(date: oldValue, calendar: calendar) {
                generation += 1
                isLoading = false
                latestContextText = nil
                activitySummary = nil
                activityStatus = nil
                briefNavigationGeneration += 1
                showsSavedDraft = false
                handoffPreview = nil
                events = []
                brief = nil
                searchHits = []
                refreshedAt = nil
                errorMessage = nil
                briefError = nil
            }
        }
    }
    @Published public var query = ""
    @Published public private(set) var events: [TimelineEvent] = []
    @Published public private(set) var searchHits: [Hit] = []
    @Published public private(set) var brief: Brief?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var briefError: String?
    @Published public private(set) var searchError: String?
    @Published public private(set) var refreshedAt: Date?
    @Published public private(set) var captureHealth: CaptureHealthReceipt?
    @Published public private(set) var activitySummary: ActivitySummary?
    @Published public private(set) var activityStatus: String?
    @Published public private(set) var handoffPreview: String?
    @Published private var latestContextText: EventText?
    @Published public var showsSavedDraft = false
    private let reader: BrainReader
    private let calendar: Calendar
    private let healthLoader: @Sendable () async -> CaptureHealthReceipt?
    private let now: @Sendable () -> Date
    private var generation = 0
    private var searchGeneration = 0
    private var loadedDay: MemoryDay?
    private var briefNavigationGeneration = 0

    public init(reader: BrainReader, selectedDate: Date = Date(), calendar: Calendar = .current,
                healthLoader: @escaping @Sendable () async -> CaptureHealthReceipt? = { await CaptureHealthReceipt.load() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.selectedDate = selectedDate
        self.calendar = calendar
        self.healthLoader = healthLoader
        self.now = now
    }

    public var day: MemoryDay { MemoryDay(date: selectedDate, calendar: calendar) }
    public var review: DailyReview { DailyReview(day: day, events: events, latestContextText: latestContextText) }
    public var screenshots: [TimelineEvent] { events.filter(\.hasScreenshot) }
    public var episodes: [VisualMemoryEpisode] { VisualMemoryEpisode.group(events) }
    public var canExportSummary: Bool {
        loadedDay == day && !isLoading && errorMessage == nil && !review.events.isEmpty
    }

    public func exportSummary() async throws -> String {
        guard canExportSummary else { throw CancellationError() }
        let selectedDay = day
        let request = generation
        let samples = DailyReview.sample(review.events, limit: 24)
        let ids = samples.map(\.id)
        let identities = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
        let fetched = ids.isEmpty ? [] : try await reader.fetchEventsByIds(ids)
        guard request == generation, day == selectedDay, canExportSummary, !Task.isCancelled else {
            throw CancellationError()
        }
        var seen = Set<UInt64>()
        let hits = fetched.filter { identities[$0.id]?.matches($0) == true && selectedDay.contains($0.tsUs) && seen.insert($0.id).inserted }
            .sorted { $0.tsUs == $1.tsUs ? $0.id < $1.id : $0.tsUs < $1.tsUs }
        var excerpts: [Hit] = []
        for hit in hits {
            let text = try await reader.eventText(eventId: hit.id)
            guard request == generation, day == selectedDay, canExportSummary, !Task.isCancelled else {
                throw CancellationError()
            }
            guard let text, text.matches(hit) else { continue }
            let body = Formatters.stripContextHeader(text.text)
            // A header truncated by the bounded text read is not evidence of the body.
            guard !text.text.hasPrefix("[app=") || body != text.text else { continue }
            excerpts.append(Hit(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                windowTitle: hit.windowTitle, url: hit.url, ocrTextSnippet: body,
                source: hit.source, score: hit.score, entities: hit.entities,
                linkedEventIds: hit.linkedEventIds, thumbnailPath: hit.thumbnailPath, sourceKind: hit.sourceKind))
        }
        // Text reads are separate from metadata reads; reject deletion or replacement during either.
        let rechecked = try await reader.fetchEventsByIds(excerpts.map(\.id))
        guard request == generation, day == selectedDay, canExportSummary, !Task.isCancelled else {
            throw CancellationError()
        }
        let currentIDs = Set(rechecked.filter { hits.contains($0) }.map(\.id))
        excerpts.removeAll { !currentIDs.contains($0.id) }
        guard !excerpts.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return VisualMemoryExport.dailyHandoff(day: selectedDay, hits: excerpts, requestedCount: ids.count)
    }

    public func prepareHandoff() async throws {
        handoffPreview = nil
        handoffPreview = try await exportSummary()
    }

    /// Recheck immediately before the UI writes to the clipboard or a user-selected file.
    public func validatedHandoff() async throws -> String {
        guard let preview = handoffPreview else { throw CancellationError() }
        let fresh: String
        do { fresh = try await exportSummary() }
        catch { handoffPreview = nil; throw error }
        handoffPreview = fresh
        guard fresh == preview else { throw DailyHandoffError.evidenceChanged }
        return fresh
    }
    public var visibleScreenshots: [TimelineEvent] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return screenshots }
        return searchHits.map {
            TimelineEvent(eventId: $0.id, tsUs: $0.tsUs, appBundleId: $0.appBundleId,
                          snippet: Formatters.stripContextHeader($0.ocrTextSnippet),
                          thumbnailPath: $0.thumbnailPath, sourceKind: $0.sourceKind)
        }
    }

    public func moveDay(_ amount: Int) {
        if let date = calendar.date(byAdding: .day, value: amount, to: selectedDate) {
            selectedDate = date
        }
    }

    public func openLatestBrief() async {
        briefNavigationGeneration += 1
        let request = briefNavigationGeneration
        showsSavedDraft = false
        do {
            let latest = try await reader.latestBrief()
            guard request == briefNavigationGeneration, !Task.isCancelled else { return }
            guard let latest else {
                briefError = "No saved draft is available."
                return
            }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: latest.dateLocal),
                  formatter.string(from: date) == latest.dateLocal else {
                briefError = "The latest draft has an invalid date."
                return
            }
            selectedDate = date
            let navigation = briefNavigationGeneration
            await reload(force: true)
            guard navigation == briefNavigationGeneration, day.dateLocal == latest.dateLocal,
                  !Task.isCancelled else { return }
            showsSavedDraft = brief?.dateLocal == latest.dateLocal
            if brief == nil && briefError == nil { briefError = "The latest saved draft is no longer available." }
        } catch {
            guard request == briefNavigationGeneration, !Task.isCancelled else { return }
            briefError = "The latest saved draft could not be read."
        }
    }

    public func reload(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let requestedDay = day
        // Coalesce timer/manual requests for the same day while allowing navigation to supersede them.
        guard force || !isLoading || loadedDay != requestedDay else { return }
        generation += 1
        let request = generation
        latestContextText = nil
        if loadedDay != requestedDay {
            activitySummary = nil
            activityStatus = nil
            events = []
            searchHits = []
            brief = nil
            refreshedAt = nil
        }
        loadedDay = requestedDay
        isLoading = true
        errorMessage = nil
        briefError = nil
        defer { if request == generation { isLoading = false } }

        async let receipt = healthLoader()
        do {
            let rows = try await reader.timelineEvents(startTsUs: requestedDay.startUs,
                                                       endTsUs: requestedDay.endUs, resolution: .minute)
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            let refreshed = DailyReview(day: requestedDay, events: rows).events
            if events != refreshed { handoffPreview = nil }
            events = refreshed
            refreshedAt = Date()
        } catch {
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            events = []
            handoffPreview = nil
            errorMessage = "This day's memory could not be read. Try refreshing."
        }
        if let latest = events.last {
            // Preview hydration is optional; its failure must not discard the day's samples or brief.
            let text = try? await loadLatestContext(latest, day: requestedDay, request: request)
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            latestContextText = text
        }
        do {
            let savedBrief = try await reader.briefForDate(requestedDay.dateLocal)
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            brief = savedBrief?.dateLocal == requestedDay.dateLocal ? savedBrief : nil
        } catch {
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            brief = nil
            briefError = "The saved brief could not be read."
        }
        let health = await receipt
        guard request == generation, day == requestedDay, !Task.isCancelled else { return }
        captureHealth = health
        await reloadActivity(day: requestedDay, request: request)
        guard request == generation, day == requestedDay, !Task.isCancelled else { return }
        await search()
    }

    private func reloadActivity(day requestedDay: MemoryDay, request: Int) async {
        let endUs = min(requestedDay.endUs + 1, UInt64(max(0, now().timeIntervalSince1970 * 1_000_000)))
        guard endUs > requestedDay.startUs else {
            activitySummary = nil
            activityStatus = "No measured input for this window"
            return
        }
        do {
            let page = try await reader.activityIntervals(startUs: requestedDay.startUs, endUs: endUs, limit: 50_000)
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            activitySummary = ActivitySummary(page: page, startUs: requestedDay.startUs, endUs: endUs)
            activityStatus = nil
            if page.truncated {
                activityStatus = "Measured input is incomplete"
            } else if page.intervals.isEmpty {
                activityStatus = "No measured input for this window"
            } else if activitySummary == nil {
                activityStatus = "Measured input could not be reconciled"
            }
        } catch {
            guard request == generation, day == requestedDay, !Task.isCancelled else { return }
            activitySummary = nil
            activityStatus = "Measured input unavailable"
        }
    }

    private func loadLatestContext(_ event: TimelineEvent, day requestedDay: MemoryDay,
                                   request: Int) async throws -> EventText? {
        let fetched = try await reader.fetchEventsByIds([event.id])
        guard request == generation, day == requestedDay, !Task.isCancelled else { return nil }
        guard let hit = fetched.first(where: { event.matches($0) && requestedDay.contains($0.tsUs) }) else {
            return nil
        }
        let text = try await reader.eventText(eventId: event.id)
        guard request == generation, day == requestedDay, !Task.isCancelled else { return nil }
        guard let text, text.matches(hit) else { return nil }
        // Text and authority reads are separate; reject deletion or replacement during hydration.
        let rechecked = try await reader.fetchEventsByIds([event.id])
        guard request == generation, day == requestedDay, !Task.isCancelled,
              rechecked.contains(hit) else { return nil }
        return text
    }

    public func search() async {
        searchGeneration += 1
        let request = searchGeneration
        let requestedDay = day
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        guard !text.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        defer { if request == searchGeneration { isSearching = false } }
        do {
            let hits = try await reader.search(SearchOptions(text: text, limit: 200,
                                                             timeFromUs: requestedDay.startUs,
                                                             timeToUs: requestedDay.endUs))
            guard request == searchGeneration, day == requestedDay,
                  text == query.trimmingCharacters(in: .whitespacesAndNewlines), !Task.isCancelled else { return }
            searchHits = MCI.Workspace.recentKeyframes(from: hits).filter { requestedDay.contains($0.tsUs) }
                .sorted { $0.tsUs < $1.tsUs }
        } catch {
            guard request == searchGeneration, day == requestedDay,
                  text == query.trimmingCharacters(in: .whitespacesAndNewlines), !Task.isCancelled else { return }
            searchHits = []
            searchError = "Screenshot search is unavailable. Try again."
        }
    }
}
