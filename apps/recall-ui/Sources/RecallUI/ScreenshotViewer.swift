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

    init(selection: ScreenshotSelection, reader: BrainReader) {
        self.selection = selection
        self.reader = reader
        _index = State(initialValue: selection.eventIDs.firstIndex(of: selection.initialID) ?? 0)
    }

    private var eventID: UInt64? {
        selection.eventIDs.indices.contains(index) ? selection.eventIDs[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0).help("Previous screenshot")
                    .accessibilityLabel("Previous screenshot")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(selection.eventIDs.isEmpty ? 0 : index + 1) of \(selection.eventIDs.count)")
                    .font(.callout.monospacedDigit()).frame(minWidth: 76)
                Button { index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= selection.eventIDs.count).help("Next screenshot")
                    .accessibilityLabel("Next screenshot")
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                if let hit {
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
            } else if let hit {
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
                            Text(hit.sourceKind == "screen_ocr" ? "OCR snippet" : "Stored text snippet")
                                .font(.headline)
                            Text(Formatters.stripContextHeader(hit.ocrTextSnippet).isEmpty
                                 ? "No text was stored with this screenshot."
                                 : Formatters.stripContextHeader(hit.ocrTextSnippet))
                                .font(.body).textSelection(.enabled)
                            Text("The stored snippet may be incomplete.")
                                .font(.caption).foregroundStyle(.secondary)
                            Divider()
                            Button("Copy context", systemImage: "doc.on.clipboard") {
                                copy(VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit]))
                            }
                            Button("Export context", systemImage: "square.and.arrow.up") {
                                export(VisualMemoryExport.markdown(title: "Selected screenshot", hits: [hit]), name: "screenshot-\(hit.id).md")
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
            let request = UUID()
            loadGeneration = request
            if hit?.id != eventID { hit = nil }
            errorMessage = nil
            isLoading = hit == nil
            defer { if loadGeneration == request { isLoading = false } }
            guard let eventID else { errorMessage = "No screenshot selected."; return }
            do {
                let current = try await reader.fetchEventsByIds([eventID]).first
                guard !Task.isCancelled, loadGeneration == request else { return }
                hit = current
                if current == nil { errorMessage = "This event is no longer in memory." }
            } catch {
                guard !Task.isCancelled, loadGeneration == request else { return }
                hit = nil
                errorMessage = "The saved event could not be read. Try again."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            refreshID += 1
        }
        .alert("Context export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            ToastNotifier.shared.notify("Context copied")
        } else { exportError = "The clipboard is unavailable. Try again." }
    }

    private func export(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text]
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = "The context file could not be saved. Choose another location." }
        }
    }
}
