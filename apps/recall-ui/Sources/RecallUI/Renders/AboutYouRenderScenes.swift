#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// About You (SPEC 3.7), drawn as the page, 900 pt wide: what Sam's AI
    /// tools can be told, with one Why open; the bottom row's two lists open;
    /// nothing learned yet. Light and dark, from the samples only. Verdicts
    /// go nowhere (`VerdictInbox(directory: nil)`).
    static var aboutYouScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                AboutYouRenderScene.scene("nav-about-you\(suffix)", dark: dark),
                AboutYouRenderScene.scene("nav-about-you-empty\(suffix)", dark: dark, empty: true, height: 520),
            ]
        }
        scenes.append(AboutYouRenderScene.scene("nav-about-you-open", open: true, height: 1_400))
        return scenes
    }
}

@MainActor
enum AboutYouRenderScene {
    static func scene(_ name: String, dark: Bool = false, empty: Bool = false, open: Bool = false,
                      height: CGFloat = 1_100) -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: height), dark: dark) {
            await page(empty: empty, open: open)
        }
    }

    static func page(empty: Bool, open: Bool) async -> AnyView {
        let understanding = PreviewUnderstandingReader(scenario: empty ? .empty : .populated)
        let model = UserModelViewModel(understanding: understanding, verdicts: VerdictInbox(directory: nil),
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await model.reload()
        let page = AboutYouPlace(model: model, open: { _ in }, items: TodayRenderFixture.work.items,
                                 keptBackOpen: open, notSeenOpen: open, firstWhyOpen: !open)
            .background(MCI.Color.background)
        return AnyView(page)
    }
}
#endif
