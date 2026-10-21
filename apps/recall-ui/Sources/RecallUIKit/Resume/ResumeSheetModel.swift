import Foundation

/// What Resume can ask of the Mac, behind a seam: the app uses the system
/// (`SystemResumeWorkspace`), and tests and renders use fakes, so they never
/// open anything or look at what is installed.
public protocol ResumeWorkspace: Sendable {
    /// The app with `bundleId`, when it is on this Mac.
    func appURL(bundleId: String) -> URL?
    /// Whether a folder or file is there, with `~` for the home folder.
    func exists(path: String) -> Bool
    /// Open `urls` in the app at `app`: pages as tabs in a browser, a
    /// folder in an editor or a terminal. True when macOS took them.
    func open(_ urls: [URL], withApp app: URL) async -> Bool
    /// Open (or bring forward) the app at `app`.
    func openApp(at app: URL) async -> Bool
    /// The URL of a path with `~` written out, as a folder.
    func folderURL(path: String) -> URL
}

/// The addresses open in a browser's tabs, so Resume never opens one twice
/// where it can tell (SPEC-DELTA 3): AppleScript for the Chrome family and
/// Arc. The addresses are compared in memory and never kept.
public protocol OpenTabsReading: Sendable {
    /// The addresses open in `browser` (a bundle id), and whether macOS was
    /// asked. `mayAsk`: macOS may ask the person for Automation now.
    func openTabs(browser: String, mayAsk: Bool) async -> OpenTabsAnswer
}

/// What a browser said about its open tabs.
public struct OpenTabsAnswer: Equatable, Sendable {
    /// The addresses open in its normal windows: empty when it isn't
    /// running; nil when Hippocampus can't tell (not allowed, or no way to
    /// ask).
    public var addresses: [String]?
    /// Whether macOS was asked about Automation for it this time. A browser
    /// that isn't running can't be asked about, so its one question waits.
    public var asked: Bool

    public init(addresses: [String]?, asked: Bool = false) {
        self.addresses = addresses
        self.asked = asked
    }

    /// Not running: no tabs, and nothing asked.
    public static let notRunning = OpenTabsAnswer(addresses: [])
    /// No way to tell, and nothing asked.
    public static let unknown = OpenTabsAnswer(addresses: nil)
}

/// What Resume never offers, whatever the plan says: the apps and sites
/// Hippocampus never reads, and what the person's own rules leave out.
public struct ResumeRules: Sendable {
    public let isNeverReadApp: @Sendable (String) -> Bool
    public let isNeverReadSite: @Sendable (String) -> Bool
    /// A title the never-read list names by a part of it, as Ask {Tool}
    /// leaves it out: a page or document remembered before the rule.
    public let isNeverReadTitle: @Sendable (String) -> Bool

    public init(isNeverReadApp: @escaping @Sendable (String) -> Bool,
                isNeverReadSite: @escaping @Sendable (String) -> Bool,
                isNeverReadTitle: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.isNeverReadApp = isNeverReadApp
        self.isNeverReadSite = isNeverReadSite
        self.isNeverReadTitle = isNeverReadTitle
    }

    /// No rules: what tests and renders use.
    public static let none = ResumeRules(isNeverReadApp: { _ in false }, isNeverReadSite: { _ in false })
}

/// One row of the Resume sheet.
public struct ResumeRow: Identifiable, Equatable, Sendable {
    /// The sheet's groups, in order.
    public enum Group: Int, CaseIterable, Sendable {
        case code, documents, pages, apps

        public var title: String {
            switch self {
            case .code: WorkCopy.resumeCode
            case .documents: WorkCopy.resumeDocuments
            case .pages: WorkCopy.resumePages
            case .apps: WorkCopy.resumeApps
            }
        }
    }

    public let target: ResumePlan.Target
    public let group: Group
    /// Whether it will open.
    public var ticked: Bool
    /// Whether it can be ticked at all.
    public let available: Bool
    /// The line under its title: why it can't open, what opening it does,
    /// or where it opens.
    public let detail: String?
    /// The name of the app it opens in.
    public let appName: String

