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
                .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 300)
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
        GeometryReader { geometry in
            let filmstripHeight = MCI.Workspace.evidenceFilmstripHeight(
                availableHeight: geometry.size.height
            )
            VStack(spacing: 0) {
                if selection != .now {
                    WorkspaceFilmstrip(
                        reader: reader,
                        isCompact: filmstripHeight < 200
                    )
                    .frame(height: filmstripHeight)
                    Divider().overlay(Color.brandCardBorder)
                }

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
                            )
                        )
                    case .sources:
                        SourcesWorkspaceView(reader: reader)
                    case .privacy:
                        PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
                    case .settings:
                        UserDictionaryEditor()
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
    let isCompact: Bool
    @State private var hits: [Hit] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedHit: Hit?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .center, spacing: MCI.Spacing.l) {
            VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
                Label("Recent evidence", systemImage: "photo.on.rectangle.angled")
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                Text(countLabel)
                    .mciFont(.caption)
                    .foregroundStyle(Color.brandFgMuted)
            }
            .frame(width: isCompact ? 164 : 176, alignment: .leading)

            if isLoading && hits.isEmpty {
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
                            Button {
                                selectedHit = hit
                            } label: {
                                FilmstripCard(hit: hit, isCompact: isCompact)
                            }
                            .buttonStyle(.plain)
                            .help("Inspect source evidence")
                        }
                    }
                    .padding(.vertical, MCI.Spacing.s)
                }
            }
        }
        .padding(.horizontal, MCI.Spacing.xl)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color.brandBgSecondary)
                : AnyShapeStyle(.ultraThinMaterial)
        )
        .sheet(item: $selectedHit) { hit in
            ScreenshotViewer(selection: ScreenshotSelection(eventIDs: hits.map(\.id), initialID: hit.id), reader: reader)
        }
        .task {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await load() }
        }
    }

    private var countLabel: String {
        if isLoading { return "Loading" }
        if errorMessage != nil { return "Unavailable" }
        return MCI.Workspace.keyframeCountLabel(hits.count)
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            errorMessage = nil
            let events = try await reader.recentEvents(limit: 500)
            hits = Array(MCI.Workspace.recentKeyframes(from: events).prefix(12))
        } catch {
            hits = []
            errorMessage = "Memory unavailable"
        }
    }
}

private struct FilmstripCard: View {
    let hit: Hit
    let isCompact: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
            EvidenceThumbnail(
                url: hit.thumbnailURL,
                size: thumbnailSize,
                maxPixelSize: isCompact ? 300 : 384
            )
            HStack(spacing: MCI.Spacing.xs) {
                Text(Formatters.relativeTime(usSinceEpoch: hit.tsUs))
                    .font(MCI.Font.mono)
                    .foregroundStyle(Color.brandMint)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.brandFgMuted)
            }
            if !isCompact {
                Text(Formatters.contextLine(hit))
                    .font(MCI.Font.footnote)
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(Formatters.evidenceSummary(hit))
                .mciFont(.caption)
                .foregroundStyle(Color.brandFgSecondary)
                .lineLimit(isCompact ? 1 : 2)
        }
        .frame(
            width: isCompact ? 120 : 152,
            height: isCompact ? 104 : 154,
            alignment: .topLeading
        )
        .padding(MCI.Spacing.s)
        .background(
            isHovered
                ? Color.brandBgElevated.opacity(0.96)
                : Color.brandCardBg.opacity(0.54)
        )
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                .stroke(
                    isHovered ? Color.brandMintDim.opacity(0.55) : Color.brandCardBorder,
                    lineWidth: 0.5
                )
        }
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: 8, y: 3)
        .scaleEffect(isHovered ? 1.01 : 1)
        .onHover { isHovered = $0 }
        .animation(MCI.Motion.snap, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Formatters.contextLine(hit))
        .accessibilityHint("Opens the source evidence")
    }

    private var thumbnailSize: CGSize {
        if isCompact {
            return CGSize(width: 120, height: 68)
        }
        return CGSize(width: 152, height: 86)
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
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await load() }
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
