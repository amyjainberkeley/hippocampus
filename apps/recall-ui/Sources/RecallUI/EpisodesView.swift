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

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                errorView(err)
            } else if viewModel.isLoading && viewModel.episodes.isEmpty {
                ShimmerLoadingView(isLoading: true)
            } else if viewModel.episodes.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reload()
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
        List(viewModel.episodes, selection: $viewModel.selectedEpisodeId) { episode in
            EpisodeCard(episode: episode)
                .tag(episode.id)
                .listRowSeparator(.hidden)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Color.brandMintDim)
                Text(displayApp)
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(Color.brandFgPrimary)
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
                Text(durationLabel)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(Color.brandFgSecondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.brandCardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
        .padding(.vertical, 4)
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
