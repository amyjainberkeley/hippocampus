import AppKit
import RecallUIKit
import SwiftUI

enum MemoryWorkspaceSelection: String, CaseIterable, Identifiable {
    case now
    case search
    case timeline
    case episodes
    case briefs
    case sources
    case privacy
    case settings

    var id: String { rawValue }

    init(initialTab: RecallTab) {
        switch initialTab {
        case .now:
            self = .now
        case .search:
            self = .search
        case .timeline, .timelineStrip:
            self = .timeline
        case .episodes:
            self = .episodes
        case .brief:
            self = .briefs
        case .privacy, .privacyDashboard:
            self = .privacy
        case .settings:
            self = .settings
        }
    }

    var descriptor: MCI.Workspace.Destination {
        MCI.Workspace.allDestinations.first { $0.id == rawValue }
            ?? MCI.Workspace.primaryDestinations[0]
    }

    var keyboardShortcutLabel: String {
        descriptor.keyboardShortcut
    }

    init?(keyboardShortcut: Character) {
        guard
            let destination = MCI.Workspace.destination(
                forKeyboardShortcut: String(keyboardShortcut)
            ),
            let selection = Self(rawValue: destination.id)
        else {
            return nil
        }
        self = selection
    }
}

struct MemoryWorkspaceView: View {
    let reader: BrainReader
    @Binding var selection: MemoryWorkspaceSelection
    var searchFocusTrigger: Bool
    var focusRequest: RecallFocusRequest? = nil

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            workspaceDetail
        }
        .background(Color.brandBgPrimary)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            MemoryRefreshSignal.post()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                MemoryRefreshSignal.post()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Memory") {
                ForEach(MemoryWorkspaceSelection.primary) { item in
                    MemorySidebarRow(item: item)
                        .tag(item)
                }
            }

            Section("Workspace") {
                ForEach(MemoryWorkspaceSelection.secondary) { item in
                    MemorySidebarRow(item: item)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
    }

    // Now: overview; Search: query-only; Timeline: chronological evidence;
    // Episodes: grouped evidence; Briefs: daily overview. Each owns its content.
    @ViewBuilder
    private var workspaceDetail: some View {
        Group {
            switch selection {
            case .now:
                DailyMemoryView(reader: reader, onOpenPrivacy: { selection = .privacy })
            case .search:
                SearchView(
                    viewModel: SearchViewModel(reader: reader),
                    focusTrigger: searchFocusTrigger,
                    focusRequest: focusRequest,
                    reader: reader
                )
            case .timeline:
                TimelineView(viewModel: TimelineViewModel(reader: reader), reader: reader)
            case .episodes:
                EpisodesView(viewModel: EpisodesViewModel(reader: reader), reader: reader)
            case .briefs:
                BriefView(
                    viewModel: BriefViewModel(
                        reader: reader,
                        captureCoverage: .unknown
                    ),
                    reader: reader
                )
            case .sources:
                SourcesWorkspaceView(reader: reader)
            case .privacy:
                PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
            case .settings:
                WorkspaceSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandBgPrimary)
        .navigationTitle(selection.descriptor.title)
    }
}

private extension MemoryWorkspaceSelection {
    static let primary: [MemoryWorkspaceSelection] = [.now, .search, .timeline, .episodes, .briefs]
    static let secondary: [MemoryWorkspaceSelection] = [.sources, .privacy, .settings]
}

private struct MemorySidebarRow: View {
    let item: MemoryWorkspaceSelection

    var body: some View {
        // The selectable List row owns keyboard focus and selection appearance.
        Label(item.descriptor.title, systemImage: item.descriptor.systemImage)
            .mciFont(.body)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.descriptor.title)
    }
}

private struct SourcesWorkspaceView: View {
    let reader: BrainReader
    @State private var observedApps: [ObservedApp] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Observed apps").font(.headline)
                Spacer()
                WorkspacePreferencesButton(title: "App access", systemImage: "display", destination: .capture)
                WorkspacePreferencesButton(title: "AI context", systemImage: "point.3.connected.trianglepath.dotted", destination: .sources)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 24).padding(.top, 20)
            if isLoading && observedApps.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Sources are unavailable",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(errorMessage)
                )
                .foregroundStyle(Color.brandError)
            } else if observedApps.isEmpty {
                ContentUnavailableView(
                    "No sources yet",
                    systemImage: "link.badge.plus",
                    description: Text("Sources appear after permitted applications add events to memory.")
                )
                .foregroundStyle(Color.brandFgSecondary)
            } else {
                List(observedApps) { app in
                    HStack(spacing: MCI.Spacing.m) {
                        Image(systemName: "app")
                            .foregroundStyle(Color.brandFgSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                            Text(Formatters.appDisplayName(app.appBundleId))
                                .mciFont(.bodyStrong)
                                .foregroundStyle(Color.brandFgPrimary)
                            Text(app.appBundleId)
                                .font(MCI.Font.mono)
                                .foregroundStyle(Color.brandFgMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(app.count) events")
                            .mciFont(.caption)
                            .foregroundStyle(Color.brandFgSecondary)
                    }
                    .padding(.vertical, MCI.Spacing.s)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.brandBgPrimary)
        .refreshable { await load() }
        .task {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            observedApps = try await reader.listObservedApps(limit: 100, timeFromUs: nil)
            errorMessage = nil
        } catch {
            observedApps = []
            errorMessage = UserFacingCopy.memoryUnreachableBody
        }
    }

}
