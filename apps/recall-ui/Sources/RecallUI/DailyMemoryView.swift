import AppKit
import RecallUIKit
import SwiftUI

struct DailyMemoryView: View {
    let reader: BrainReader
    let onOpenPrivacy: () -> Void
    @StateObject private var model: DailyMemoryViewModel
    @State private var selectedScreenshot: ScreenshotSelection?
    @State private var showsEpisodes = false
    @State private var isExporting = false
    @State private var exportError: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(reader: BrainReader, onOpenPrivacy: @escaping () -> Void) {
        self.reader = reader
        self.onOpenPrivacy = onOpenPrivacy
        _model = StateObject(wrappedValue: DailyMemoryViewModel(reader: reader))
    }

    var body: some View {
        VStack(spacing: 0) {
            dayToolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    captureStatus
                    if model.isLoading && model.refreshedAt == nil {
                        ProgressView("Reading this day").frame(maxWidth: .infinity).padding(40)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Memory unavailable", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                        Button("Retry", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                    } else {
                        summary
                        visualMemory
                        if !model.screenshots.isEmpty { appBreakdown }
                        dayBrief
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.brandBgPrimary)
        .task(id: model.day) { await model.reload() }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await model.search()
        }
        .onChange(of: showsEpisodes) { _, episodes in
            if episodes { model.query = "" }
        }
        .onChange(of: model.query) { _, query in
            if !query.isEmpty { showsEpisodes = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.reload() }
        }
        .sheet(item: $selectedScreenshot) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
        .alert("Context export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private var dayToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { dateControls; Spacer(minLength: 8); exportControls }
            VStack(alignment: .leading, spacing: 12) {
                dateControls
                HStack { Spacer(); exportControls }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(reduceTransparency ? AnyShapeStyle(Color.brandBgSecondary) : AnyShapeStyle(.regularMaterial))
    }

    private var dateControls: some View {
        HStack(spacing: 12) {
            Button { model.moveDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous day").accessibilityLabel("Previous day")
            DatePicker("Day", selection: $model.selectedDate, in: ...Date(), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
                .accessibilityLabel("Selected memory day")
            Button { model.moveDay(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(model.selectedDate))
                .help("Next day").accessibilityLabel("Next day")
            Button("Today") { model.selectedDate = Date() }
                .disabled(Calendar.current.isDateInToday(model.selectedDate))
        }
        .buttonStyle(.borderless)
    }

    private var exportControls: some View {
        HStack(spacing: 12) {
            if model.isLoading || isExporting { ProgressView().controlSize(.small) }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isLoading).help("Refresh memory").accessibilityLabel("Refresh memory")
            Button("Copy day summary", systemImage: "doc.on.clipboard") { exportDay(save: false) }
                .disabled(isExporting || !model.canExportSummary)
            Button { exportDay(save: true) } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(isExporting || !model.canExportSummary)
                .help("Export day context").accessibilityLabel("Export day context")
        }
        .buttonStyle(.borderless)
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let receipt = model.captureHealth {
                Label(receipt.isStale() ? "Capture status is out of date" : receipt.stateLabel,
                      systemImage: receipt.isStale() || receipt.blockedReason != nil ? "exclamationmark.circle" : "display")
                    .font(.callout)
                    .foregroundStyle(receipt.isStale() || receipt.blockedReason != nil ? Color.brandWarning : Color.brandFgSecondary)
                if let detail = receipt.detailText() {
                    Text(detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(receipt.storedFrameCount) screen records / \(receipt.storedScreenshotCount) screenshots stored")
                    if let last = receipt.lastStoredFrameAt {
                        Text("Last screen write \(last.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Capture status unavailable", systemImage: "display")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let date = model.refreshedAt {
                Text("Memory refreshed \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                WorkspacePreferencesButton(title: "Capture", systemImage: "display", destination: .capture)
                Button("Privacy", systemImage: "hand.raised", action: onOpenPrivacy)
                    .help("Open Privacy")
            }
            .buttonStyle(.borderless)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Calendar.current.isDateInToday(model.selectedDate) ? "Today" : model.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title2.weight(.semibold))
            if model.screenshots.isEmpty {
                Text(model.events.isEmpty ? "No visual memory is available for this day."
                     : "\(model.events.count) memory records are available, with no saved screenshots.")
                    .foregroundStyle(.secondary)
            } else {
                let apps = Set(model.screenshots.map { Formatters.appDisplayName($0.appBundleId) })
                Text("\(model.screenshots.count) screenshots across \(apps.count) apps in \(model.episodes.count) visual episodes.")
                    .font(.body)
                if let first = model.screenshots.first, let last = model.screenshots.last {
                    Text("First saved \(time(first.tsUs)) / Last saved \(time(last.tsUs))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appBreakdown: some View {
        let groups = Dictionary(grouping: model.episodes, by: { $0.appBundleId ?? "" })
        let apps = groups.keys.sorted {
            let lhs = groups[$0, default: []].reduce(0) { $0 + $1.observedSeconds }
            let rhs = groups[$1, default: []].reduce(0) { $0 + $1.observedSeconds }
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Observed spans by app").font(.subheadline.weight(.medium))
                .help("Observed spans join screenshots in the same app up to 10 minutes apart and include unmeasured idle time. They are not active-time measurements. Dense days may be sampled.")
            ForEach(apps, id: \.self) { app in
                let episodes = groups[app, default: []]
                HStack {
                    Text(Formatters.appDisplayName(app))
                    Spacer()
                    Text("\(episodes.reduce(0) { $0 + $1.events.count }) screenshots")
                        .foregroundStyle(.secondary)
                    Text(VisualMemoryEpisode.durationLabel(episodes.reduce(0) { $0 + $1.observedSeconds }))
                        .monospacedDigit().frame(minWidth: 130, alignment: .trailing)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 8)
    }

    private var visualMemory: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { visualMode; Spacer(); screenshotSearch }
                VStack(alignment: .leading, spacing: 12) { visualMode; screenshotSearch }
            }
            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.brandError)
            } else if model.isSearching {
                ProgressView("Searching screenshots").frame(maxWidth: .infinity).padding()
            } else if showsEpisodes && model.query.isEmpty {
                if model.episodes.isEmpty {
                    emptyScreenshots
                } else {
                    ForEach(model.episodes.reversed()) { episode in
                        Button {
                            open(episode.events[0], among: episode.events)
                        } label: {
                            HStack(spacing: 16) {
                                EvidenceThumbnail(url: episode.events[0].thumbnailURL,
                                                  size: CGSize(width: 160, height: 90), maxPixelSize: 320)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(Formatters.appDisplayName(episode.appBundleId)).font(.headline)
                                    Text("\(time(episode.events[0].tsUs)) - \(time(episode.events[episode.events.count - 1].tsUs))")
                                    Text("\(episode.events.count) screenshots / \(VisualMemoryEpisode.durationLabel(episode.observedSeconds))")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            } else if model.visibleScreenshots.isEmpty {
                if model.query.isEmpty { emptyScreenshots }
                else { ContentUnavailableView.search(text: model.query) }
            } else {
                if !model.query.isEmpty {
                    Text("Screenshots in the top 200 memory matches for this day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)], spacing: 20) {
                    ForEach(model.visibleScreenshots.reversed()) { event in
                        Button { open(event, among: model.visibleScreenshots) } label: {
                            DailyScreenshotCard(event: event)
                        }
                        .buttonStyle(.plain)
                        .help("Open saved screenshot")
                    }
                }
            }
        }
    }

    private var visualMode: some View {
        Picker("Visual memory", selection: $showsEpisodes) {
            Text("Screenshots").tag(false)
            Text("Episodes").tag(true)
        }
        .pickerStyle(.segmented).frame(width: 220)
    }

    private var screenshotSearch: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search this day's screenshots", text: $model.query)
                .textFieldStyle(.plain)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Clear screenshot search").accessibilityLabel("Clear screenshot search")
            }
        }
        .padding(8).background(Color.brandBgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 240, maxWidth: 340)
    }

    private var emptyScreenshots: some View {
        ContentUnavailableView("No saved screenshots", systemImage: "photo.on.rectangle",
                               description: Text("No screenshot files are available for this day. Text-only records remain in Search and Timeline."))
    }

    private var dayBrief: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Saved daily brief").font(.headline)
            if let brief = model.brief {
                Text(brief.title).font(.subheadline.weight(.medium))
                if brief.modelId == "hippocampus-extractive" {
                    Label("Draft", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                }
                BriefEvidenceView(brief: brief, reader: reader)
                Text("Generated \(Formatters.tsString(usSinceEpoch: brief.generatedTsUs)) from \(brief.sourceEventCount) memory records. May include non-screen sources.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.briefError ?? "No generated brief is saved for this day.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func time(_ timestamp: UInt64) -> String {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000_000).formatted(date: .omitted, time: .shortened)
    }

    private func open(_ event: TimelineEvent, among events: [TimelineEvent]) {
        selectedScreenshot = ScreenshotSelection(eventIDs: events.map(\.id), initialID: event.id)
    }

    private func exportDay(save: Bool) {
        guard !isExporting else { return }
        isExporting = true
        let day = model.day
        Task {
            defer { isExporting = false }
            do {
                let packet = try await model.exportSummary()
                guard model.day == day else { return }
                if save {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "day-summary-\(day.dateLocal).md"
                    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
                    if panel.runModal() == .OK, let url = panel.url {
                        try packet.write(to: url, atomically: true, encoding: .utf8)
                    }
                } else {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(packet, forType: .string) else {
                        exportError = "The clipboard is unavailable. Try again."
                        return
                    }
                    ToastNotifier.shared.notify("Day summary copied")
                }
            } catch { exportError = "The day context could not be exported. Try again." }
        }
    }
}

private struct DailyScreenshotCard: View {
    let event: TimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                EvidenceThumbnail(url: event.thumbnailURL, size: geometry.size, maxPixelSize: 640)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            HStack {
                Text(Formatters.appDisplayName(event.appBundleId)).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                Text(Date(timeIntervalSince1970: Double(event.tsUs) / 1_000_000), format: .dateTime.hour().minute())
                    .monospacedDigit()
            }
            .font(.callout)
            Text(MemorySourceKind.label(event.sourceKind)).font(.caption).foregroundStyle(.secondary)
            Text(event.snippet)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
