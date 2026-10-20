#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Working On's scenes: a code project's page and a document's, one the
    /// person hid, Show All, Web Pages (with and without page addresses),
    /// Looked Up (and empty), and the sidebar's thumbnails and hover
    /// preview, light and dark (`nav-working-on-*`, `nav-web-pages*`,
    /// `nav-looked-up*`, `show-all-grid*`, `sidebar-*`). Sam's week, drawn
    /// and sealed (`WorkRenderFixture`); nothing is read from the person's
    /// memory, and nothing opens.
    static var workScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                .picture("nav-working-on-item-code\(suffix)", dark: dark) {
                    await WorkRenders.window(.item(WorkFixtures.trailheadShop))
                },
                .picture("nav-working-on-item-document\(suffix)", dark: dark) {
                    await WorkRenders.window(.item(WorkFixtures.launchChecklist))
                },
                .picture("nav-working-on-item-hidden\(suffix)", dark: dark) {
                    await WorkRenders.window(.item(WorkFixtures.launchChecklist), hidden: [WorkFixtures.launchChecklist])
                },
                .picture("nav-working-on-all\(suffix)", dark: dark) {
                    await WorkRenders.window(.showAll)
                },
                .picture("show-all-grid\(suffix)", size: CGSize(width: 1100, height: 1500), dark: dark) {
                    await WorkRenders.window(.showAll, hidden: [WorkFixtures.giftCardCopy], expandsNotShown: true)
                },
                .picture("nav-web-pages\(suffix)", dark: dark) {
                    await WorkRenders.window(.webPages(addresses: true))
                },
                .picture("nav-web-pages-no-addresses\(suffix)", dark: dark) {
                    await WorkRenders.window(.webPages(addresses: false))
                },
                .picture("nav-looked-up\(suffix)", dark: dark) {
                    await WorkRenders.window(.lookedUp(empty: false))
                },
                .picture("nav-looked-up-empty\(suffix)", dark: dark) {
                    await WorkRenders.window(.lookedUp(empty: true))
                },
                .picture("sidebar-thumbnails\(suffix)", size: CGSize(width: 200, height: 720), dark: dark) {
                    await WorkRenders.sidebarAlone()
                },
                .picture("sidebar-hover\(suffix)", dark: dark) {
                    await WorkRenders.window(.item(WorkFixtures.trailheadShop), hovered: WorkFixtures.pricingV3)
                },
            ]
        }
        return scenes
    }
}

/// How the Working On renders are drawn: the window's frame as the approved
/// prototype draws it (the sidebar, the field row) around one of lane C's
/// places. The frame here is a picture's stand-in for the shell's, which
/// owns the real sidebar; the Working On rows in it are the real
/// `WorkingOnSidebarRow`.
@MainActor
enum WorkRenders {
    enum Page {
        case item(String)
        case showAll
        case webPages(addresses: Bool)
        case lookedUp(empty: Bool)
    }

    nonisolated static let now = PreviewUnderstandingReader.sampleNow
    nonisolated static let calendar = PreviewUnderstandingReader.sampleCalendar

    /// The fixture whose picture is being taken. Scenes are drawn one at a
    /// time, so a new one means the last one's picture is taken: its sealed
    /// screens go then, and the last one's when the renderer exits.
    private static var live: WorkRenderFixture?

    static func adopt(_ fixture: WorkRenderFixture) {
        live?.remove()
        live = fixture
        workRenderFolder = fixture.folder.path
        if !exitCleanupRegistered {
            exitCleanupRegistered = true
            atexit {
                if let folder = workRenderFolder {
                    try? FileManager.default.removeItem(atPath: folder)
                }
            }
        }
    }

    private static var exitCleanupRegistered = false