    public var id: String { target.id }
}

/// The Resume sheet (SPEC-DELTA 3): the plan from the item's last session,
/// a checkbox each, what will open as the ticks change, and opening only
/// on the click. It sends nothing anywhere: it asks macOS to open things.
@MainActor
public final class ResumeSheetModel: ObservableObject {
    public enum State: Equatable {
        case loading
        case ready
        case failed
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var rows: [ResumeRow] = []
    @Published public private(set) var plan: ResumePlan?
    @Published public private(set) var isOpening = false

    public let itemId: String
    private let planner: any ResumePlanning
    private let workspace: any ResumeWorkspace
    private let tabs: any OpenTabsReading
    private let rules: ResumeRules
    private let asked: (any KeyValueStore)?
    private let appName: (String) -> String
    /// The window reads Demo Memory: what the made-up week invented says
    /// so, and never opens (`isMadeUp`).
    private let madeUp: Bool

    public init(
        itemId: String,
        planner: any ResumePlanning,
        workspace: any ResumeWorkspace,
        tabs: any OpenTabsReading,
        rules: ResumeRules = .none,
        asked: (any KeyValueStore)? = nil,
        appName: @escaping (String) -> String = { Formatters.appDisplayName($0) },
        madeUp: Bool = false
    ) {
        self.itemId = itemId
        self.planner = planner
        self.workspace = workspace
        self.tabs = tabs
        self.rules = rules
        self.asked = asked
        self.appName = appName
        self.madeUp = madeUp
    }

    /// Read the plan and make the rows.
    public func load() async {
        state = .loading
        do {
            let plan = try await planner.plan(item: itemId)
            self.plan = plan
            rows = makeRows(plan)
            state = .ready
        } catch is CancellationError {
            return
        } catch {
            rows = []
            state = .failed
        }
    }

    /// The rows a plan becomes. Never-read apps and sites are left out
    /// whatever the plan says; an app not on this Mac can't be ticked and
    /// says so; a folder that's gone says so. In Demo Memory, what the
    /// made-up week invented says that, and can't be ticked.
    func makeRows(_ plan: ResumePlan) -> [ResumeRow] {
        plan.items.compactMap { target -> ResumeRow? in
            if let app = target.app, rules.isNeverReadApp(app) { return nil }
            if let url = target.url, rules.isNeverReadSite(url) { return nil }
            if rules.isNeverReadTitle(target.title) { return nil }
            let name = target.app.map(appName) ?? ""
            let group = Self.group(of: target)
            var blocked: String?
            if let note = target.note {
                blocked = note
            } else if madeUp, Self.isMadeUp(target) {
                blocked = WorkCopy.resumeMadeUp
            } else if target.reason == "missing" {
                blocked = WorkCopy.resumeMissing(Self.lastPart(of: target.path) ?? target.title)
            } else if target.reason == "no_address" {
                blocked = WorkCopy.resumeNoAddress
            } else if let app = target.app, workspace.appURL(bundleId: app) == nil {
                blocked = WorkCopy.resumeNotInstalled(name)
            } else if let path = target.path, target.url == nil, !workspace.exists(path: path) {
                blocked = WorkCopy.resumeMissing(Self.lastPart(of: path) ?? target.title)
            }
            let detail: String? = blocked ?? {
                switch target.reason {
                case "single_note": return WorkCopy.resumeSingleNote
                case "app_only": return WorkCopy.resumeAppOnly(name)
                case "no_folder": return WorkCopy.resumeNoFolder(name)
                default: break
                }
                if group == .code { return WorkCopy.resumeOpensIn(name) }
                if let url = target.url { return Self.shortAddress(url) }
                return nil
            }()
            let available = blocked == nil && target.canOpen
            return ResumeRow(target: target, group: group, ticked: available && target.checked,
                             available: available, detail: detail, appName: name)
        }
    }

