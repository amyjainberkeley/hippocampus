import AppKit
import RecallUIKit
import SwiftUI

struct ScreenshotSelection: Identifiable {
    let eventIDs: [UInt64]
    let initialID: UInt64
    var id: UInt64 { initialID }
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
                    .disabled(index <= 0).help("Previous screenshot")
                    .accessibilityLabel("Previous screenshot")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(selection.eventIDs.isEmpty ? 0 : index + 1) of \(selection.eventIDs.count)")
                    .font(.callout.monospacedDigit()).frame(minWidth: 76)
                Button { clearLoadedEvent(); index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= selection.eventIDs.count).help("Next screenshot")
                    .accessibilityLabel("Next screenshot")
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                if let hit = selectedHit {
                    Text(Formatters.appDisplayName(hit.appBundleId)).font(.headline).lineLimit(1)
                    Text(Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000), format: .dateTime.hour().minute().second())
                        .font(.callout.monospacedDigit())
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help("Close screenshot").accessibilityLabel("Close screenshot")
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(16)
            .background(.regularMaterial)
            Divider()
            if isLoading {
                ProgressView("Loading screenshot").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Screenshot unavailable", systemImage: "photo.badge.exclamationmark",
                                       description: Text(errorMessage))
                Button("Retry", systemImage: "arrow.clockwise") { refreshID += 1 }.padding()
            } else if let hit = selectedHit {
                HSplitView {
                    GeometryReader { geometry in
                        EvidenceThumbnail(url: hit.thumbnailURL, size: geometry.size,
                                          maxPixelSize: ThumbnailDataProvider.maximumThumbnailPixels,
                                          showsStatus: true)
                    }
                    .padding(16)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(hit.windowTitle ?? Formatters.appDisplayName(hit.appBundleId))
                                .font(.headline).textSelection(.enabled)
                            LabeledContent("Source", value: MemorySourceKind.label(hit.sourceKind))
                            LabeledContent("Saved", value: hit.thumbnailURL == nil ? "Text only" : "Screenshot")
                            Text(Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000),
                                 format: .dateTime.year().month().day().hour().minute().second().timeZone())
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let url = hit.url, !url.isEmpty {
                                Text(url).font(.callout).textSelection(.enabled)
                                if let destination = URL(string: url), ["http", "https"].contains(destination.scheme?.lowercased() ?? "") {
                                    Link(destination: destination) { Label("Open source", systemImage: "arrow.up.right.square") }
                                }
                            }
                            Divider()
                            storedTextSection(for: hit)
                            Divider()
                            Button("Copy context", systemImage: "doc.on.clipboard") {
                                copyContext()
                            }
                            Button("Export context", systemImage: "square.and.arrow.up") {
                                exportContext()
                            }
                            Text("Event \(hit.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
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
            guard let eventID else { errorMessage = "No screenshot selected."; return }
            do {
                let current = try await reader.fetchEventsByIds([eventID]).first
                guard !Task.isCancelled, loadGeneration == request, eventID == self.eventID else { return }
                guard let current, current.id == eventID else {
                    errorMessage = "This event is no longer in memory."
                    return
                }
                hit = current
                isLoading = false
                await textModel.load(hit: current, reader: reader)
            } catch {
                guard !Task.isCancelled, loadGeneration == request, eventID == self.eventID else { return }
                textModel.clear()
                errorMessage = "The saved event could not be read. Try again."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            clearLoadedEvent()
            refreshID += 1
        }
        .onDisappear(perform: clearLoadedEvent)
        .alert("Context export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    @ViewBuilder
    private func storedTextSection(for hit: Hit) -> some View {
        let stored = textModel.text(for: hit)
        let body = Formatters.stripContextHeader(textModel.copyText(for: hit))
        Text(stored == nil ? "Stored text snippet" : (hit.sourceKind == "screen_ocr" ? "OCR text" : "Stored text"))
            .font(.headline)
        switch textModel.state(for: hit) {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading stored text...").font(.caption).foregroundStyle(.secondary)
            }
        case .unavailable:
            Text("Full text unavailable. Showing saved snippet.").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Could not load full text. Showing saved snippet.").font(.caption).foregroundStyle(.secondary)
        case let .loaded(text):
            if text.isTruncated {
                Label("Truncated at the 128 KiB text limit.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text(body.isEmpty ? (stored == nil ? "No text preview is available." : "No stored text.") : body)
            .font(.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearLoadedEvent() {
        loadGeneration = UUID()
        hit = nil
        textModel.clear()
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
        panel.nameFieldStringValue = "screenshot-\(hit.id).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
        if panel.runModal() == .OK, let url = panel.url {
            guard loadGeneration == generation, let current = selectedHit, current.id == hit.id else {
                exportError = "The selected event changed. Export canceled."
                return
            }
            let text = ScreenshotInspectorContext.markdown(hit: current, text: textModel.text(for: current))
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "The context file could not be saved. Choose another location." }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            ToastNotifier.shared.notify("Context copied")
        } else { exportError = "The clipboard is unavailable. Try again." }
    }

}
