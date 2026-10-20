import XCTest
@testable import RecallUIKit

/// The Resume sheet (SPEC-DELTA 3) over fakes: nothing opens, nothing is
/// asked of macOS. Rows say why they can't open; never-read apps and sites
/// never show; the newest ten pages are ticked; tabs already open aren't
/// opened again; Automation is asked for only the first time.
@MainActor
final class ResumeSheetModelTests: XCTestCase {
    private let vscode = "com.microsoft.VSCode"
    private let terminal = "com.apple.Terminal"
    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"
    private let notes = "com.apple.Notes"
    private let pages = "com.apple.iWork.Pages"
    private let slack = "com.tinyspeck.slackmacgap"

    private func model(_ items: [ResumePlan.Target], installed: Set<String>? = nil, missing: Set<String> = [],
                       tabs: FakeTabs = FakeTabs(), asked: (any KeyValueStore)? = nil,
                       workspace: FakeWorkspace? = nil, rules: ResumeRules = .none) -> (ResumeSheetModel, FakeWorkspace) {
        let workspace = workspace ?? FakeWorkspace(
            installed: installed ?? [vscode, terminal, chrome, safari, notes, pages, slack], missing: missing)
        let plan = ResumePlan(items: items, item: .init(name: "trailhead-shop", kind: "code"),
                              session: .init(startUs: WorkClock.us(0, 14), endUs: WorkClock.us(0, 14, 35)))
        let model = ResumeSheetModel(itemId: "w_5c1e8a0d2f9b47e3a6d1", planner: PreviewResumePlans(plans: [
            "w_5c1e8a0d2f9b47e3a6d1": plan,
        ]), workspace: workspace, tabs: tabs, rules: rules, asked: asked, appName: { Self.name($0) })
        return (model, workspace)
    }

    nonisolated private static func name(_ bundle: String) -> String {
        [
            "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal", "com.google.Chrome": "Chrome",
            "com.apple.Safari": "Safari", "com.apple.Notes": "Notes", "com.apple.iWork.Pages": "Pages",
            "com.tinyspeck.slackmacgap": "Slack", "com.example.Sketchpad": "Sketchpad",
        ][bundle] ?? bundle
    }

    private var sessionPlan: [ResumePlan.Target] {
        [
            .init(kind: "folder", title: "trailhead-shop", app: vscode, path: "~/dev/trailhead-shop"),
            .init(kind: "folder", title: "trailhead-shop", app: terminal, path: "~/dev/trailhead-shop"),
            .init(kind: "document", title: "Q4 planning", app: chrome, url: "https://docs.google.com/document/d/q4/edit"),
            .init(kind: "document", title: "Launch checklist", app: notes, reason: "single_note"),
            .init(kind: "document", title: "Pricing letter", app: pages, reason: "app_only"),
            .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
            .init(kind: "page", title: "Seat-based pricing", app: chrome, url: "https://saasguide.example/pricing/seats"),
            .init(kind: "page", title: "Plans and pricing", app: safari, url: "https://spokeandchain.example/plans"),
            .init(kind: "page", title: "A page read without its address", app: safari, checked: false,
                  reason: "no_address"),
            .init(kind: "app", title: "Slack", app: slack),
            .init(kind: "app", title: "Sketchpad", app: "com.example.Sketchpad"),
        ]
    }

