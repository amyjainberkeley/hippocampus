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
        case .chat:
            self = .now
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
    var onRequestModelDownload: () -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 300)
        } detail: {
            workspaceDetail
        }
        .background(Color.brandBgPrimary)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(MCI.Motion.snap) {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Show or hide sidebar")
                .accessibilityLabel("Show or hide sidebar")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Memory") {
                ForEach(MemoryWorkspaceSelection.primary) { item in
                    MemorySidebarRow(item: item, isSelected: selection == item)
                        .tag(item)
                }
            }

            Section("Workspace") {
                ForEach(MemoryWorkspaceSelection.secondary) { item in
                    MemorySidebarRow(item: item, isSelected: selection == item)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        VStack(spacing: 0) {
            WorkspaceFilmstrip(reader: reader)
                .frame(minHeight: 92, idealHeight: 112, maxHeight: 128)
            Divider().overlay(Color.brandCardBorder)

            Group {
                switch selection {
                case .now:
                    NowWorkspaceView(reader: reader)
                case .search:
                    SearchView(
                        viewModel: SearchViewModel(reader: reader),
                        focusTrigger: searchFocusTrigger,
                        reader: reader
                    )
                case .timeline:
                    TimelineView(viewModel: TimelineViewModel(reader: reader), reader: reader)
                case .episodes:
                    EpisodesView(viewModel: EpisodesViewModel(reader: reader))
                case .briefs:
                    BriefView(
                        viewModel: BriefViewModel(
                            reader: reader,
                            isModelPresentProbe: {
                                ModelPresenceProbe.isBriefModelInstalled()
                            },
                            captureCoverage: .unknown
                        ),
                        onRequestModelDownload: onRequestModelDownload
                    )
                case .sources:
                    SourcesWorkspaceView(reader: reader)
                case .privacy:
                    PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
                case .settings:
                    UserDictionaryEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: item.descriptor.systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.brandMint : Color.brandFgSecondary)
            Text(item.descriptor.title)
                .mciFont(.bodyStrong)
            Spacer(minLength: MCI.Spacing.s)
            Text(item.keyboardShortcutLabel)
                .font(MCI.Font.mono)
                .foregroundStyle(Color.brandFgMuted)
        }
        .padding(.horizontal, MCI.Spacing.s)
        .padding(.vertical, MCI.Spacing.s - 2)
        .foregroundStyle(isSelected ? Color.brandFgPrimary : Color.brandFgSecondary)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.s, style: .continuous))
        .contentShape(Rectangle())
        .focusable()
        .onHover { isHovered = $0 }
        .animation(MCI.Motion.snap, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.descriptor.title)
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.brandMintSubtle)
        }
        if isHovered {
            return AnyShapeStyle(Color.brandBgElevated.opacity(0.7))
        }
        return AnyShapeStyle(Color.clear)
    }
}

private struct WorkspaceFilmstrip: View {
    let reader: BrainReader
    @State private var hits: [Hit] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: MCI.Spacing.m) {
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                Text("Recent keyframes")
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgSecondary)
                Text(countLabel)
                    .font(MCI.Font.mono)
                    .foregroundStyle(Color.brandFgMuted)
            }
            .frame(width: 132, alignment: .leading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if hits.isEmpty {
                Label("No recent keyframes", systemImage: "photo.on.rectangle.angled")
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MCI.Spacing.s) {
                        ForEach(hits) { hit in
                            FilmstripCard(hit: hit)
                        }
                    }
                    .padding(.vertical, MCI.Spacing.s)
                }
            }
        }
        .padding(.horizontal, MCI.Spacing.l)
        .background(reduceTransparency ? AnyShapeStyle(Color.brandBgPrimary) : AnyShapeStyle(.regularMaterial))
        .task {
            await load()
        }
    }

    private var countLabel: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        return MCI.Workspace.keyframeCountLabel(hits.count)
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            errorMessage = nil
            let events = try await reader.recentEvents(limit: 48)
            hits = Array(MCI.Workspace.recentKeyframes(from: events).prefix(12))
        } catch {
            hits = []
            errorMessage = "Memory unavailable"
        }
    }
}

