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
    @State private var searchFocus = false
    @StateObject private var dailyModel: DailyMemoryViewModel
    @StateObject private var searchModel: SearchViewModel

    init(configuration: NativePreviewConfiguration) {
        let reader = NativePreviewReader(date: PreviewUnderstandingReader.sampleNow,
                                         now: PreviewUnderstandingReader.sampleNow,
                                         calendar: PreviewUnderstandingReader.sampleCalendar,
                                         scenario: configuration.scenario)
        self.reader = reader
        understanding = PreviewUnderstandingReader(
            scenario: PreviewUnderstandingReader.Scenario(rawValue: configuration.scenario.rawValue) ?? .populated)
        _selection = State(initialValue: MemoryWorkspaceSelection(initialTab: configuration.tab))
        _dailyModel = StateObject(wrappedValue: DailyMemoryViewModel(reader: reader, selectedDate: reader.date,
            calendar: reader.calendar, healthLoader: { nil }, now: { reader.now }))
        let search = SearchViewModel(reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: PreviewQueryStore()),
            userDictionaryLoader: { .empty })
        search.query = configuration.query
        _searchModel = StateObject(wrappedValue: search)
    }

    var body: some View {
        MemoryWorkspaceView(reader: reader, understanding: understanding, selection: $selection,
            searchFocusTrigger: searchFocus,
            dailyModel: dailyModel, searchModel: searchModel, isSyntheticPreview: true,
            contextExporter: { query in
                let hits = try await reader.search(SearchOptions(text: query, mode: .text))
                return VisualMemoryExport.markdown(title: "Synthetic preview", hits: hits)
            })
            .toolbar { Text("Synthetic preview").font(.caption).foregroundStyle(.secondary) }
            .focusable(true, interactions: .automatic)
            .onKeyPress(keys: ["1", "2", "3", "4"], phases: .down) { press in
                guard press.modifiers == .command,
                      let destination = MemoryWorkspaceSelection(keyboardShortcut: press.key.character) else { return .ignored }
                selection = destination
                return .handled
            }
            .onKeyPress("f", phases: .down) { press in
                guard press.modifiers == .command else { return .ignored }
                selection = .search
                searchFocus.toggle()
                return .handled
            }
            .preferredColorScheme(.light)
            .frame(minWidth: 720, minHeight: 440)
    }
}

private final class PreviewQueryStore: KeyValueStore, Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
#endif
