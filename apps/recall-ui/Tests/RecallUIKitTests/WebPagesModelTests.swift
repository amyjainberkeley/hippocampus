import XCTest
@testable import RecallUIKit

/// Web Pages (SPEC 3.5): one row per page across days, by its address
/// without query or fragment; by browser and title without one; under
/// Apple Notes' date sections; and the fallback from History's moments
/// when the work read can't answer.
@MainActor
final class WebPagesModelTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"

    private func page(_ title: String, host: String? = "devnotes.example", path: String? = "/rounding",
                      app: String = "com.google.Chrome", days: Int = 1, lastUs: UInt64,
                      moments: [UInt64]) -> WorkPage {
        WorkPage(title: title, host: host, path: path, app: app, days: days, lastUs: lastUs, moments: moments)
    }

    func testTheFallbackMakesOneRowPerAddressAndLeavesSearchesOut() {
        let hits = [
            workMoment(5, WorkClock.us(0, 14, 35), title: "Rounding half to even",
                       url: "https://www.devnotes.example/rounding?utm_source=feed#part-2"),
            workMoment(4, WorkClock.us(0, 11, 20), title: "Rounding half to even",
                       url: "https://devnotes.example/rounding/"),
            workMoment(3, WorkClock.us(3, 15, 16), app: safari, title: "Plans and pricing",
                       url: "https://SpokeAndChain.example/plans"),
            workMoment(2, WorkClock.us(0, 14, 6), title: "per seat vs tiered pricing - Google Search",
                       url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing"),
            workMoment(1, WorkClock.us(4, 9), title: "Sign in", url: "mailto:someone@example.com"),
        ]
        let rows = WebPagesModel.pages(from: hits, calendar: WorkClock.calendar)
        XCTAssertEqual(rows.map(\.id), ["devnotes.example/rounding", "spokeandchain.example/plans"])
        let rounding = rows[0]
        XCTAssertEqual(rounding.page.title, "Rounding half to even")
        XCTAssertEqual(rounding.page.host, "devnotes.example")
        XCTAssertEqual(rounding.page.path, "/rounding")
        XCTAssertEqual(rounding.page.moments, [5, 4], "newest first")
        XCTAssertEqual(rounding.page.days, 1)
        XCTAssertEqual(rounding.newest?.id, 5)
        XCTAssertEqual(rows[1].page.app, safari)
        XCTAssertEqual(WebPagesModel.link(rounding)?.absoluteString, "https://devnotes.example/rounding",
                       "a link never carries the query or fragment")
    }

    func testARowSaysItsBrowserSiteAndDaysAndItsLinkKeepsItsScheme() {
        var row = WebPageRow(id: "a", page: page("Rounding half to even", days: 3, lastUs: WorkClock.us(0, 14),
                                                 moments: [9]))
        XCTAssertEqual(WebPagesModel.origin(row).place, "Chrome \u{00B7} devnotes.example")
        XCTAssertEqual(WebPagesModel.origin(row).days, "on 3 days")
        row.newest = workMoment(9, WorkClock.us(0, 14), url: "http://devnotes.example/rounding?session=abc")
        XCTAssertEqual(WebPagesModel.link(row)?.absoluteString, "http://devnotes.example/rounding")

        let titleOnly = WebPageRow(id: "b", page: page("Rounding half to even", host: nil, path: nil, app: safari,
                                                       lastUs: WorkClock.us(0, 14), moments: [9]))
        XCTAssertEqual(WebPagesModel.origin(titleOnly).place, "Safari")
        XCTAssertNil(WebPagesModel.origin(titleOnly).days)
        XCTAssertNil(WebPagesModel.link(titleOnly), "no address, no Open Link")
        XCTAssertEqual(WebPagesModel.key(of: titleOnly.page), "com.apple.Safari|rounding half to even")
    }

    func testTheWorkReadsPagesListUnderDateSectionsWithABrowserFilter() async {
        let pages = [
            page("Rounding half to even", lastUs: WorkClock.us(0, 14, 35), moments: [5, 4]),
            page("Plans and pricing", host: "spokeandchain.example", path: "/plans", app: safari,
                 lastUs: WorkClock.us(1, 16), moments: [3]),
            page("Sales tax by state", host: "taxguide.example", path: "/states", lastUs: WorkClock.us(4, 15),
                 moments: [2]),
            page("Currency math without floats", host: "devnotes.example", path: "/currency",
                 lastUs: WorkClock.us(20, 15), moments: [1]),
            page("Last year", host: "old.example", path: "/", lastUs: WorkClock.us(80, 9), moments: [0]),
        ]
        let reader = WorkMomentsReader([workMoment(5, WorkClock.us(0, 14, 35), url: "https://devnotes.example/rounding")])
        let model = WebPagesModel(work: PreviewWorkReader(snapshot: WorkSnapshot(pages: pages)), reader: reader,
                                  calendar: WorkClock.calendar, now: { WorkClock.now })
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.rows.first?.newest?.id, 5, "the first rows read their newest moment")
        XCTAssertEqual(model.sections.map(\.title),
                       [WorkCopy.today, WorkCopy.yesterday, WorkCopy.previous7Days, WorkCopy.previous30Days, "July"])
        XCTAssertEqual(model.browsers, [chrome, safari])
        XCTAssertFalse(model.hasNoAddresses)
        model.browser = safari
        XCTAssertEqual(model.shownRows.map(\.page.title), ["Plans and pricing"])
        XCTAssertEqual(model.sections.map(\.title), [WorkCopy.yesterday])
        XCTAssertTrue(reader.searches.isEmpty, "the work read answered: no fallback")
    }

    func testWithoutAddressesTheLineAboutBrowsersShows() async {
        let pages = [page("Rounding half to even", host: nil, path: nil, lastUs: WorkClock.us(0, 14), moments: [5])]
        let model = WebPagesModel(work: PreviewWorkReader(snapshot: WorkSnapshot(pages: pages)), reader: WorkMomentsReader([]),
                                  calendar: WorkClock.calendar, now: { WorkClock.now })
        await model.reload()
        XCTAssertTrue(model.hasNoAddresses)
        XCTAssertEqual(model.rows.map(\.id), ["com.google.Chrome|rounding half to even"])
    }

    func testWhenTheWorkReadFailsTheLastSevenDaysOfAddressesShow() async {
        let reader = WorkMomentsReader([
            workMoment(7, WorkClock.us(0, 14), title: "Rounding half to even", url: "https://devnotes.example/rounding"),
            workMoment(6, WorkClock.us(0, 13), app: "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop"),
            workMoment(5, WorkClock.us(9, 13), title: "Too old", url: "https://old.example/page"),
        ])
        let model = WebPagesModel(work: UnavailableWorkReader(), reader: reader, calendar: WorkClock.calendar,
                                  now: { WorkClock.now })
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.rows.map(\.page.title), ["Rounding half to even"])
        let asked = try? XCTUnwrap(reader.searches.first)
        XCTAssertEqual(asked?.hasUrl, true)
        XCTAssertEqual(asked?.timeFromUs, UInt64(WorkClock.now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
                                                     * 1_000_000))

        let broken = WorkMomentsReader([])
        broken.failSearches()
        let failed = WebPagesModel(work: UnavailableWorkReader(), reader: broken, calendar: WorkClock.calendar,
                                   now: { WorkClock.now })
        await failed.reload()
        XCTAssertEqual(failed.state, .failed)
    }

    func testReadOnNamesEachDayOrEachVisitAndClickingATimeShowsIt() async {
        let moments = [
            workMoment(9, WorkClock.us(0, 14, 35), url: "https://devnotes.example/rounding"),
            workMoment(8, WorkClock.us(0, 14, 33), url: "https://devnotes.example/rounding"),
            workMoment(7, WorkClock.us(0, 11, 20), url: "https://devnotes.example/rounding"),
            workMoment(6, WorkClock.us(3, 16), url: "https://devnotes.example/currency"),
            workMoment(5, WorkClock.us(5, 9), url: "https://devnotes.example/currency"),
        ]
        let pages = [
            page("Rounding half to even", lastUs: WorkClock.us(0, 14, 35), moments: [9, 8, 7]),
            page("Currency math without floats", path: "/currency", days: 2, lastUs: WorkClock.us(3, 16), moments: [6, 5]),
            page("Once", path: "/once", lastUs: WorkClock.us(0, 9), moments: [4]),
        ]
        let model = WebPagesModel(work: PreviewWorkReader(snapshot: WorkSnapshot(pages: pages)),
                                  reader: WorkMomentsReader(moments), calendar: WorkClock.calendar, now: { WorkClock.now })
        await model.reload()
        let rows = model.rows
        await model.select(rows[0].id)
        let today = try? XCTUnwrap(model.readOn(rows[0]))
        XCTAssertEqual(today?.lead, "Read 2 times today:", "two minutes apart is one visit")
        XCTAssertEqual(today?.moments.map(\.id), [9, 7])

        await model.select(rows[1].id)
        let days = try? XCTUnwrap(model.readOn(rows[1]))
        XCTAssertEqual(days?.lead, "Read on 2 days:")
        XCTAssertEqual(days?.moments.map(\.id), [6, 5])
        XCTAssertNil(model.readOn(rows[0]), "only the selected row reads its times")

        await model.select(rows[2].id)
        XCTAssertNil(model.readOn(rows[2]), "read once: no line")
        await model.select(nil)
        XCTAssertNil(model.selected)
    }

    func testDateSectionsAreAppleNotesOwn() {
        let calendar = WorkClock.calendar
        let now = WorkClock.now
        XCTAssertEqual(DateSections.title(for: WorkClock.us(0, 1), now: now, calendar: calendar), WorkCopy.today)
        XCTAssertEqual(DateSections.title(for: WorkClock.us(1, 23), now: now, calendar: calendar), WorkCopy.yesterday)
        XCTAssertEqual(DateSections.title(for: WorkClock.us(6, 9), now: now, calendar: calendar), WorkCopy.previous7Days)
        XCTAssertEqual(DateSections.title(for: WorkClock.us(29, 9), now: now, calendar: calendar),
                       WorkCopy.previous30Days)
        XCTAssertEqual(DateSections.title(for: WorkClock.us(60, 9), now: now, calendar: calendar), "August")
        XCTAssertEqual(DateSections.title(for: WorkClock.us(400, 9), now: now, calendar: calendar), "September 2025")
    }
}
