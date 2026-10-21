import AppKit
import RecallUIKit
import SwiftUI

struct ScreenshotSelection: Identifiable {
    let eventIDs: [UInt64]
    let initialID: UInt64
    let expectedEvents: [TimelineEvent]
    var id: UInt64 { initialID }

    init(eventIDs: [UInt64], initialID: UInt64, expectedEvents: [TimelineEvent] = []) {
        self.eventIDs = eventIDs
        self.initialID = initialID
        self.expectedEvents = expectedEvents
    }
}

struct ScreenshotViewer: View {
    let selection: ScreenshotSelection
    let reader: BrainReader
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var hit: Hit?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var exportError: String?
    @State private var refreshID = 0
    @State private var loadGeneration = UUID()
    @StateObject private var textModel = EventTextViewModel()
    @StateObject private var rereadModel = ScreenshotRereadViewModel()
    @State private var imageZoom: CGFloat = 1
    @State private var showsRest = false

    init(selection: ScreenshotSelection, reader: BrainReader) {
        self.selection = selection
        self.reader = reader
        _index = State(initialValue: selection.eventIDs.firstIndex(of: selection.initialID) ?? 0)
    }

    private var eventID: UInt64? {
        selection.eventIDs.indices.contains(index) ? selection.eventIDs[index] : nil
    }

