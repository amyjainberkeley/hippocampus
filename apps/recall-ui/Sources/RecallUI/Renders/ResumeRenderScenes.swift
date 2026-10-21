#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Resume: the sheet over trailhead-shop's page, listing what was open
    /// in its last session, the same plan as Demo Memory shows a made-up
    /// one (`resume-sheet-made-up*`), and the note after it opened
    /// (`resume-sheet*`, `resume-note*`), light and dark. The plan, the Mac
    /// and the browsers' tabs are fixtures: nothing opens and macOS is asked
    /// nothing.
    static var resumeScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                .picture("resume-sheet\(suffix)", dark: dark) {
                    await ResumeRenders.sheetOverPage()
                },
                .picture("resume-sheet-many-pages\(suffix)", size: CGSize(width: 1100, height: 820), dark: dark) {
                    await ResumeRenders.sheetOverPage(manyPages: true)
                },
                .picture("resume-sheet-made-up\(suffix)", dark: dark) {
                    await ResumeRenders.sheetOverPage(madeUp: true)
                },
                .picture("resume-note\(suffix)", dark: dark) {
                    await ResumeRenders.noteAfter()
                },
            ]
        }
        return scenes
    }
}

@MainActor
enum ResumeRenders {
    /// The Mac in the pictures: the apps Sam's plan names are installed.
    static let installed: Set<String> = [
        "com.microsoft.VSCode", "com.apple.Terminal", "com.google.Chrome", "com.apple.Notes",
        "com.tinyspeck.slackmacgap", "com.apple.Safari",
    ]

    /// The sheet as macOS shows it: over the page, at the window's top.
    static func sheetOverPage(manyPages: Bool = false, madeUp: Bool = false) async -> AnyView {
        let page = await WorkRenders.window(.item(WorkFixtures.trailheadShop))
        var plans = WorkFixtures.plans(now: WorkRenders.now, calendar: WorkRenders.calendar)
        if manyPages, let shop = plans[WorkFixtures.trailheadShop] {
            var items = shop.items
            // Twelve pages: the newest ten ticked, as the agent ticks them.
            let more: [ResumePlan.Target] = (0..<8).map { index in
                .init(kind: "page", title: "Pricing page example \(index + 1)", app: "com.google.Chrome",
                      url: "https://pricing\(index + 1).example/plans", checked: index < 6)
            }
            items.insert(contentsOf: more, at: 8)
            plans[WorkFixtures.trailheadShop] = ResumePlan(items: items, item: shop.item, session: shop.session)
        }
        let model = ResumeSheetModel(itemId: WorkFixtures.trailheadShop, planner: PreviewResumePlans(plans: plans),
                                     workspace: FixtureResumeWorkspace(installed: installed), tabs: NoOpenTabs(),
                                     madeUp: madeUp)
        await model.load()
        let sheet = ResumeSheetContent(model: model, notes: BottomNotes(), now: WorkRenders.now,
                                       calendar: WorkRenders.calendar, loads: false) {}
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MCI.Color.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 35, y: 18)
        return AnyView(
            ZStack(alignment: .top) {
                page
                Color.black.opacity(0.06)
                sheet.padding(.top, 52)
            }
        )
    }

    /// The note after Resume, at the bottom of the page.
    static func noteAfter() async -> AnyView {
        let page = await WorkRenders.window(.item(WorkFixtures.trailheadShop))
        let notes = BottomNotes()
        notes.show(WorkCopy.resumeOpened(tabs: 6, apps: 2))
        return AnyView(
            ZStack(alignment: .bottom) {
                page
                // Where the window keeps it: over the page, at its foot.
                HStack(alignment: .bottom, spacing: 0) {
                    Color.clear.frame(width: 201, height: 1)
                    BottomNoteHost(notes: notes).frame(maxWidth: .infinity)
                }
            }
        )
    }
}
#endif