    /// In Demo Memory, whether a target is the made-up week's own invention,
    /// so nothing real can open it: every file, folder and document in the
    /// week is made up (`mci_seed_brain/demo_week/story.rs`), except the
    /// project's folder Demo Memory makes (`isDemoProjectFolder`), and so is a
    /// page with no address or on a made-up site (a name reserved for
    /// examples, such as `foundernotes.example`). Its apps, and its pages on
    /// real sites, are real, and open as they would anywhere.
    static func isMadeUp(_ target: ResumePlan.Target) -> Bool {
        if isDemoProjectFolder(target) { return false }
        if target.path != nil || target.kind == "folder" || target.kind == "document" { return true }
        if target.reason == "missing" || target.reason == "no_address" { return true }
        guard let address = target.url else { return false }
        return isExampleSite(address)
    }

    /// Demo Memory's own folder, as the made-up week's Terminal titles write
    /// it (`PROJECT_FOLDER` in `mci_seed_brain/demo_week/story.rs`).
    static let demoMemoryFolder = "~/Library/Application Support/Hippocampus/Demo Memory/"

    /// The one real thing in the made-up week: the project's folder, which
    /// Demo Memory makes, empty, inside its own folder, so Resume can reopen
    /// it in the editor and Terminal. Only a folder directly inside Demo
    /// Memory's folder counts; whether it is still there is checked as for
    /// any folder.
    static func isDemoProjectFolder(_ target: ResumePlan.Target) -> Bool {
        guard target.kind == "folder", let path = target.path, path.hasPrefix(demoMemoryFolder) else {
            return false
        }
        var name = Substring(path.dropFirst(demoMemoryFolder.count))
        if name.hasSuffix("/") { name = name.dropLast() }
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// A host under a name kept for examples and tests (RFC 2606 and 6761),
    /// which never reaches a real site.
    static func isExampleSite(_ address: String) -> Bool {
        guard let host = URLComponents(string: address)?.host?.lowercased(), !host.isEmpty else { return false }
        for suffix in ["example", "test", "invalid", "localhost"] where host == suffix || host.hasSuffix("." + suffix) {
            return true
        }
        for name in ["example.com", "example.net", "example.org"] where host == name || host.hasSuffix("." + name) {
            return true
        }
        return false
    }

    static func group(of target: ResumePlan.Target) -> ResumeRow.Group {
        switch target.kind {
        case "folder": .code
        case "document": .documents
        case "page": .pages
        default: target.reason == "no_folder" ? .code : .apps
        }
    }

    /// "devnotes.example/rounding", for a page's second line.
    static func shortAddress(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    static func lastPart(of path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }

    /// Tick or untick a row that can open.
    public func toggle(_ id: ResumeRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].available else { return }
        rows[index].ticked.toggle()
    }

    /// The rows in a group, in the plan's order.
    public func rows(in group: ResumeRow.Group) -> [ResumeRow] {
        rows.filter { $0.group == group }
    }

    /// How many tabs and apps the button opens now.
    public var willOpen: (tabs: Int, apps: Int) {
        let ticked = rows.filter(\.ticked)
        return (ticked.filter(\.target.isTab).count, ticked.filter { !$0.target.isTab }.count)
    }

    /// Whether there is anything to open.
    public var canResume: Bool { rows.contains(where: \.ticked) && !isOpening }

    /// Whether the plan has anything at all to list.
    public var isEmpty: Bool { rows.isEmpty }

    /// How many pages the agent ticks: the newest ten (`PAGES_TICKED` in
    /// `resume.rs`).
    public static let pagesTicked = 10

    /// Pages ticked by default are the newest ten: a line says so when the
    /// plan has more.
    public var pagesBeyondTheCap: Bool { rows(in: .pages).filter(\.available).count > Self.pagesTicked }

    /// What the ticked rows open, through macOS only: tabs in the browser
    /// each was read in (not one that is open there already, where the
    /// browser can say), folders in their editor or terminal, apps. Returns
    /// the note the window shows after: "Opened 6 tabs and 2 apps."
    @discardableResult
    public func resume() async -> String {
        guard canResume else { return WorkCopy.resumeOpenedNothing }
        isOpening = true
        defer { isOpening = false }
        let ticked = rows.filter(\.ticked)
        var tabsOpened = 0
        var appsOpened = 0
        var alreadyOpen = 0
        var failed: [String] = []

        // Tabs, browser by browser, in the order the plan lists them.
        var browsers: [String] = []
        var byBrowser: [String: [ResumeRow]] = [:]
        for row in ticked where row.target.isTab {
            let browser = row.target.app ?? ""
            if byBrowser[browser] == nil { browsers.append(browser) }
            byBrowser[browser, default: []].append(row)
        }
        for browser in browsers {
            guard let rowsHere = byBrowser[browser], let app = workspace.appURL(bundleId: browser) else {
                failed.append(contentsOf: (byBrowser[browser] ?? []).map(\.target.title))
                continue
            }
            let open = await openAddresses(in: browser)
            var urls: [URL] = []
            for row in rowsHere {
                guard let address = row.target.url, let url = URL(string: address) else { continue }
                if let open, open.contains(Self.comparable(address)) {
                    alreadyOpen += 1
                } else {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { continue }
            if await workspace.open(urls, withApp: app) {
                tabsOpened += urls.count
            } else {
                failed.append(appName(browser))
            }
        }

        // Folders and apps, one at a time.
        for row in ticked where !row.target.isTab {
            guard let bundle = row.target.app, let app = workspace.appURL(bundleId: bundle) else {
                failed.append(row.appName.isEmpty ? row.target.title : row.appName)
                continue
            }
            let opened: Bool
            if row.target.kind == "folder", let path = row.target.path {
                opened = await workspace.open([workspace.folderURL(path: path)], withApp: app)
            } else {
                opened = await workspace.openApp(at: app)
            }
            if opened {
                appsOpened += 1
            } else {
                failed.append(row.appName)
            }
        }
        return Self.note(tabs: tabsOpened, apps: appsOpened, alreadyOpen: alreadyOpen, failed: failed)
    }

    /// The note after Resume, from what happened.
    static func note(tabs: Int, apps: Int, alreadyOpen: Int, failed: [String]) -> String {
        var parts: [String] = []
        if tabs + apps > 0 {
            parts.append(WorkCopy.resumeOpened(tabs: tabs, apps: apps))
        } else if alreadyOpen == 0 {
            parts.append(WorkCopy.resumeOpenedNothing)
        }
        if alreadyOpen > 0 { parts.append(WorkCopy.resumeAlreadyOpen(alreadyOpen)) }
        if let first = failed.first { parts.append(WorkCopy.resumeCouldntOpen(first)) }
        return parts.joined(separator: " ")
    }

    /// The addresses open in a browser now, compared without scheme, "www.",
    /// query, fragment or a closing slash. macOS may ask for Automation only
    /// the first time Resume opens tabs in that browser while it is running;
    /// after that, a browser Hippocampus may not ask simply opens them again.
    private func openAddresses(in browser: String) async -> Set<String>? {
        let key = "resume.automation.asked.\(browser)"
        let mayAsk = asked.map { $0.data(forKey: key) == nil } ?? false
        let answer = await tabs.openTabs(browser: browser, mayAsk: mayAsk)
        // Only a question macOS really asked uses it up: with the browser
        // closed there was nothing to ask, so the next Resume still may.
        if mayAsk, answer.asked { asked?.set(Data([1]), forKey: key) }
        return answer.addresses.map { Set($0.map(Self.comparable)) }
    }

    /// An address as tabs are compared: host and path, lower-case host.
    static func comparable(_ address: String) -> String {
        guard let components = URLComponents(string: address), let host = components.host?.lowercased() else {
            return address
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        let video = components.queryItems?.first(where: { $0.name == "v" })?.value.map { "?v=\($0)" } ?? ""
        return bare + path + (bare.hasSuffix("youtube.com") ? video : "")
    }
}
