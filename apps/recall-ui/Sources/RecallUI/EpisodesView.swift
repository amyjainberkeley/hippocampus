import AppKit
import RecallUIKit
import SwiftUI

/// Episodes tab — renders the rows produced by `core/brain::
/// episode_segmenter` (ADR-0010). An episode is a contiguous run of
/// events in the same app, broken by app change or a 10-minute gap.
///
/// Read-only view — never mutates the brain. Lists episode rows sorted
/// by start-time DESC; each card shows the app, the time window, the
/// duration, and the event count for that segment.
struct EpisodesView: View {
    @StateObject var viewModel: EpisodesViewModel
    var reader: BrainReader? = nil

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                EvidenceStateViewport { errorView(err) }
            } else if viewModel.isLoading && viewModel.episodes.isEmpty {
                EvidenceStateViewport { ShimmerLoadingView(isLoading: true) }
            } else if viewModel.episodes.isEmpty {
                EvidenceStateViewport { emptyView }
            } else {
                contentView
            }
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await viewModel.reload() }
        }
    }

    private var emptyView: some View {
        // Cycle 8.49 polished empty state (audit-gap fix).
        MCIEmptyState.noEpisodes()
    }

    private func errorView(_ err: String) -> some View {
        // Cycle 8.54 copy audit — `err` intentionally unused for
        // display; kept as a param for future logging hooks.
        _ = err
        return VStack(spacing: 16) {
            ContentUnavailableView(
                UserFacingCopy.memoryUnreachableTitle,
                systemImage: "exclamationmark.triangle.fill",
                description: Text(UserFacingCopy.memoryUnreachableBody)
            )
            .foregroundStyle(Color.brandError)

            Button(UserFacingCopy.openHippocampusAction) {
                let appPath = NSHomeDirectory() + "/Applications/Hippocampus.app"
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            }
            .buttonStyle(.bordered)
            .tint(Color.brandMint)
        }
    }

    private var contentView: some View {
        AdaptiveEvidencePanes(
            showsDetail: viewModel.selectedEpisode != nil && reader != nil,
            backLabel: "Back to sessions",
            onDismissDetail: { viewModel.selectedEpisodeId = nil }
        ) {
            episodeList
        } detail: {
            if let episode = viewModel.selectedEpisode, let reader {
                EpisodeEvidencePanel(episode: episode, reader: reader)
                    .id(episode.id)
            }
        }
    }

    private var episodeList: some View {
        List(viewModel.episodes, selection: $viewModel.selectedEpisodeId) { episode in
            EpisodeCard(episode: episode)
                .tag(episode.id)
                .listRowBackground(
                    viewModel.selectedEpisodeId == episode.id
                        ? Color.brandMintSubtle : Color.clear
                )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.brandBgPrimary)
        .refreshable { await viewModel.reload() }
    }
}

private struct EpisodeCard: View {
    let episode: Episode
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Color.brandMintDim)
                Text(displayApp)
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(episode.eventCount) event\(episode.eventCount == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.brandMintDim, lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.brandMintDim)
            }
            HStack(spacing: 6) {
                Text(Formatters.relativeTime(usSinceEpoch: episode.tsStartUs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMint)
                    .help(Formatters.tsString(usSinceEpoch: episode.tsStartUs))
                Text("·").foregroundStyle(Color.brandFgMuted)
                Text("\(durationLabel) event span")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
            }
        }
        .padding(.vertical, MCI.Spacing.s)
        .padding(.horizontal, MCI.Spacing.xs)
        .background(isHovered ? Color.brandBgElevated.opacity(0.7) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.s, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(MCI.Motion.snap, value: isHovered)
    }

    private var displayApp: String {
        guard let bundle = episode.appBundleId, !bundle.isEmpty else {
            return "(no app)"
        }
        if let last = bundle.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }
        return bundle
    }

    private var durationLabel: String {
        let seconds = max(0, episode.durationSeconds)
        if seconds < 60 {
            return "\(Int(seconds))s"
        }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            let s = Int(seconds.truncatingRemainder(dividingBy: 60))
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

private struct EpisodeEvidencePanel: View {
    let episode: Episode
    let reader: BrainReader
    @State private var screenshots: [TimelineEvent] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var selection: ScreenshotSelection?
    @State private var loadGeneration = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Formatters.appDisplayName(episode.appBundleId)).font(.headline)
                Text(Formatters.tsString(usSinceEpoch: episode.tsStartUs)).font(.caption)
                Text("Episode spans include unmeasured idle time and may include non-screen records.")
                    .font(.caption).foregroundStyle(.secondary)
                if isLoading {
                    ProgressView("Reading episode")
                } else if failed {
                    Text("Episode evidence is unavailable. Try refreshing memory.")
                        .foregroundStyle(Color.brandError)
                } else if screenshots.isEmpty {
                    ContentUnavailableView("No saved evidence", systemImage: "doc.text",
                                           description: Text("This session has no available samples."))
                } else {
                    ForEach(screenshots) { event in
                        Button {
                            selection = ScreenshotSelection(eventIDs: screenshots.map(\.id), initialID: event.id, expectedEvents: screenshots)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                if event.hasScreenshot {
                                    GeometryReader { geometry in
                                        EvidenceThumbnail(url: event.thumbnailURL, size: geometry.size, maxPixelSize: 640)
                                    }
                                    .aspectRatio(16 / 10, contentMode: .fit)
                                }
                                Text(verbatim: Formatters.stripContextHeader(event.snippet))
                                    .font(.callout).lineLimit(4)
                                Text(Date(timeIntervalSince1970: Double(event.tsUs) / 1_000_000), format: .dateTime.hour().minute().second())
                                Text(MemorySourceKind.label(event.sourceKind)).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Open saved session evidence")
                    }
                }
            }
            .padding(16)
        }
        .task(id: episode) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await load() }
        }
        .sheet(item: $selection) { selection in ScreenshotViewer(selection: selection, reader: reader) }
    }

    private func load() async {
        let request = UUID()
        loadGeneration = request
        isLoading = screenshots.isEmpty
        failed = false
        do {
            let events = try await reader.timelineEvents(startTsUs: episode.tsStartUs, endTsUs: episode.tsEndUs, resolution: .minute)
            guard !Task.isCancelled, request == loadGeneration else { return }
            screenshots = episode.evidence(from: events)
        } catch {
            guard !Task.isCancelled, request == loadGeneration else { return }
            screenshots = []
            failed = true
        }
        isLoading = false
    }
}
