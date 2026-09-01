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
        let all = MCI.Workspace.primaryDestinations + MCI.Workspace.secondaryDestinations
        return all.first { $0.id == rawValue } ?? MCI.Workspace.primaryDestinations[0]
    }

    var keyboardShortcutLabel: String {
        switch self {
        case .now: return "1"
        case .search: return "2"
        case .timeline: return "3"
        case .episodes: return "4"
        case .briefs: return "5"
        case .sources: return "6"
        case .privacy: return "7"
        case .settings: return "8"
        }
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
        .safeAreaInset(edge: .bottom) {
            CaptureStatusFooter()
                .padding(.horizontal, MCI.Spacing.m)
                .padding(.vertical, MCI.Spacing.s)
                .background(.regularMaterial)
        }
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
                            hasFullDayCapture: true
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

private struct CaptureStatusFooter: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "record.circle")
                .foregroundStyle(Color.brandChange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture status")
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgPrimary)
                Text("Controlled by Hippocampus")
                    .font(MCI.Font.footnote)
                    .foregroundStyle(Color.brandFgMuted)
            }
            Spacer(minLength: MCI.Spacing.s)
        }
        .padding(MCI.Spacing.s)
        .background(reduceTransparency ? Color.brandBgSecondary : Color.brandBgElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
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
                Text(statusLabel)
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
                Label("No visual evidence yet", systemImage: "photo.on.rectangle.angled")
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

    private var statusLabel: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        return "\(hits.count) sources"
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            errorMessage = nil
            hits = try await reader.recentEvents(limit: 12)
                .filter { $0.thumbnailPath != nil || !$0.ocrTextSnippet.isEmpty }
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
            HitThumbnail(url: hit.thumbnailURL)
                .frame(width: 76, height: 48)
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
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: MCI.Spacing.l)],
                    alignment: .leading,
                    spacing: MCI.Spacing.l
                ) {
                    StatusPanel(
                        title: "Capture",
                        value: captureValue,
                        detail: "Visible controls remain in the menu bar.",
                        systemImage: "record.circle",
                        tint: Color.brandChange
                    )
                    StatusPanel(
                        title: "Evidence",
                        value: evidenceValue,
                        detail: "Source-backed recall is read-only here.",
                        systemImage: "externaldrive",
                        tint: Color.brandMint
                    )
                    StatusPanel(
                        title: "Brief",
                        value: latestBrief?.dateLocal ?? "No brief",
                        detail: latestBrief?.title ?? "Daily briefs appear after capture.",
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

    private var captureValue: String {
        guard let summary else { return "Ready" }
        return summary.totalEvents > 0 ? "On record" : "Ready"
    }

    private var evidenceValue: String {
        guard let summary else { return "No events" }
        return "\(summary.totalEvents) events"
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

private struct StatusPanel: View {
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
                    description: Text("Sources appear after permitted applications produce evidence.")
                )
                .foregroundStyle(Color.brandFgSecondary)
            } else {
                List(observedApps) { app in
                    HStack(spacing: MCI.Spacing.m) {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(Color.brandMintDim)
                        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                            Text(displayName(app.appBundleId))
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

    private func displayName(_ bundleId: String) -> String {
        guard let last = bundleId.split(separator: ".").last, !last.isEmpty else {
            return bundleId
        }
        return String(last)
    }
}
