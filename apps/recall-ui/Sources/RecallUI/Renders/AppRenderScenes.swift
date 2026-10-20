#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

/// What a picture's page reads in Sam's world (`ShellWorld`).
@MainActor
struct ShellWorldContext {
    let reader: any BrainReader
    let work: any WorkReader
    let now: Date
    let calendar: Calendar
    let services: WindowServices
}

extension WindowRenderer {
    /// The whole window on every page, in Sam's made-up world, light and
    /// dark (`app-*`): the pictures to hold against the approved prototype.
    /// Each page is the window's own, inside the real shell, read before
    /// the picture is taken; a list shows its first row open, as a click
    /// would. Nothing is read from the person's memory, calendar, AI tools
    /// or Mac, and nothing opens.
    static var appScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let tail = dark ? "-dark" : "-light"
            scenes += [
                Scene.shell("app-today" + tail, place: .today, dark: dark),
                Scene.shell("app-history-article" + tail, dark: dark, history: true) { ask in
                    await ask.history.reload()
                    if let row = ask.history.hits.first(where: { ($0.windowTitle ?? "").contains("Rounding") }) {
                        ask.history.selectedHitId = row.id
                        ask.history.focusDetail()
                    }
                },
                app("app-item-code" + tail, place: .item(WorkFixtures.trailheadShop), dark: dark) { context in
                    await itemPage(WorkFixtures.trailheadShop, context)
                },
                app("app-item-document" + tail, place: .item(WorkFixtures.launchChecklist), dark: dark) { context in
                    await itemPage(WorkFixtures.launchChecklist, context)
                },
                app("app-show-all" + tail, place: .workingOn, dark: dark) { context in
                    let model = WorkingOnModel(reader: context.work)
                    await model.reload()
                    return AnyView(WorkingOnPlace(work: context.work, reader: context.reader, open: { _ in },
                                                  model: model))
                },
                app("app-web-pages" + tail, place: .webPages, dark: dark) { context in
                    let model = WebPagesModel(work: context.work, reader: context.reader, calendar: context.calendar,
                                              now: { context.now })
                    await model.reload()
                    if let first = model.rows.first?.id { await model.select(first) }
                    return AnyView(WebPagesPlace(work: context.work, reader: context.reader, open: { _ in },
                                                 model: model))
                },
                app("app-looked-up" + tail, place: .lookedUp, dark: dark) { context in
                    let searches = context.services.searches ?? PreviewSearchesReader()
                    let model = LookedUpModel(searches: searches, reader: context.reader, calendar: context.calendar,
                                              now: { context.now })
                    await model.reload()
                    if let first = model.rows.first?.id { await model.select(first) }
                    return AnyView(LookedUpList(reader: context.reader, open: { _ in }, model: model))
                },
                Scene.shell("app-about-you" + tail, place: .aboutYou, dark: dark),
                Scene.shell("app-ai-tools" + tail, place: .aiTools, dark: dark),
                Scene.shell("app-privacy" + tail, place: .privacy, dark: dark),
                app("app-code" + tail, place: .place(.code), dark: dark, history: true) { context in
                    await lensPage(.code, context)
                },
                app("app-documents" + tail, place: .place(.documents), dark: dark, history: true) { context in
                    await lensPage(.documents, context)
                },
                app("app-conversations" + tail, place: .place(.conversations), dark: dark, history: true) { context in
                    await lensPage(.conversations, context)
                },
            ]
        }
        // An item's whole page, down to the meetings that overlapped its
        // sessions, read from Sam's calendar through the window's reader.
        var whole = app("app-item-code-whole-light", place: .item(WorkFixtures.trailheadShop), dark: false) { context in
            await itemPage(WorkFixtures.trailheadShop, context)
        }
        whole.size = CGSize(width: 1100, height: 1500)
        scenes.append(whole)
        // The question a session's forget asks, drawn over Today.
        var forget = WindowShellPreset()
        forget.forgetConfirmation = ForgetConfirmation(
            title: NavigationCopy.forgetSpanTitle("2:12 to 2:41\u{202F}PM"),
            body: NavigationCopy.forgetSpanBody("2:12 to 2:41\u{202F}PM", moments: 7), firstForget: true,
            request: ForgetRequest(momentIds: [1]), audit: .moments(7))
        scenes.append(Scene.shell("app-forget-session-light", place: .today, preset: forget))
        return scenes
    }

    /// A shell scene whose page is read before the picture is taken.
    private static func app(_ name: String, place: MemoryWorkspaceSelection, dark: Bool, history: Bool = false,
                            page: @escaping @MainActor (ShellWorldContext) async -> AnyView) -> Scene {
        var scene = Scene.shell(name, place: place, dark: dark, history: history)
        scene.shellPage = page
        return scene
    }

    /// A lens over History with its newest row open, as a click opens it.
    private static func lensPage(_ lens: LibraryLens, _ context: ShellWorldContext) async -> AnyView {
        let model = LibraryLensModel(lens: lens, reader: context.reader)
        await model.reload()
        if let first = model.shownHits.first?.id {
            model.selection = [first]
            model.isDetailFocused = true
        }
        return AnyView(LibraryLensView(model: model, reader: context.reader, work: context.work, open: { _ in },
                                       calendar: context.calendar, now: { context.now }))
    }

    /// An item's page, read with Sam's calendar, so its meetings show.
    private static func itemPage(_ id: String, _ context: ShellWorldContext) async -> AnyView {
        let model = WorkingOnItemModel(itemId: id, work: context.work, reader: context.reader,
                                       calendarReader: context.services.calendar, calendar: context.calendar,
                                       now: { context.now })
        await model.reload()
        return AnyView(WorkingOnItemPlace(itemId: id, work: context.work, reader: context.reader, open: { _ in },
                                          model: model))
    }
}
#endif
