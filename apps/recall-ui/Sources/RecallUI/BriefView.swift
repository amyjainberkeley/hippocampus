// BriefView.swift — SwiftUI scene for the Daily Brief tab in the Recall
// UI per `docs/design/brief-viewer-spec.md`.
//
// The scene is a thin renderer over BriefViewModel.scene; the VM owns
// all state-machine logic. The five spec states map to the
// `BriefScene` enum the VM publishes.

import AppKit
import RecallUIKit
import SwiftUI

struct BriefView: View {
    @StateObject var viewModel: BriefViewModel
    /// Callback fired when the empty-state "Enable on-device brief
    /// model" button is tapped. The Recall UI does NOT own the model
    /// download UI (that lives in Hippocampus.app per PR #134) — this
    /// is the deep-link out. App wires it to launch Hippocampus.app
    /// with a URL the menu-bar surfaces.
    var onRequestModelDownload: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DateSelectorBar(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().overlay(Color.brandCardBorder)

            sceneBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.brandBgPrimary)
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reload()
        }
    }

    @ViewBuilder
    private var sceneBody: some View {
        switch viewModel.scene {
        case .modelMissing:
            modelMissingView
        case .awaitingFirstFullDay(let hoursSoFar):
            awaitingFirstFullDayView(hoursSoFar: hoursSoFar)
        case .loading:
            ShimmerLoadingView(isLoading: true)
        case .brief(let brief):
            BriefBodyView(brief: brief) {
                Task { await viewModel.reload(forceDate: brief.dateLocal) }
            }
        case .missingForDate(let dateLocal):
            missingForDateView(dateLocal: dateLocal)
        case .error(let message):
            errorView(message: message)
        }
    }

    private var modelMissingView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Daily briefs coming soon",
                systemImage: "doc.text",
                description: Text(
                    "Daily briefs are written by an on-device AI model (Qwen3-1.7B, ≈ 1 GB). The model is not bundled in v0.1.0 — it ships in a future update. Nothing leaves your device."
                )
            )
            .foregroundStyle(Color.brandFgSecondary)

            // The download flow exists in Hippocampus.app's menu-bar
            // ("Daily Briefs: Off — Download Model…") but Qwen3 model
            // conversion + HuggingFace upload (OWNER_TASKS #17–#19) is
            // not complete in v0.1.0 — the SHA in models.json is the
            // `PLACEHOLDER_UNTIL_MODEL_IS_CONVERTED` literal, so a
            // download attempt would fail SHA verification anyway. We
            // surface the menu-bar entry-point honestly so power users
            // who fetch the model manually can still wire it up.
            Text("Power users: click the Hippocampus icon in your menu bar → 'Daily Briefs' once the model ships.")
                .font(.caption)
                .foregroundStyle(Color.brandFgMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
    }

    private func awaitingFirstFullDayView(hoursSoFar: Double?) -> some View {
        let hoursLabel: String = {
            guard let h = hoursSoFar, h > 0 else { return "Capture hasn't started yet." }
            return String(format: "Captured %.1f hours so far.", h)
        }()
        return ContentUnavailableView(
            "First brief generates after your first full day",
            systemImage: "clock.badge",
            description: Text(hoursLabel)
        )
        .foregroundStyle(Color.brandFgSecondary)
        .padding(24)
    }

    private func missingForDateView(dateLocal: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "No brief for \(dateLocal)",
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    "Either capture was off this day or brief generation was skipped."
                )
            )
            .foregroundStyle(Color.brandFgSecondary)

            if let latestKnown = viewModel.knownDates.first, latestKnown != dateLocal {
                Button("Jump to most recent brief") {
                    Task { await viewModel.loadFor(latestKnown) }
                }
                .buttonStyle(.bordered)
                .tint(Color.brandMint)
            }
        }
        .padding(24)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Couldn't load brief",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )
            .foregroundStyle(Color.brandError)

            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.bordered)
            .tint(Color.brandMint)
        }
        .padding(24)
    }
}

// MARK: - Date selector

struct DateSelectorBar: View {
    @ObservedObject var viewModel: BriefViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.pickPrevious() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(viewModel.canPickPrevious ? Color.brandMint : Color.brandFgMuted)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPickPrevious)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Previous brief")

            Text(viewModel.selectedDate.map(Self.humanReadable) ?? "—")
                .font(.system(.title3, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)

            Button {
                Task { await viewModel.pickNext() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(viewModel.canPickNext ? Color.brandMint : Color.brandFgMuted)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPickNext)
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .help("Next brief")
        }
    }

    /// "Friday, May 22, 2026"
    static func humanReadable(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .iso8601)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - Brief body + footer

struct BriefBodyView: View {
    let brief: Brief
    var onRegenerate: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BriefHeaderView(brief: brief)

                Text(brief.body)
                    .font(.system(.body, design: .default))
                    .textSelection(.enabled)
                    .foregroundStyle(Color.brandFgPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)

                BriefFooterActions(brief: brief, onRegenerate: onRegenerate)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BriefHeaderView: View {
    let brief: Brief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(brief.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.brandFgPrimary)
            HStack(spacing: 6) {
                Text("Generated \(Formatters.relativeTime(usSinceEpoch: brief.generatedTsUs))")
                    .help(Formatters.tsString(usSinceEpoch: brief.generatedTsUs))
                Text("·")
                Text("\(brief.wordCount) words")
                Text("·")
                Text("\(brief.modelId), on-device")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.brandFgMuted)

            if brief.sourceEventCount > 0 {
                Text("based on \(brief.sourceEventCount) events")
                    .font(.caption)
                    .foregroundStyle(Color.brandFgMuted)
            }
        }
        .padding(.bottom, 4)
    }
}

struct BriefFooterActions: View {
    let brief: Brief
    var onRegenerate: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(brief.body, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy brief body to clipboard")

            Button {
                exportMarkdown(brief)
            } label: {
                Label("Export Markdown", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Save the brief as a .md file")

            Spacer()

            Button {
                onRegenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.brandMintDim)
            .help(
                "Re-fetch the latest brief for this date. The brief author runs on a schedule; this does not trigger a new generation."
            )
        }
        .font(.callout)
    }

    private func exportMarkdown(_ brief: Brief) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "brief-\(brief.dateLocal).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
        panel.title = "Export Brief"
        if panel.runModal() == .OK, let url = panel.url {
            let header = "# \(brief.title)\n\n_\(brief.modelId), generated \(Formatters.tsString(usSinceEpoch: brief.generatedTsUs))_\n\n"
            let data = (header + brief.body).data(using: .utf8) ?? Data()
            try? data.write(to: url)
        }
    }
}
