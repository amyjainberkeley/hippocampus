import AppKit
import RecallUIKit
import SwiftUI

enum MemoryWorkspaceSelection: String, CaseIterable, Identifiable {
    case now
    case search
    case timeline
    case episodes
    case sources
    case privacy
    case settings

    var id: String { rawValue }

    init(initialTab: RecallTab) {
        switch initialTab.workspaceTab {
        case .now, .brief:
            self = .now
        case .search:
            self = .search
        case .timeline, .timelineStrip:
            self = .timeline
        case .episodes:
            self = .episodes
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
    var latestBriefRequest: UUID? = nil
    var dailyModel: DailyMemoryViewModel? = nil
    var searchModel: SearchViewModel? = nil
    var isSyntheticPreview = false
    var contextExporter: @Sendable (String) async throws -> String = { try await ContextHandoffExporter.export(focus: $0) }

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var historyExpanded = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            workspaceDetail
        }
        .background(Color.brandBgPrimary)
        .onChange(of: selection) { _, destination in
            if destination == .episodes { historyExpanded = true }
        }
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
                    if item == .timeline {
                        DisclosureGroup(isExpanded: $historyExpanded) {
                            MemorySidebarRow(item: .episodes)
                                .tag(MemoryWorkspaceSelection.episodes)
                        } label: {
                            MemorySidebarRow(item: item)
                        }
                        .tag(item)
                    } else {
                        MemorySidebarRow(item: item)
                            .tag(item)
                    }
                }
            }

            Section("Workspace") {
                ForEach(MemoryWorkspaceSelection.secondary) { item in
                    MemorySidebarRow(item: item)
                        .tag(item)
                        .disabled(isSyntheticPreview)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
    }

    // Daily review, query results, chronological history, and grouped sessions.
    @ViewBuilder
    private var workspaceDetail: some View {
        Group {
            if isSyntheticPreview && MemoryWorkspaceSelection.secondary.contains(selection) {
                ContentUnavailableView("Synthetic preview", systemImage: "eye")
            } else {
            switch selection {
            case .now:
                DailyMemoryView(reader: reader, onOpenPrivacy: { selection = .privacy }, latestBriefRequest: latestBriefRequest, model: dailyModel)
            case .search:
                SearchView(
                    viewModel: searchModel ?? SearchViewModel(reader: reader),
                    focusTrigger: searchFocusTrigger,
                    focusRequest: focusRequest,
                    reader: reader,
                    contextExporter: contextExporter
                )
            case .timeline, .episodes:
                HistoryWorkspaceView(reader: reader, selection: $selection)
            case .sources:
                SourcesWorkspaceView(reader: reader)
            case .privacy:
                PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
            case .settings:
                WorkspaceSettingsView()
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandBgPrimary)
        .navigationTitle(selection == .episodes ? "History" : selection.descriptor.title)
    }
}

private extension MemoryWorkspaceSelection {
    static let primary: [MemoryWorkspaceSelection] = [.now, .search, .timeline]
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

private struct HistoryWorkspaceView: View {
    let reader: BrainReader
    @Binding var selection: MemoryWorkspaceSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("History view", selection: $selection) {
                    Text("Evidence").tag(MemoryWorkspaceSelection.timeline)
                    Text("Sessions").tag(MemoryWorkspaceSelection.episodes)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if selection == .episodes {
                EpisodesView(viewModel: EpisodesViewModel(reader: reader), reader: reader)
            } else {
                TimelineView(viewModel: TimelineViewModel(reader: reader), reader: reader)
            }
        }
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