private struct FilmstripCard: View {
    let hit: Hit
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
            EvidenceThumbnail(
                url: hit.thumbnailURL,
                size: CGSize(width: 76, height: 48),
                maxPixelSize: 192
            )
            Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                .font(MCI.Font.mono)
                .foregroundStyle(Color.brandMint)
            Text(Formatters.contextLine(hit))
                .font(MCI.Font.footnote)
                .foregroundStyle(Color.brandFgSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 96, alignment: .leading)
        .padding(MCI.Spacing.s)
        .background(isHovered ? Color.brandBgElevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(MCI.Motion.snap, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Formatters.contextLine(hit))
    }
}

private struct NowWorkspaceView: View {
    let reader: BrainReader
    @State private var summary: SummaryStats?
    @State private var latestBrief: Brief?
    @State private var recentHits: [Hit] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        let storedEvents = summary.map(MCI.Workspace.historicalEventMetric(for:))

        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: MCI.Spacing.l)],
                    alignment: .leading,
                    spacing: MCI.Spacing.l
                ) {
                    MetricPanel(
                        title: storedEvents?.title ?? "Stored events",
                        value: historicalEventValue,
                        detail: storedEvents?.detail ?? "Historical memory rows",
                        systemImage: "tray.full",
                        tint: Color.brandMint
                    )
                    MetricPanel(
                        title: "Recent events",
                        value: recentEventValue,
                        detail: "Latest rows returned from memory",
                        systemImage: "clock.arrow.circlepath",
                        tint: Color.brandFgSecondary
                    )
                    MetricPanel(
                        title: "Brief",
                        value: briefValue,
                        detail: briefDetail,
                        systemImage: "doc.text",
                        tint: Color.brandFgSecondary
                    )
                }

                if isLoading {
                    ShimmerLoadingView(isLoading: true)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Memory is unavailable",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(errorMessage)
                    )
                    .foregroundStyle(Color.brandError)
                } else if recentHits.isEmpty {
                    MCIEmptyState.noTimelineEvents()
                } else {
                    VStack(alignment: .leading, spacing: MCI.Spacing.s) {
                        Text("What happened most recently")
                            .mciFont(.title2)
                            .foregroundStyle(Color.brandFgPrimary)
                        ForEach(recentHits.prefix(5)) { hit in
                            HitRow(hit: hit)
                                .padding(.horizontal, MCI.Spacing.m)
                                .background(Color.brandCardBg)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                                        .stroke(Color.brandCardBorder, lineWidth: 0.5)
                                )
                        }
                    }
                }
            }
            .padding(MCI.Spacing.xl)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color.brandBgPrimary)
        .refreshable { await load() }
        .task {
            await load()
        }
    }

    private var historicalEventValue: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        guard let summary else { return "Unknown" }
        return MCI.Workspace.historicalEventMetric(for: summary).value
    }

    private var recentEventValue: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        return "\(recentHits.count)"
    }

    private var briefValue: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        return latestBrief?.dateLocal ?? "None saved"
    }

    private var briefDetail: String {
        if isLoading { return "Reading saved briefs" }
        if errorMessage != nil { return "Brief memory could not be read" }
        return latestBrief?.title ?? "No saved brief in memory"
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let stats = reader.summaryStats()
            async let brief = reader.latestBrief()
            async let hits = reader.recentEvents(limit: 8)
            summary = try await stats
            latestBrief = try await brief
            recentHits = try await hits
            errorMessage = nil
        } catch {
            summary = nil
            latestBrief = nil
            recentHits = []
            errorMessage = UserFacingCopy.memoryUnreachableBody
        }
    }
}

private struct MetricPanel: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgSecondary)
            }
            Text(value)
                .mciFont(.title2)
                .foregroundStyle(Color.brandFgPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .mciFont(.caption)
                .foregroundStyle(Color.brandFgMuted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(MCI.Spacing.l)
        .background(Color.brandCardBg)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
    }
}

private struct SourcesWorkspaceView: View {
    let reader: BrainReader
    @State private var observedApps: [ObservedApp] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ShimmerLoadingView(isLoading: true)
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
                        Image(systemName: "app.dashed")
                            .foregroundStyle(Color.brandMintDim)
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
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.brandBgPrimary)
        .refreshable { await load() }
        .task {
            await load()
        }
    }

    @MainActor
    private func load() async {
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