    func testRowsGroupAndSayWhatOpensOrWhyItCant() async {
        let (model, _) = model(sessionPlan)
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, model.rows.count, "the editor and Terminal rows are two")
        XCTAssertEqual(model.rows(in: .code).map(\.detail), ["Opens in VS Code", "Opens in Terminal"])
        XCTAssertEqual(model.rows(in: .documents).map(\.detail), [
            "docs.google.com/document/d/q4/edit", WorkCopy.resumeSingleNote, WorkCopy.resumeAppOnly("Pages"),
        ])
        XCTAssertEqual(model.rows(in: .pages).map(\.detail), [
            "devnotes.example/rounding", "saasguide.example/pricing/seats", "spokeandchain.example/plans",
            WorkCopy.resumeNoAddress,
        ])
        XCTAssertEqual(model.rows(in: .apps).map(\.detail), [nil, WorkCopy.resumeNotInstalled("Sketchpad")])
        XCTAssertEqual(model.rows.filter(\.ticked).count, 9)
        XCTAssertEqual(model.rows.filter { !$0.available }.map(\.target.title),
                       ["A page read without its address", "Sketchpad"])
        XCTAssertEqual(model.willOpen.tabs, 4, "a document's link opens as a tab")
        XCTAssertEqual(model.willOpen.apps, 5)
        XCTAssertTrue(model.canResume)
        XCTAssertFalse(model.pagesBeyondTheCap)
    }

    func testAFolderThatIsGoneSaysSoAndCantBeTicked() async {
        let (model, _) = model([
            .init(kind: "folder", title: "trailhead-shop", app: vscode, path: "~/dev/trailhead-shop"),
            .init(kind: "folder", title: "bike-api", app: vscode, path: "~/dev/bike-api", checked: false,
                  reason: "missing"),
            .init(kind: "app", title: "Cursor", app: vscode, reason: "no_folder"),
        ], missing: ["~/dev/trailhead-shop"])
        await model.load()
        XCTAssertEqual(model.rows.map(\.detail), [WorkCopy.resumeMissing("trailhead-shop"),
                                                  WorkCopy.resumeMissing("bike-api"), WorkCopy.resumeNoFolder("VS Code")])
        XCTAssertEqual(model.rows.map(\.available), [false, false, true])
        XCTAssertEqual(model.rows.map(\.group), [.code, .code, .code], "an editor without its folder is still code")
        model.toggle(model.rows[0].id)
        XCTAssertFalse(model.rows[0].ticked, "a row that can't open can't be ticked")
    }

    func testNeverReadAppsAndSitesAreNeverOfferedWhateverThePlanSays() async {
        let rules = ResumeRules(isNeverReadApp: { $0 == "com.1password.1password" },
                                isNeverReadSite: { $0.contains("bank.example") })
        let (model, _) = model([
            .init(kind: "app", title: "1Password", app: "com.1password.1password"),
            .init(kind: "page", title: "Statements", app: chrome, url: "https://bank.example/statements"),
            .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
        ], installed: ["com.1password.1password", chrome], rules: rules)
        await model.load()
        XCTAssertEqual(model.rows.map(\.target.title), ["Rounding half to even"])
    }

    func testTheSystemRulesLeaveOutPasswordAppsAndThePersonsOwnList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resume-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = folder.appendingPathComponent("denylist.toml")
        try """
            [[denylist]]
            kind = "urlPrefix"
            pattern = "https://bank.example/"

            [[denylist]]
            kind = "appBundle"
            pattern = "com.example.Diary"

            """.write(to: list, atomically: true, encoding: .utf8)
        let rules = ResumeRules.system(userList: list)
        XCTAssertTrue(rules.isNeverReadApp("com.1password.1password"))
        XCTAssertTrue(rules.isNeverReadApp("com.example.Diary"))
        XCTAssertFalse(rules.isNeverReadApp(chrome))
        XCTAssertTrue(rules.isNeverReadSite("https://bank.example/statements"))
        XCTAssertFalse(rules.isNeverReadSite("https://devnotes.example/rounding"))
        let without = ResumeRules.system(userList: folder.appendingPathComponent("none.toml"))
        XCTAssertFalse(without.isNeverReadApp("com.example.Diary"), "no list, only the built-in one")
        XCTAssertTrue(without.isNeverReadApp("com.1password.1password"))
    }

    /// A window title the person's never-read list names (`windowTitleSubstring`,
    /// as Ask {Tool}'s builder honours it) is never offered by Resume, even
    /// when it was remembered before the rule (from the privacy verifier).
    func testATitleOnTheNeverReadListIsNeverOffered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resume-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = folder.appendingPathComponent("denylist.toml")
        try """
            [[denylist]]
            kind = "windowTitleSubstring"
            pattern = "Payroll"

            """.write(to: list, atomically: true, encoding: .utf8)
        let rules = ResumeRules.system(userList: list)
        let (model, _) = model([
            .init(kind: "document", title: "Payroll October", app: chrome,
                  url: "https://docs.google.com/spreadsheets/d/pay/edit"),
            .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
        ], installed: [chrome], rules: rules)
        await model.load()
        XCTAssertEqual(model.rows.map(\.target.title), ["Rounding half to even"],
                       "a title on the never-read list is offered")
        // Titles match as the capture helper matches them: the part as
        // written, and a private window's own words.
        XCTAssertFalse(rules.isNeverReadTitle("payroll notes"))
        XCTAssertTrue(rules.isNeverReadTitle("New Incognito Tab"))
        XCTAssertFalse(ResumeRules.system(userList: folder.appendingPathComponent("none.toml"))
            .isNeverReadTitle("Payroll October"), "no list, no title of the person's")
        XCTAssertFalse(ResumeRules.none.isNeverReadTitle("Payroll October"))
    }

    func testTheNewestTenPagesAreTickedAndTheSheetSaysSo() async {
        let pagesPlan: [ResumePlan.Target] = (0..<12).map { index in
            .init(kind: "page", title: "Page \(index)", app: chrome, url: "https://pages.example/\(index)",
                  checked: index < ResumeSheetModel.pagesTicked)
        }
        let (model, _) = model(pagesPlan)
        await model.load()
        XCTAssertTrue(model.pagesBeyondTheCap)
        XCTAssertEqual(model.willOpen.tabs, 10)
        XCTAssertEqual(model.rows.filter(\.ticked).map(\.target.title), (0..<10).map { "Page \($0)" })
        model.toggle(model.rows[11].id)
        XCTAssertEqual(model.willOpen.tabs, 11, "the person can tick more")
        for row in model.rows where row.ticked { model.toggle(row.id) }
        XCTAssertFalse(model.canResume)
        let note = await model.resume()
        XCTAssertEqual(note, WorkCopy.resumeOpenedNothing)
    }

    func testResumeOpensTabsBrowserByBrowserSkipsOpenOnesAndOpensFoldersAndApps() async {
        let tabs = FakeTabs(open: [chrome: ["https://www.devnotes.example/rounding/", "https://other.example/"]])
        let (model, workspace) = model(sessionPlan, tabs: tabs)
        await model.load()
        let note = await model.resume()
        XCTAssertEqual(note, "Opened 3 tabs and 5 apps. 1 was already open.")
        let opened = workspace.opened
        XCTAssertEqual(opened.map(\.app.lastPathComponent), [
            "com.google.Chrome.app", "com.apple.Safari.app", "com.microsoft.VSCode.app", "com.apple.Terminal.app",
        ])
        XCTAssertEqual(opened[0].urls.map(\.absoluteString), [
            "https://docs.google.com/document/d/q4/edit", "https://saasguide.example/pricing/seats",
        ], "Rounding half to even was open already")
        XCTAssertEqual(opened[2].urls, [URL(fileURLWithPath: "/Users/sam/dev/trailhead-shop", isDirectory: true)])
        XCTAssertEqual(workspace.launched.map(\.lastPathComponent),
                       ["com.apple.Notes.app", "com.apple.iWork.Pages.app", "com.tinyspeck.slackmacgap.app"])
        XCTAssertEqual(tabs.asked.map(\.browser), [chrome, safari])
        XCTAssertEqual(tabs.asked.map(\.mayAsk), [false, false], "without a place to remember, it never asks")
        XCTAssertFalse(model.isOpening)
    }

    func testAutomationIsAskedForOnlyTheFirstTimeInEachBrowser() async {
        let store = MemoryKeyValueStore()
        let tabs = FakeTabs()
        let plan: [ResumePlan.Target] = [
            .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
        ]
        let (first, _) = model(plan, tabs: tabs, asked: store)
        await first.load()
        _ = await first.resume()
        let (second, _) = model(plan, tabs: tabs, asked: store)
        await second.load()
        _ = await second.resume()
        XCTAssertEqual(tabs.asked.map(\.mayAsk), [true, false])
        XCTAssertNotNil(store.data(forKey: "resume.automation.asked.\(chrome)"))
    }

    func testWhatCouldNotOpenIsNamedAndTheRestStillOpens() async {
        let workspace = FakeWorkspace(installed: [chrome, slack], missing: [], failing: [chrome])
        let (model, _) = model([
            .init(kind: "page", title: "Rounding half to even", app: chrome, url: "https://devnotes.example/rounding"),
            .init(kind: "app", title: "Slack", app: slack),
        ], workspace: workspace)
        await model.load()
        let note = await model.resume()
        XCTAssertEqual(note, "Opened 1 app. Couldn\u{2019}t open Chrome.")
    }

    func testAPlanThatCantBeReadSaysSo() async {
        let model = ResumeSheetModel(itemId: "w_1", planner: FailingPlanner(),
                                     workspace: FakeWorkspace(installed: [], missing: []), tabs: FakeTabs())
        await model.load()
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.rows.isEmpty)
        let empty = ResumeSheetModel(itemId: "w_1", planner: NoResumePlans(),
                                     workspace: FakeWorkspace(installed: [], missing: []), tabs: FakeTabs())
        await empty.load()
        XCTAssertEqual(empty.state, .ready)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.canResume)
    }

    func testTabsAreComparedByHostAndPathOnly() {
        XCTAssertEqual(ResumeSheetModel.comparable("https://www.DevNotes.example/rounding/?utm=1#top"),
                       "devnotes.example/rounding")
        XCTAssertEqual(ResumeSheetModel.comparable("https://www.youtube.com/watch?v=abc123&t=42"),
                       "youtube.com/watch?v=abc123", "a video is its id")
        XCTAssertEqual(ResumeSheetModel.comparable("not a url"), "not a url")
        XCTAssertEqual(ResumeSheetModel.shortAddress("https://www.devnotes.example/rounding/"), "devnotes.example/rounding")
    }

    func testTheNoteAfterSaysWhatHappenedPlainly() {
        XCTAssertEqual(ResumeSheetModel.note(tabs: 6, apps: 2, alreadyOpen: 0, failed: []), "Opened 6 tabs and 2 apps.")
        XCTAssertEqual(ResumeSheetModel.note(tabs: 1, apps: 0, alreadyOpen: 0, failed: []), "Opened 1 tab.")
        XCTAssertEqual(ResumeSheetModel.note(tabs: 0, apps: 0, alreadyOpen: 2, failed: []), "2 were already open.")
        XCTAssertEqual(ResumeSheetModel.note(tabs: 0, apps: 0, alreadyOpen: 0, failed: []), "Nothing opened.")
        XCTAssertEqual(ResumeSheetModel.note(tabs: 0, apps: 0, alreadyOpen: 0, failed: ["Slack", "Chrome"]),
                       "Nothing opened. Couldn\u{2019}t open Slack.")
        for text in [WorkCopy.resumeWillOpen(tabs: 3, apps: 1), WorkCopy.resumeOpened(tabs: 1, apps: 1),
                     WorkCopy.resumeLead(name: "trailhead-shop", when: "today at 2:35 PM"), WorkCopy.resumeSingleNote,
                     WorkCopy.resumeNoAddress, WorkCopy.resumeNewestTicked(10), WorkCopy.resumeMissing("bike-api"),
                     WorkCopy.resumeAppOnly("Pages"), WorkCopy.resumeNoFolder("Cursor")] {
            XCTAssertNil(CopyStyleValidator.containsJargon(text), text)
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(text), text)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(text), text)
        }
    }
}