    private var selectedHit: Hit? {
        guard let hit, hit.id == eventID else { return nil }
        return hit
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { clearLoadedEvent(); index -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0).help(UserFacingCopy.previousAction)
                    .accessibilityLabel(UserFacingCopy.previousAction)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(selection.eventIDs.isEmpty ? 0 : index + 1) of \(selection.eventIDs.count)")
                    .font(.callout.monospacedDigit()).frame(minWidth: 76)
                Button { clearLoadedEvent(); index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= selection.eventIDs.count).help(UserFacingCopy.nextAction)
                    .accessibilityLabel(UserFacingCopy.nextAction)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                if let hit = selectedHit {
                    Text(Formatters.appDisplayName(hit.appBundleId)).font(.headline).lineLimit(1)
                    Text(Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000), format: .dateTime.hour().minute().second())
                        .font(.callout.monospacedDigit())
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help(UserFacingCopy.closeAction).accessibilityLabel(UserFacingCopy.closeAction)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(16)
            .background(.regularMaterial)
            Divider()
            if isLoading {
                ProgressView(UserFacingCopy.momentTextLoading).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(UserFacingCopy.screenshotLoadFailed, systemImage: "photo.badge.exclamationmark",
                                       description: Text(errorMessage))
                Button(UserFacingCopy.tryAgainAction, systemImage: "arrow.clockwise") { refreshID += 1 }.padding()
            } else if let hit = selectedHit {
                HSplitView {
                    VStack(spacing: 8) {
                        HStack {
                            Button("Zoom out", systemImage: "minus.magnifyingglass") { imageZoom = max(1, imageZoom - 0.5) }
                                .disabled(imageZoom <= 1)
                            Button("Fit") { imageZoom = 1 }
                            Button("Zoom in", systemImage: "plus.magnifyingglass") { imageZoom = min(4, imageZoom + 0.5) }
                                .disabled(imageZoom >= 4)
                        }
                        .buttonStyle(.borderless).font(.caption)
                        GeometryReader { geometry in
                            ScrollView([.horizontal, .vertical]) {
                                EvidenceThumbnail(url: hit.thumbnailURL, appBundleId: hit.appBundleId,
                                    size: CGSize(width: geometry.size.width * imageZoom, height: geometry.size.height * imageZoom),
                                    maxPixelSize: ThumbnailDataProvider.maximumScreenshotPixels,
                                    showsStatus: true, fullResolution: true)
                            }
                        }
                    }
                    .padding(16)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(hit.windowTitle ?? Formatters.appDisplayName(hit.appBundleId))
                                .font(.headline).textSelection(.enabled)
                            LabeledContent("Source", value: MemorySourceKind.label(hit.sourceKind))
                            LabeledContent("Saved", value: savedLabel(for: hit))
                            Text(Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000),
                                 format: .dateTime.year().month().day().hour().minute().second().timeZone())
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let url = hit.url, !url.isEmpty {
                                Text(url).font(.callout).textSelection(.enabled)
                                if let destination = URL(string: url), ["http", "https"].contains(destination.scheme?.lowercased() ?? "") {
                                    Link(destination: destination) { Label(UserFacingCopy.openLink, systemImage: "arrow.up.right.square") }
                                }
                            }
                            Divider()
                            if hit.thumbnailURL != nil {
                                ScreenshotRereadSection(hit: hit, reader: reader, model: rereadModel) { text in
                                    copy(text, notification: UserFacingCopy.copiedToast)
                                }
                                Divider()
                            }
                            textSection(for: hit)
                            Divider()
                            Button(UserFacingCopy.copyForYourAI, systemImage: "doc.on.clipboard") {
                                copyContext()
                            }
                            Button(UserFacingCopy.saveContextAction, systemImage: "square.and.arrow.up") {
                                exportContext()
                            }
                        }
                        .padding(20)
                    }
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 1060, maxWidth: .infinity,
               minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        .background(Color.brandBgPrimary)
        .task(id: "\(eventID ?? 0)-\(refreshID)") {
            guard !Task.isCancelled else { return }
            clearLoadedEvent()
            let request = UUID()
            loadGeneration = request
            defer { if loadGeneration == request { isLoading = false } }
            guard let eventID else { errorMessage = UserFacingCopy.momentGone; return }
            do {
                let current = try await reader.fetchEventsByIds([eventID]).first { $0.id == eventID }
                guard !Task.isCancelled, loadGeneration == request, eventID == self.eventID else { return }
                guard let current, current.id == eventID else {
                    errorMessage = UserFacingCopy.momentGone
                    return
                }
                if let expected = selection.expectedEvents.first(where: { $0.id == eventID }), !expected.matches(current) {
                    errorMessage = UserFacingCopy.momentGone
                    return
                }
                hit = current
                isLoading = false
                await textModel.load(hit: current, reader: reader)
            } catch {
                guard !Task.isCancelled, loadGeneration == request, eventID == self.eventID else { return }
                textModel.clear()
                errorMessage = UserFacingCopy.momentLoadFailed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            clearLoadedEvent()
            refreshID += 1
        }
        .onDisappear(perform: clearLoadedEvent)
        .alert(UserFacingCopy.saveContextFailedTitle, isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    /// What the person was reading, then "Also in this window", closed
    /// (RULINGS T12, T17).
    @ViewBuilder
    private func textSection(for hit: Hit) -> some View {
        let reading = textModel.text(for: hit)
        let body = textModel.copyText(for: hit, includingRest: false)
        let state = textModel.state(for: hit)
        Text(UserFacingCopy.momentTextHeading(sourceKind: hit.sourceKind))
            .font(.headline)
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(UserFacingCopy.momentTextLoading).font(.caption).foregroundStyle(.secondary)
            }
        case .unavailable, .failed:
            if !body.isEmpty {
                Text(UserFacingCopy.momentTextExcerpt).font(.caption).foregroundStyle(.secondary)
            }
        case let .loaded(text):
            if text.isTruncated {
                Label(UserFacingCopy.momentTextFirstPart, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !body.isEmpty {
            Text(body)
                .font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state != .idle, state != .loading, reading?.rest.isEmpty ?? true {
            Text(UserFacingCopy.momentTextEmpty)
                .font(.body).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let reading, !reading.rest.isEmpty {
            AlsoInThisWindowDisclosure(rest: reading.rest, lineCount: reading.restLineCount, isExpanded: $showsRest)
        }
    }

    /// "Screenshot", "Screenshot from 2:14 PM" when an earlier moment of the
    /// same window kept it, or "Text only".
    private func savedLabel(for hit: Hit) -> String {
        guard hit.thumbnailURL != nil else { return UserFacingCopy.textOnly }
        guard hit.screenshotIsEarlier, let taken = hit.thumbnailTsUs else { return "Screenshot" }
        return UserFacingCopy.screenshotFrom(Formatters.clockTime(us: Int64(clamping: taken)))
    }

    private func clearLoadedEvent() {
        loadGeneration = UUID()
        hit = nil
        textModel.clear()
        rereadModel.clear()
        imageZoom = 1
        showsRest = false
        errorMessage = nil
        exportError = nil
        isLoading = true
    }

    private func copyContext() {
        guard let hit = selectedHit else { return }
        copy(ScreenshotInspectorContext.markdown(hit: hit, text: textModel.text(for: hit)))
    }

    private func exportContext() {
        guard let hit = selectedHit else { return }
        let generation = loadGeneration
        let panel = NSSavePanel()
        // The text isn't encrypted, and Spotlight reads Markdown in full
        // (storage-security review S8).
        panel.message = ExportDestination.panelMessage
        panel.nameFieldStringValue = "screenshot-\(hit.id).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
        if panel.runModal() == .OK, let url = panel.url {
            guard loadGeneration == generation, let current = selectedHit, current.id == hit.id else {
                exportError = UserFacingCopy.momentChangedNothingSaved
                return
            }
            let text = ScreenshotInspectorContext.markdown(hit: current, text: textModel.text(for: current))
            // Mode 0600 from the moment it exists.
            do { try PrivateFileWriter.write(text, to: url) }
            catch { exportError = UserFacingCopy.saveContextFailedBody }
        }
    }

    private func copy(_ text: String, notification: String = UserFacingCopy.copiedToast) {
        if ClipboardHygiene.copyToKeep(text) {
            ToastNotifier.shared.notify(notification)
        } else { exportError = UserFacingCopy.copyFailedTryAgain }
    }

}
