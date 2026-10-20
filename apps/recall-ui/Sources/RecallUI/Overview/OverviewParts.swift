import AppKit
import RecallUIKit
import SwiftUI

// Pieces Overview and You share: a session's screenshot, "Copy for your AI",
// "Open {App}" or "Open Page", and opening AI Tools.

/// Where Overview's screenshots come from: the encrypted store in the app,
/// drawn fixtures in the off-screen renderer.
private struct OverviewThumbnailsKey: EnvironmentKey {
    static let defaultValue: any ThumbnailDataProviding = SharedThumbnails()
}

extension EnvironmentValues {
    var overviewThumbnails: any ThumbnailDataProviding {
        get { self[OverviewThumbnailsKey.self] }
        set { self[OverviewThumbnailsKey.self] = newValue }
    }
}

/// The app's provider, reached only when an image is asked for.
private struct SharedThumbnails: ThumbnailDataProviding {
    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        await ThumbnailDataProvider.shared.thumbnailData(for: url, maxPixelSize: maxPixelSize)
    }

    func screenshotData(for url: URL) async -> Data? {
        await ThumbnailDataProvider.shared.screenshotData(for: url)
    }
}

/// A session's stored screenshot, found by its moment; without one, the
/// app it was in on a calm tile.
struct SessionScreenshot: View {
    let eventId: Int64?
    let reader: BrainReader
    let size: CGSize
    /// The app shown on the tile until the moment says otherwise.
    var fallbackApp: String? = nil
    @Environment(\.overviewThumbnails) private var provider
    @State private var url: URL?
    @State private var app: String?

    var body: some View {
        EvidenceThumbnail(url: url, appBundleId: app ?? fallbackApp, size: size,
                          maxPixelSize: Int(max(size.width, size.height) * 2),
                          contentMode: .fill, provider: provider)
            .task(id: eventId) {
                url = nil
                guard let eventId, let id = UInt64(exactly: eventId),
                      let hit = try? await reader.fetchEventsByIds([id]).first(where: { $0.eventId == id }),
                      !Task.isCancelled
                else { return }
                app = hit.appBundleId
                guard let path = hit.thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty
                else { return }
                url = URL(fileURLWithPath: path)
            }
    }
}

/// "Copy for your AI": the session's own moments, as Markdown (RULINGS I13).
struct CopyForYourAIButton: View {
    let title: String
    let range: ClosedRange<Int64>
    let reader: BrainReader
    var prominent = false

    private enum Phase { case idle, copying, copied, failed }
    @State private var phase: Phase = .idle

    var body: some View {
        HStack(spacing: 8) {
            let button = Button {
                Task { await copy() }
            } label: {
                Text(phase == .copied ? UserFacingCopy.Overview.copied : UserFacingCopy.copyForYourAI)
            }
            .disabled(phase == .copying)
            if prominent {
                button.buttonStyle(.borderedProminent).tint(DayStripPalette.color(DayStripPalette.accent))
            } else {
                button.buttonStyle(.bordered)
            }
            if phase == .failed {
                Text(UserFacingCopy.Overview.couldNotCopy)
                    .font(MCI.Font.caption)
                    .foregroundStyle(MCI.Color.error)
            }
        }
    }

    @MainActor
    private func copy() async {
        phase = .copying
        do {
            let text = try await SessionCopy.markdown(title: title, range: range, reader: reader)
            let board = NSPasteboard.general
            board.clearContents()
            guard board.setString(text, forType: .string) else {
                phase = .failed
                return
            }
            phase = .copied
            try? await Task.sleep(for: .seconds(2))
            if phase == .copied { phase = .idle }
        } catch {
            phase = .failed
        }
    }
}

/// "Open Page" or "Open {App}" (RULINGS W5).
struct ReopenButton: View {
    let action: ReopenAction
    var prominent = false
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        let button = Button(action.label) { perform() }
            .disabled(isSyntheticPreview)
        if prominent {
            button.buttonStyle(.borderedProminent).tint(DayStripPalette.color(DayStripPalette.accent))
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func perform() {
        switch action {
        case let .page(url):
            NSWorkspace.shared.open(url)
        case let .app(bundleId, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Opens the AI Tools pane of Preferences.
@MainActor
func openAITools() {
    Task { _ = await WorkspacePreferencesRouter.shared.open(.sources, bundleURL: Bundle.main.bundleURL) }
}

/// A rounded card on the window's background.
struct OverviewCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MCI.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MCI.Color.border, lineWidth: 1)
            )
    }
}
