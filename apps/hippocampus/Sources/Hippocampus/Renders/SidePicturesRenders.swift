#if DEBUG
import AppKit
import HippocampusKit
import SwiftUI

extension StatusPreviewRenderer {
    /// Preferences › Remembering with pictures of the windows beside the one
    /// in front: on with what they use, off with Forget, the budget full and
    /// the Mac low on space, light and dark
    /// (`prefs-remembering-side-pictures*`). Drawn with every other picture
    /// by `HIPPOCAMPUS_RENDER_BAR`.
    ///
    /// Each is fed its own made-up settings and usage record, written to a
    /// temporary folder, read once and removed: nothing reads or writes the
    /// person's own settings.
    static var sidePicturePanes: [Pane] {
        [
            sidePicturePane("remembering-side-pictures", enabled: true, usedBytes: 640_000_000),
            sidePicturePane("remembering-side-pictures-dark", enabled: true, usedBytes: 640_000_000, dark: true),
            sidePicturePane("remembering-side-pictures-off", enabled: false, usedBytes: 640_000_000),
            sidePicturePane("remembering-side-pictures-off-dark", enabled: false, usedBytes: 640_000_000, dark: true),
            sidePicturePane("remembering-side-pictures-full", enabled: true, usedBytes: 2_000_000_000),
            sidePicturePane("remembering-side-pictures-low-space", enabled: true, usedBytes: 640_000_000,
                            freeBytes: 8_000_000_000),
        ]
    }

    private static func sidePicturePane(
        _ name: String, enabled: Bool, usedBytes: Int64, budgetMB: Int = 2_000,
        freeBytes: Int64 = 300_000_000_000, dark: Bool = false
    ) -> Pane {
        let model = fixtureSidePictures(enabled: enabled, usedBytes: usedBytes, budgetMB: budgetMB,
                                        freeBytes: freeBytes)
        let pane = fixturePane(name, .capture, receipt: savedReceipt(savedAt: Date().addingTimeInterval(-8)))
        let view = pane.view.environment(\.sidePictures, model)
        guard dark else { return Pane(name: name, view: AnyView(view)) }
        return Pane(name: name, view: AnyView(
            AppearanceHost(appearance: .darkAqua, content: AnyView(view.environment(\.colorScheme, .dark)))
        ))
    }

    /// A model read from made-up files that are gone once it has read them.
    private static func fixtureSidePictures(
        enabled: Bool, usedBytes: Int64, budgetMB: Int, freeBytes: Int64
    ) -> SidePicturesPreferences {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-side-pictures-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = RuntimeConfig(path: folder.appendingPathComponent("runtime.toml"))
        try? config.setSideWindowPictures(enabled)
        try? config.setSidePicturesBudgetMB(budgetMB)
        let usage = folder.appendingPathComponent("pictures-usage.json")
        let record: [String: Any] = [
            "schema_version": 1, "updated_at": "2026-10-13T22:09:00.000Z", "front_bytes": 1_400_000_000,
            "side_bytes": usedBytes, "side_count": 412, "side_budget_bytes": Int64(budgetMB) * 1_000_000,
            "side_pictures_on": enabled,
        ]
        try? JSONSerialization.data(withJSONObject: record).write(to: usage)
        return SidePicturesPreferences(config: config, usageURL: usage, availableBytes: { freeBytes })
    }
}

/// Draws `content` under a fixed appearance, for pictures of the dark Mac:
/// AppKit's own controls inside take the appearance of the view that hosts
/// them, which SwiftUI's colour scheme alone does not change.
private struct AppearanceHost: NSViewRepresentable {
    let appearance: NSAppearance.Name
    let content: AnyView

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: appearance)
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = content
        host.appearance = NSAppearance(named: appearance)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
#endif
