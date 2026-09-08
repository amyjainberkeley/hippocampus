import AppKit
import RecallUIKit
import SwiftUI

struct DailyMemoryView: View {
    let reader: BrainReader
    let onOpenPrivacy: () -> Void
    let latestBriefRequest: UUID?
    @StateObject private var model: DailyMemoryViewModel
    @State private var selectedEvidence: ScreenshotSelection?
    @State private var showsHandoff = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(reader: BrainReader, onOpenPrivacy: @escaping () -> Void, latestBriefRequest: UUID? = nil) {
        self.reader = reader
        self.onOpenPrivacy = onOpenPrivacy
        self.latestBriefRequest = latestBriefRequest
        _model = StateObject(wrappedValue: DailyMemoryViewModel(reader: reader))
    }

    var body: some View {
        VStack(spacing: 0) {
            dayToolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.isLoading && model.refreshedAt == nil {
                            ProgressView("Reading this day").frame(maxWidth: .infinity).padding(40)
                        } else if let error = model.errorMessage {
                            ContentUnavailableView("Memory unavailable", systemImage: "exclamationmark.triangle",
                                                   description: Text(error))
                            Button("Retry", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                        } else {
                            dailyReview
                            if !model.review.visualEvidence.isEmpty { visualEvidence }
                            savedDraft.id("saved-draft")
                        }
                        Divider()
                        captureStatus
                    }
                    .padding(24)
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.showsSavedDraft) { _, expanded in
                    if expanded { proxy.scrollTo("saved-draft", anchor: .top) }
                }
            }
        }
        .background(Color.brandBgPrimary)
        .task(id: model.day) { await model.reload() }
        .task(id: latestBriefRequest) {
            if latestBriefRequest != nil { await model.openLatestBrief() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            guard !showsHandoff else { return }
            Task { await model.reload() }
        }
        .sheet(item: $selectedEvidence) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
        .sheet(isPresented: $showsHandoff, onDismiss: { Task { await model.reload() } }) {
            DailyHandoffView(model: model)
        }
    }

    private var dayToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            dateControls
            HStack(alignment: .top, spacing: 16) {
                currentCaptureState
                Spacer(minLength: 8)
                Button("Handoff", systemImage: "doc.text.magnifyingglass") { showsHandoff = true }
                    .disabled(!model.canExportSummary)
                    .help("Review daily context before copying or exporting")
                    .accessibilityLabel("Preview daily handoff")
            }
        }
        .buttonStyle(.borderless)
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
            Spacer(minLength: 8)
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isLoading).help("Refresh memory").accessibilityLabel("Refresh memory")
        }
    }

    @ViewBuilder
    private var currentCaptureState: some View {
        if let receipt = model.captureHealth {
            Label((receipt.isStale() ? "Status out of date / " : "Now / ") + receipt.stateLabel,
                  systemImage: receipt.isStale() || receipt.blockedReason != nil ? "exclamationmark.circle" : "display")
                .font(.caption)
                .foregroundStyle(receipt.isStale() || receipt.blockedReason != nil ? Color.brandWarning : Color.brandFgSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(receipt.detailText() ?? "Current capture status, independent of the selected day")
        } else {
            Label("Capture status unavailable", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dailyReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Calendar.current.isDateInToday(model.selectedDate) ? "Today" : model.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title2.weight(.semibold))
            if model.review.events.isEmpty {
                ContentUnavailableView("No saved evidence", systemImage: "calendar",
                    description: Text("No samples are available for this day."))
            } else {
                ForEach(model.review.observations) { observation in
                    observationRow(observation)
                    Divider()
                }
                Text(model.review.countLabel).font(.callout)
                Text(DailyReview.coverageNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func observationRow(_ observation: DailyReview.Observation) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if observation.kind == .lastContext, let image = model.review.visualEvidence.last {
                Button { open(image, among: model.screenshots) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        EvidenceThumbnail(url: image.thumbnailURL, size: CGSize(width: 132, height: 82), maxPixelSize: 264)
                            .frame(width: 132, height: 82)
                        Text("Last image / \(time(image.tsUs))").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 132, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open last saved image")
                .accessibilityLabel("Last saved image, \(Formatters.appDisplayName(image.appBundleId)), \(time(image.tsUs))")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: observation.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !observation.detail.isEmpty {
                    Text(verbatim: observation.detail).font(.callout).lineLimit(2)
                        .textSelection(.enabled)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { observationSources(observation) }
                    VStack(alignment: .leading, spacing: 6) { observationSources(observation) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func observationSources(_ observation: DailyReview.Observation) -> some View {
        ForEach(observation.evidence) { event in
            Button { open(event, among: observation.evidence) } label: {
                Label {
                    Text("\(time(event.tsUs)) / \(Formatters.appDisplayName(event.appBundleId)) / \(MemorySourceKind.label(event.sourceKind))")
                        .lineLimit(2)
                } icon: { Image(systemName: "doc.text.magnifyingglass") }
            }
            .buttonStyle(.borderless).font(.caption)
            .help("Open saved evidence \(event.id)")
            .accessibilityHint("Opens the saved source with its timestamp and text")
        }
    }

    private var visualEvidence: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visual evidence").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 16)], spacing: 16) {
                ForEach(model.review.visualEvidence) { event in
                    Button { open(event, among: model.screenshots) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            GeometryReader { geometry in
                                EvidenceThumbnail(url: event.thumbnailURL, size: geometry.size, maxPixelSize: 560)
                            }
                            .aspectRatio(16 / 10, contentMode: .fit)
                            Text(Formatters.appDisplayName(event.appBundleId)).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(time(event.tsUs)) / \(MemorySourceKind.label(event.sourceKind))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain).help("Open saved screenshot")
                }
            }
        }
    }

    @ViewBuilder
    private var savedDraft: some View {
        if let brief = model.brief {
            DisclosureGroup("Saved draft", isExpanded: $model.showsSavedDraft) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Generated \(Formatters.tsString(usSinceEpoch: brief.generatedTsUs)). This stored draft may be out of date.")
                        .font(.caption).foregroundStyle(.secondary)
                    BriefEvidenceView(brief: brief, reader: reader)
                }
                .padding(.top, 12)
            }
        } else if let error = model.briefError {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var captureStatus: some View {
        DisclosureGroup("Capture now") {
            VStack(alignment: .leading, spacing: 8) {
                if let receipt = model.captureHealth {
                    Text(receipt.isStale() ? "Capture status is out of date" : receipt.stateLabel)
                        .font(.callout)
                    if let detail = receipt.detailText() {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let last = receipt.lastStoredFrameAt {
                        Text("Last screen write \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Capture status unavailable").font(.callout).foregroundStyle(.secondary)
                }
                if let refreshed = model.refreshedAt {
                    Text("Review refreshed \(refreshed.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    WorkspacePreferencesButton(title: "Capture", systemImage: "display", destination: .capture)
                    Button("Privacy", systemImage: "hand.raised", action: onOpenPrivacy)
                }
                .buttonStyle(.borderless)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
    }

    private func time(_ timestamp: UInt64) -> String {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000_000).formatted(date: .omitted, time: .shortened)
    }

    private func open(_ event: TimelineEvent, among events: [TimelineEvent]) {
        selectedEvidence = ScreenshotSelection(eventIDs: events.map(\.id), initialID: event.id, expectedEvents: events)
    }
}

private struct DailyHandoffView: View {
    @ObservedObject var model: DailyMemoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var handoffTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Daily handoff / \(model.day.dateLocal)").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help("Close handoff").accessibilityLabel("Close handoff")
                    .keyboardShortcut(.cancelAction)
            }
            Text("Review before sharing. Source observations are not verified facts.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                if let preview = model.handoffPreview {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(HandoffPreview.blocks(preview)) { block in
                            Text(block.text)
                                .font(block.isHeading ? .headline : .callout)
                                .textSelection(.enabled)
                                .accessibilityAddTraits(block.isHeading ? .isHeader : [])
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .environment(\.openURL, OpenURLAction { _ in .discarded })
                } else if isWorking {
                    ProgressView("Rechecking saved evidence").frame(maxWidth: .infinity).padding(40)
                } else {
                    ContentUnavailableView("No current handoff", systemImage: "doc.text")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(Color.brandWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 16) {
                Button("Refresh preview", systemImage: "arrow.clockwise") { prepare() }
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Copy", systemImage: "doc.on.clipboard") { export(save: false) }
                    .disabled(isWorking || model.handoffPreview == nil)
                Button("Export", systemImage: "square.and.arrow.up") { export(save: true) }
                    .disabled(isWorking || model.handoffPreview == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 400, idealHeight: 600)
        .task { prepare() }
        .onDisappear { handoffTask?.cancel() }
    }

    private func prepare() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        handoffTask = Task {
            defer { isWorking = false }
            do { try await model.prepareHandoff() }
            catch { errorMessage = "The saved evidence could not be read. Refresh to try again." }
        }
    }

    private func export(save: Bool) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        handoffTask = Task {
            defer { isWorking = false }
            do {
                var destination: URL?
                if save {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "daily-handoff-\(model.day.dateLocal).md"
                    panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
                    guard await panel.begin() == .OK, let url = panel.url else { return }
                    destination = url
                }
                let packet = try await model.validatedHandoff()
                if let destination {
                    try packet.write(to: destination, atomically: true, encoding: .utf8)
                    ToastNotifier.shared.notify("Daily handoff exported")
                } else {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(packet, forType: .string) else {
                        errorMessage = "The clipboard is unavailable. Try again."
                        return
                    }
                    ToastNotifier.shared.notify("Daily handoff copied")
                }
            } catch let error as DailyHandoffError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = "The handoff could not be exported. Refresh the preview and try again."
            }
        }
    }
}
