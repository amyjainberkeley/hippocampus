#if DEBUG
import RecallUIKit
import SwiftUI

/// Uses the shipping views with synthetic readers; never starts the production app services.
/// Every reader here is a fixture: the moments are `NativePreviewReader`'s and what
/// the agent would say about them is `PreviewUnderstandingReader`'s, both on the
/// samples' Monday in their time zone, so the two describe one day.
struct NativeRecallPreview: View {
    private let reader: NativePreviewReader
    private let understanding: PreviewUnderstandingReader
    @State private var selection: MemoryWorkspaceSelection
    @StateObject private var ask: AskViewModel

    init(configuration: NativePreviewConfiguration) {
        let reader = NativePreviewReader(date: PreviewUnderstandingReader.sampleNow,
                                         now: PreviewUnderstandingReader.sampleNow,
                                         calendar: PreviewUnderstandingReader.sampleCalendar,
                                         scenario: configuration.scenario)
        self.reader = reader
        let understanding = PreviewUnderstandingReader(
            scenario: PreviewUnderstandingReader.Scenario(rawValue: configuration.scenario.rawValue) ?? .populated)
        self.understanding = understanding
        _selection = State(initialValue: MemoryWorkspaceSelection(initialTab: configuration.tab))
        _ask = StateObject(wrappedValue: Self.makeAsk(reader: reader, understanding: understanding,
                                                      query: configuration.query))
    }

    /// Ask over the fixtures, with nothing kept on disk and no names file read.
    @MainActor
    static func makeAsk(reader: NativePreviewReader, understanding: UnderstandingReader, query: String = "") -> AskViewModel {
        let now = reader.now
        let search = SearchViewModel(reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: PreviewQueryStore()),
            userDictionaryLoader: { .empty })
        search.query = query
        return AskViewModel(
            search: search,
            history: TimelineViewModel(reader: reader, pageSize: 200,
                                       day: MemoryDay(date: now, calendar: reader.calendar), now: { now }),
            understanding: understanding,
            calendar: reader.calendar
        )
    }

    var body: some View {
        let reader = self.reader
        let now = reader.now
        MemoryWorkspaceView(reader: reader, understanding: understanding, selection: $selection,
            isSyntheticPreview: true,
            healthLoader: { nil },
            contextExporter: { query in
                let hits = try await reader.search(SearchOptions(text: query, mode: .text))
                return VisualMemoryExport.markdown(title: "Example", hits: hits)
            },
            calendar: reader.calendar,
            now: { now },
            ask: ask)
            .preferredColorScheme(.light)
            .frame(minWidth: 760, minHeight: 480)
    }
}

private final class PreviewQueryStore: KeyValueStore, Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
#endif
