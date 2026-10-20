#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// The field kept to a page, Mail-style (SPEC 2.8), drawn as the matches
    /// under the field, 900 pt wide: "tax" on trailhead-shop's page, light and
    /// dark, and a scope with nothing in it. From fixtures only.
    static var searchScenes: [Scene] {
        [
            SearchRenderScene.scene("nav-history-search-scope", query: "tax"),
            SearchRenderScene.scene("nav-history-search-scope-dark", dark: true, query: "tax"),
            SearchRenderScene.scene("nav-history-search-scope-empty", query: "invoice"),
        ]
    }
}

@MainActor
enum SearchRenderScene {
    static func scene(_ name: String, dark: Bool = false, query: String) -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: 720), dark: dark) {
            await page(query: query)
        }
    }

    static func page(query: String) async -> AnyView {
        let now = PreviewUnderstandingReader.sampleNow
        let calendar = PreviewUnderstandingReader.sampleCalendar
        let base = NativePreviewReader(date: now, now: now, calendar: calendar)
        let fixtures = RenderFixtureReader(base: base, overviewMoments: OverviewPreviewBrainReader())
        guard let review = try? ReviewRenderFixture(base: fixtures, now: now) else { return AnyView(EmptyView()) }
        RenderLeftovers.keep(review)
        let reader = LensRenderReader(moments: review.reader.moments + LensRenderScene.earlier(review.reader, now: now))
        var work = HistoryRenderScene.work
        for id: UInt64 in [ReviewRenderFixture.assistantId, 72_011, 72_012, 72_013, 72_022] {
            work.momentItems[id] = "w_trailhead_shop"
        }
        let model = SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: EphemeralKeyValueStore()),
            userDictionaryLoader: { .empty },
            work: PreviewWorkReader(snapshot: work))
        if let shop = work.items.first(where: { $0.id == "w_trailhead_shop" }) {
            model.pageScope = .item(shop)
        }
        model.query = query
        await model.runSearch()
        let page = SearchView(viewModel: model, reader: reader)
            .environment(\.screenshots, review.screenshots)
            .environment(\.forget, ForgetAction { _ in })
            .background(MCI.Color.background)
        return AnyView(page)
    }
}
#endif