    /// The window on `page`, read before it is drawn.
    static func window(_ page: Page, hidden: Set<String> = [], hovered: String? = nil,
                       expandsNotShown: Bool = false, resume: Bool = false, note: String? = nil) async -> AnyView {
        guard let fixture = try? WorkRenderFixture(now: now, calendar: calendar) else {
            return AnyView(Color.red)
        }
        adopt(fixture)
        await fixture.prewarm()
        let reader = fixture.reader
        let snapshot: WorkSnapshot
        if case .webPages(addresses: false) = page {
            snapshot = WorkFixtures.snapshotWithoutAddresses(now: now, calendar: calendar)
        } else {
            snapshot = fixture.snapshot
        }
        let work = PreviewWorkReader(snapshot: snapshot)
        let moments = WorkMomentCache()
        await moments.load(snapshot.items.compactMap(\.thumbnailMoment), reader: reader)
        let content: AnyView
        let selection: StandInSidebar.Selection
        let placeholder: String
        switch page {
        case let .item(id):
            let model = WorkingOnItemModel(itemId: id, work: work, reader: reader,
                                           calendarReader: FixtureCalendar(access: .allowed,
                                                                           events: WorkFixtures.calendarEvents(now: now,
                                                                                                               calendar: calendar)),
                                           calendar: calendar, now: { now })
            await model.reload()
            content = AnyView(WorkingOnItemPlace(itemId: id, work: work, reader: reader, open: { _ in }, model: model))
            selection = .item(id)
            placeholder = UserFacingCopy.askPlaceholder
        case .showAll:
            let model = WorkingOnModel(reader: work)
            await model.reload()
            content = AnyView(WorkingOnPlace(work: work, reader: reader, open: { _ in }, model: model,
                                             showsNotShown: expandsNotShown))
            selection = .showAll
            placeholder = WorkCopy.fieldPlaceholder
        case .webPages:
            let model = WebPagesModel(work: work, reader: reader, calendar: calendar, now: { now })
            await model.reload()
            if let first = model.rows.first?.id {
                await model.select(first)
            }
            content = AnyView(WebPagesPlace(work: work, reader: reader, open: { _ in }, model: model))
            selection = .webPages
            placeholder = UserFacingCopy.askPlaceholder
        case let .lookedUp(empty):
            let searches = PreviewSearchesReader(records: empty ? [] : WorkFixtures.searches(now: now, calendar: calendar))
            let model = LookedUpModel(searches: searches, reader: reader, calendar: calendar, now: { now })
            await model.reload()
            if let first = model.rows.first?.id {
                await model.select(first)
            }
            content = AnyView(LookedUpList(reader: reader, open: { _ in }, model: model))
            selection = .lookedUp
            placeholder = UserFacingCopy.askPlaceholder
        }
        let window = StandInWindow(selection: selection, snapshot: snapshot, hidden: hidden, hovered: hovered,
                                   placeholder: placeholder, now: now, calendar: calendar, page: content)
        return AnyView(
            window
                .environment(\.screenshots, fixture.screenshots)
                .environment(\.workMoments, moments)
                .environment(\.workNow, { now })
                .environment(\.workItemHides, WorkItemHides(ids: hidden))
                .environment(\.claudeCodeStartsSessions, true)
                .environment(\.lensForget, LensForget(forget: { _, _ in }))
                .environment(\.calendar, calendar)
        )
    }

    /// The sidebar on its own, a week in.
    static func sidebarAlone() async -> AnyView {
        guard let fixture = try? WorkRenderFixture(now: now, calendar: calendar) else { return AnyView(Color.red) }
        adopt(fixture)
        await fixture.prewarm()
        let moments = WorkMomentCache()
        await moments.load(fixture.snapshot.items.compactMap(\.thumbnailMoment), reader: fixture.reader)
        return AnyView(
            StandInSidebar(selection: .item(WorkFixtures.trailheadShop), snapshot: fixture.snapshot, hidden: [],
                           hovered: nil, now: now, calendar: calendar)
                .environment(\.screenshots, fixture.screenshots)
                .environment(\.workMoments, moments)
                .environment(\.calendar, calendar)
        )
    }
}

/// The sealed screens' folder of the last fixture, removed at exit.
nonisolated(unsafe) private var workRenderFolder: String?

// MARK: - The window's frame, for pictures

/// The window as the prototype draws it, around a page: the sidebar, then
/// the field row over the page. A stand-in for the shell's in pictures only.
struct StandInWindow: View {
    let selection: StandInSidebar.Selection
    let snapshot: WorkSnapshot
    let hidden: Set<String>
    let hovered: String?
    let placeholder: String
    let now: Date
    let calendar: Calendar
    let page: AnyView

