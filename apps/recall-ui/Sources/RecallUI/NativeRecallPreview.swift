#if DEBUG
import RecallUIKit
import SwiftUI

/// Uses the shipping views with synthetic readers; never starts the production app services.
struct NativeRecallPreview: View {
    private let reader: NativePreviewReader
    @State private var selection: MemoryWorkspaceSelection
    @State private var searchFocus = false
    @StateObject private var dailyModel: DailyMemoryViewModel
    @StateObject private var searchModel: SearchViewModel

    init(configuration: NativePreviewConfiguration) {
        let reader = NativePreviewReader(scenario: configuration.scenario)
        self.reader = reader
        _selection = State(initialValue: MemoryWorkspaceSelection(initialTab: configuration.tab))
        _dailyModel = StateObject(wrappedValue: DailyMemoryViewModel(reader: reader, selectedDate: reader.date,
            healthLoader: { nil }, now: { reader.now }))
        let search = SearchViewModel(reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: PreviewQueryStore()),
            userDictionaryLoader: { .empty })
        search.query = configuration.query
        _searchModel = StateObject(wrappedValue: search)
    }

    var body: some View {
        MemoryWorkspaceView(reader: reader, selection: $selection, searchFocusTrigger: searchFocus,
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