// MARK: Fakes

/// A Mac with `installed` apps, where `missing` paths are gone and opening
/// in a `failing` app fails. It keeps what it was asked to open.
final class FakeWorkspace: ResumeWorkspace, @unchecked Sendable {
    let installed: Set<String>
    let missing: Set<String>
    let failing: Set<String>
    private let lock = NSLock()
    private var openedURLs: [(urls: [URL], app: URL)] = []
    private var launchedApps: [URL] = []

    init(installed: Set<String>, missing: Set<String>, failing: Set<String> = []) {
        self.installed = installed
        self.missing = missing
        self.failing = failing
    }

    var opened: [(urls: [URL], app: URL)] { lock.withLock { openedURLs } }
    var launched: [URL] { lock.withLock { launchedApps } }

    func appURL(bundleId: String) -> URL? {
        installed.contains(bundleId) ? URL(fileURLWithPath: "/Applications/\(bundleId).app") : nil
    }

    func exists(path: String) -> Bool { !missing.contains(path) }

    func open(_ urls: [URL], withApp app: URL) async -> Bool {
        lock.withLock { openedURLs.append((urls, app)) }
        return !failing.contains(app.deletingPathExtension().lastPathComponent)
    }

    func openApp(at app: URL) async -> Bool {
        lock.withLock { launchedApps.append(app) }
        return !failing.contains(app.deletingPathExtension().lastPathComponent)
    }

    func folderURL(path: String) -> URL {
        URL(fileURLWithPath: path.replacingOccurrences(of: "~", with: "/Users/sam"), isDirectory: true)
    }
}

/// Browsers' tabs from fixtures; it keeps whether it was allowed to ask.
final class FakeTabs: OpenTabsReading, @unchecked Sendable {
    let open: [String: [String]]
    private let lock = NSLock()
    private var calls: [(browser: String, mayAsk: Bool)] = []

    init(open: [String: [String]] = [:]) {
        self.open = open
    }

    var asked: [(browser: String, mayAsk: Bool)] { lock.withLock { calls } }

    func openTabs(browser: String, mayAsk: Bool) async -> [String]? {
        lock.withLock { calls.append((browser, mayAsk)) }
        return open[browser]
    }
}

private struct FailingPlanner: ResumePlanning {
    func plan(item: String) async throws -> ResumePlan { throw UnderstandingError.unavailable }
}