    var body: some View {
        HStack(spacing: 0) {
            StandInSidebar(selection: selection, snapshot: snapshot, hidden: hidden, hovered: hovered,
                           now: now, calendar: calendar)
                .frame(width: 200)
                .zIndex(1)
            Rectangle().fill(StandInSidebar.edge).frame(width: 1)
            VStack(spacing: 0) {
                fieldRow
                Rectangle().fill(StandInSidebar.hairline).frame(height: 1)
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(MCI.Color.background)
        }
    }

    private var fieldRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left").frame(width: 30, height: 26)
            Image(systemName: "chevron.right").frame(width: 30, height: 26)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(MCI.Color.foregroundMuted)
                .padding(.leading, 8)
            Text(placeholder)
                .font(.system(size: 17))
                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                .padding(.leading, 3)
            Spacer(minLength: 0)
            Text("\u{2318}F")
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundMuted)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(MCI.Color.foregroundSecondary.opacity(0.5))
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(height: 52)
        .background(MCI.Color.surface)
    }
}

/// The sidebar as the prototype draws it a week in: the hi mark, Today,
/// Working On (the real rows, with their thumbnails), Library, the pinned
/// group and the footer.
struct StandInSidebar: View {
    enum Selection: Equatable {
        case item(String)
        case showAll
        case webPages
        case lookedUp
    }

    let selection: Selection
    let snapshot: WorkSnapshot
    let hidden: Set<String>
    let hovered: String?
    let now: Date
    let calendar: Calendar

    @Environment(\.workMoments) private var moments

    static let background = MCI.Color.hex(light: 0xEFF0F3, dark: 0x1F2125)
    static let selected = MCI.Color.hex(light: 0xDCDEE3, dark: 0x36393F)
    static let edge = MCI.Color.hex(light: 0xD7D9DE, dark: 0x050607)
    static let hairline = MCI.Color.hex(light: 0xDFE0E1, dark: 0x2E3033)

    var body: some View {
        let sidebar = WorkingOnSidebar(snapshot, hidden: hidden)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { color in
                    Circle().fill(Color(hex: UInt(color))).frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(height: 52)
            WindowHiMarkView(remembering: true)
                .frame(height: 22)
                .foregroundStyle(MCI.Color.foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .padding(.leading, 14)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) {
                row(NavigationCopy.today, symbol: "sun.max", on: false)
                header(NavigationCopy.workingOn)
                ForEach(sidebar.items) { item in
                    rowFrame(on: selection == .item(item.id)) {
                        WorkingOnSidebarRow(item: item, picture: moments?.hit(item.thumbnailMoment), now: now,
                                            calendar: calendar, previewInline: hovered == item.id)
                            .labelStyle(StandInLabelStyle(on: selection == .item(item.id)))
                    }
                    .zIndex(hovered == item.id ? 2 : 0)
                }
                if sidebar.showsAll {
                    rowFrame(on: selection == .showAll) {
                        Text(NavigationCopy.showAll)
                            .foregroundStyle(selection == .showAll ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                            .padding(.leading, 25)
                    }
                }
                header(NavigationCopy.library)
                row(NavigationCopy.history, symbol: "clock", on: false)
                row(NavigationCopy.webPages, symbol: "globe", on: selection == .webPages)
                row(NavigationCopy.lookedUp, symbol: "text.magnifyingglass", on: selection == .lookedUp)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).padding(.horizontal, -10)
                    .padding(.bottom, 8)
                row(NavigationCopy.aboutYou, symbol: "person.crop.circle", on: false)
                row(NavigationCopy.aiTools, symbol: "cable.connector", on: false)
                row(NavigationCopy.privacy, symbol: "hand.raised", on: false)
                HStack(spacing: 8) {
                    Circle().fill(MCI.Color.accentFill).frame(width: 7, height: 7)
                    Text(verbatim: "Remembering")
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.background)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MCI.Color.foregroundSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .padding(.top, 16)
            .padding(.bottom, 2)
    }

    private func row(_ title: String, symbol: String, on: Bool) -> some View {
        rowFrame(on: on) {
            Label(title, systemImage: symbol).labelStyle(StandInLabelStyle(on: on))
        }
    }

    private func rowFrame(on: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.system(size: 13))
            .foregroundStyle(MCI.Color.foreground)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Self.selected : Color.clear))
    }
}

/// The sidebar's label: a 17 pt icon column, then the name.
struct StandInLabelStyle: LabelStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 14))
                .foregroundStyle(on ? MCI.Color.accent : MCI.Color.foregroundSecondary)
                .frame(width: 26, alignment: .center)
            configuration.title
                .lineLimit(1)
        }
    }
}
#endif
