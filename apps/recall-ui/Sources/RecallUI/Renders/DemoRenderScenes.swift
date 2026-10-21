#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// The window on Demo Memory (`demo-*`), light and dark: Today, History
    /// with a moment (a Stripe page, code, a documentation page), Ask's
    /// results, About You, the window's title with its Demo tag, a Working
    /// On page and all of Working On, Web Pages, Looked Up, AI Tools,
    /// Privacy and Resume's sheet.
    /// These are the launch video's and the website's pictures.
    ///
    /// The week is made the way the app makes it, by the same tools, into a
    /// temporary folder with a development key and a temporary home: the
    /// seeder's screen list, `demo-screens` drawing and sealing each
    /// screenshot, then the seeder writing the week. The window then reads it
    /// as it reads any memory: moments, readings and screenshots through the
    /// FFI and the codec, Today and About You through `mci-agent`. Nothing of
    /// the person's is read; the folder goes when the renderer exits.
    ///
    /// The tools are found beside the repository's build products, or named
    /// by `MCI_DEMO_SEEDER`, `MCI_DEMO_SCREENS` and `MCI_AGENT_PATH`. Without
    /// them these scenes say so and draw nothing.
    static var demoScenes: [Scene] {
        var shots: [(String, DemoRenderWorld.Shot)] = [
            ("today", .place(.overview)),
            ("history", .history(select: "Product catalog")),
            ("history-code", .history(select: "billing.ts")),
            // A documentation page as it read: headings, paragraphs, code.
            ("history-article", .history(select: "Prorations")),
            ("ask", .ask(query: "yearly", select: "Prorating yearly upgrades")),
            ("about-you", .place(.you)),
            ("window", .window),
        ]
        // Working On, its pages and the rest of the new window (WP1, WP4).
        shots += [
            ("working-on", .workItem),
            ("working-on-all", .place(.workingOn)),
            ("web-pages", .place(.webPages)),
            ("looked-up", .place(.lookedUp)),
            ("ai-tools", .place(.aiTools)),
            ("privacy", .place(.privacy)),
            ("resume", .resume),
        ]
        return shots.flatMap { name, shot in
            [false, true].map { dark in
                Scene.picture("demo-\(name)-\(dark ? "dark" : "light")", size: DemoRenderWorld.size, dark: dark) {
                    await DemoRenderWorld.picture(shot, dark: dark)
                }
            }
        }
    }
}

/// Demo Memory, made once for the renderer and read as the app reads it.
@MainActor
final class DemoRenderWorld {
    /// The pictures' size: the window at 16:10, drawn at 2x.
    static let size = CGSize(width: 1280, height: 800)

    enum Shot {
        case place(MemoryWorkspaceSelection)
        /// History on today, with the newest moment whose title holds this.
        case history(select: String)
        /// Ask's results for `query`, with the match whose title holds `select`.
        case ask(query: String, select: String)
        case route(RecallRoute)
        /// The first Working On item, from the agent's `work` read.
        case workItem
        /// Resume's sheet for that item: what it would open.
        case resume
        /// The window with its title bar and Demo tag.
        case window
    }

    let folder: URL
    let database: URL
    let keyHex: String
    let calendar: Calendar
    let now: Date
    let agent: URL
    let reader: FFIBrainReader
    let screenshots: CountingDemoScreenshots
    let understanding: AgentUnderstandingReader
    let receipt: CaptureHealthReceipt?
    /// Working On, Web Pages, Looked Up and Resume's plans: the agent's own
    /// reads of the made-up week.
    let work: AgentWorkReader
    /// Ask {Tool}'s builder and AI Tools' read, from the made-up Mac.
    let client: SendCardClient
    /// The week's made-up calendar, beside its memory.
    let calendarReader: DemoCalendar

    private static var made: DemoRenderWorld?
    private static var failed = false
    /// The folder to remove when the renderer exits.
    nonisolated(unsafe) private static var folderToRemove: String?

    /// The world, made on first use.
    static func shared() -> DemoRenderWorld? {
        if let made { return made }
        guard !failed else { return nil }
        do {
            made = try make()
        } catch {
            failed = true
            FileHandle.standardError.write(Data("demo scenes: \(error)\n".utf8))
        }
        return made
    }

    struct MakeError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Making the week

    private static func repositoryRoot() -> URL? {
        var url = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = url, current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Cargo.toml").path),
               FileManager.default.fileExists(atPath: current.appendingPathComponent("apps/demo-memory").path) {
                return current
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func tool(_ variable: String, _ relative: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment[variable], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let root = repositoryRoot() else { throw MakeError(description: "no repository found for \(relative)") }
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MakeError(description: "build \(relative) first, or name it with \(variable)")
        }
        return url
    }

    /// A whole-hour offset that puts now in the afternoon, so the pictures
    /// show a week under way whenever they are drawn; or at `hour` (0 to 23),
    /// to see the week as it looks then, as when the day's work is done.
    static func afternoonOffset(now: Date, hour wanted: Int = 14) -> Int {
        let hour = Int(now.timeIntervalSince1970) / 3600 % 24
        var offset = (wanted - hour + 24) % 24
        if offset > 14 { offset -= 24 }
        return offset * 3600
    }

    /// The hour the pictures are drawn at: `MCI_DEMO_RENDER_HOUR`, or 2 PM.
    static var renderHour: Int {
        guard let value = ProcessInfo.processInfo.environment["MCI_DEMO_RENDER_HOUR"], let hour = Int(value),
              (0...23).contains(hour) else { return 14 }
        return hour
    }

    /// What every tool and agent read here runs with, and nothing else: a
    /// temporary home, the development key for the made-up week, and a
    /// Keychain service that names no item, so no lookup can ever reach the
    /// person's own.
    static func toolEnvironment(home: URL, keyHex: String) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
            "MCI_DEVELOPMENT_FILE_KEY": "1", "MCI_DB_KEY_HEX": keyHex,
            "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.tests.demo-render-no-item",
            "MCI_DB_KEYCHAIN_ACCOUNT": "none", "MCI_DB_KEYCHAIN_STORAGE_MODEL": "file-keychain-acl-v1",
        ]
    }

    /// One agent read, with `environment` exactly, within `timeout`.
    nonisolated static func runAgent(
        _ command: ContextHandoffCommand, timeout: TimeInterval, environment: [String: String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                process.terminate()
                throw UnderstandingError.unavailable
            }
            let data = await reader.value
            guard process.terminationStatus == 0 else { throw UnderstandingError.unavailable }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// One agent read with `input` on its standard input (the builder's
    /// request), with `environment` exactly, within `timeout`.
    nonisolated static func runAgent(
        _ command: ContextHandoffCommand, input: Data, timeout: TimeInterval, environment: [String: String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.environment = environment
            let output = Pipe()
            let stdin = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try process.run()
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                process.terminate()
                throw UnderstandingError.unavailable
            }
            let data = await reader.value
            guard process.terminationStatus == 0 else { throw UnderstandingError.unavailable }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The builder and the `clients` read, run with the made-up week's
    /// environment and nothing else.
    static func sendCardClient(agent: URL, database: URL, environment: [String: String]) -> SendCardClient {
        SendCardClient(
            card: { request in
                let body = try JSONEncoder().encode(request)
                let command = ContextHandoffCommand(executableURL: agent,
                                                    arguments: ["send-card", "--json", "--db-path", database.path])
                let output = try await runAgent(command, input: body, timeout: 20, environment: environment)
                guard let card = try? JSONDecoder().decode(SendCard.self, from: Data(output.utf8)) else {
                    throw SendCardError.failed
                }
                return card
            },
            clients: {
                let command = ContextHandoffCommand(executableURL: agent, arguments: ["clients", "--json"])
                let output = try await runAgent(command, timeout: 20, environment: environment)
                struct Reply: Decodable { let tools: [ClientStatus] }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else {
                    throw SendCardError.failed
                }
                return reply.tools
            })
    }

    private static func run(_ tool: URL, _ arguments: [String], environment: [String: String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MakeError(description: "\(tool.lastPathComponent) failed: \(String(decoding: message, as: UTF8.self))")
        }
        return data
    }

    private static func make() throws -> DemoRenderWorld {
        let seeder = try tool("MCI_DEMO_SEEDER", "target/debug/mci-seed-brain")
        let drawer = try tool("MCI_DEMO_SCREENS", "apps/demo-memory/.build/debug/demo-screens")
        let agent = try tool("MCI_AGENT_PATH", "target/debug/mci-agent")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-demo-memory-render-\(UUID().uuidString)", isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        // Where the app keeps Demo Memory in a home folder, so the made-up
        // project's folder the seeder makes inside it is the one the week's
        // Terminal names, and Resume finds it.
        let store = home.appendingPathComponent("Library/Application Support/Hippocampus/Demo Memory",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        folderToRemove = folder.path
        atexit {
            if let path = DemoRenderWorld.folderToRemove {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        // A development key for this folder only: the made-up week opens
        // with it and nothing else does.
        let keyHex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let nowDate = Date()
        let now = UInt64(nowDate.timeIntervalSince1970 * 1_000_000)
        let tz = afternoonOffset(now: nowDate, hour: renderHour)
        let environment = toolEnvironment(home: home, keyHex: keyHex)
        let clock = ["--now-us", String(now), "--tz-offset-secs", String(tz)]
        let list = folder.appendingPathComponent("screens.json")
        try run(seeder, ["--demo-week", "--print-screens"] + clock, environment: environment).write(to: list)
        let manifest = folder.appendingPathComponent("manifest.json")
        _ = try run(drawer, ["--spec", list.path, "--blob-root", store.appendingPathComponent("blobs").path,
                             "--manifest", manifest.path], environment: environment)
        let database = store.appendingPathComponent("mci.sqlite")
        _ = try run(seeder, ["--demo-week", "--screens", manifest.path, "--db-path", database.path] + clock,
                    environment: environment)
        // The made-up Mac has Claude Code connected, so Today shows what
        // the founder's AI starts with: its session hook, in the temporary
        // home's own settings.
        try connectClaudeCode(home: home, database: database)
        // Remembering, as the made-up Mac would say it: Today shows Now.
        let stampFormat = ISO8601DateFormatter()
        stampFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = stampFormat.string(from: nowDate)
        let receiptText = """
            {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)",
             "stored_frame_count": 1200, "stored_screenshot_count": 240,
             "suppression_reason": null, "blocked_reason": null}
            """
        try Data(receiptText.utf8).write(to: store.appendingPathComponent("capture-status.json"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: tz) ?? .current
        calendar.locale = Locale(identifier: "en_US")
        let reader = try FFIBrainReader(path: database.path, keyHex: keyHex)
        let keyBytes = Data(stride(from: 0, to: keyHex.count, by: 2).map { offset -> UInt8 in
            let start = keyHex.index(keyHex.startIndex, offsetBy: offset)
            return UInt8(keyHex[start..<keyHex.index(start, offsetBy: 2)], radix: 16) ?? 0
        })
        let provider = ThumbnailDataProvider(blobRoot: store.appendingPathComponent("blobs", isDirectory: true),
                                             deletions: MemoryDeletionSignal(center: NotificationCenter())) { keyBytes }
        // Every agent read runs with this environment and no other: the
        // window's own runner would hand the agent the renderer's
        // environment, without the development key, and the agent would
        // then ask the Keychain for the person's key.
        let readEnvironment = environment.merging(["MCI_DB_PATH": database.path, "MCI_AGENT_PATH": agent.path]) { $1 }
        let understanding = AgentUnderstandingReader(
            environment: readEnvironment,
            recallExecutableURL: nil,
            run: { command, timeout in
                try await runAgent(command, timeout: timeout, environment: readEnvironment)
            },
            now: { nowDate },
            calendar: calendar,
            deletions: MemoryDeletionSignal(center: NotificationCenter()),
            verdicts: nil
        )
        let work = AgentWorkReader(
            environment: readEnvironment,
            recallExecutableURL: nil,
            run: { command, timeout in try await runAgent(command, timeout: timeout, environment: readEnvironment) },
            now: { nowDate },
            timeZone: calendar.timeZone,
            deletions: MemoryDeletionSignal(center: NotificationCenter())
        )
        return DemoRenderWorld(
            folder: folder, database: database, keyHex: keyHex, calendar: calendar, now: nowDate, agent: agent,
            reader: reader, screenshots: CountingDemoScreenshots(provider), understanding: understanding,
            receipt: try? CaptureHealthReceipt.decode(Data(receiptText.utf8)), work: work,
            client: sendCardClient(agent: agent, database: database, environment: readEnvironment),
            calendarReader: DemoCalendar(url: store.appendingPathComponent(DemoMemoryMode.calendarFileName)))
    }

    /// Claude Code's settings in `home` with Hippocampus's session hook, as
    /// Connect AI Tools… writes it, naming the made-up week.
    private static func connectClaudeCode(home: URL, database: URL) throws {
        let folder = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let command = "'/Applications/Hippocampus.app/Contents/MacOS/mci-agent' handoff --format claude-hook "
            + "--db-path '\(database.path)'"
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "matcher": "startup|resume|clear|compact",
                    "hooks": [["type": "command", "command": command, "timeout": 10]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("settings.json"))
    }

    private init(
        folder: URL, database: URL, keyHex: String, calendar: Calendar, now: Date, agent: URL,
        reader: FFIBrainReader, screenshots: CountingDemoScreenshots, understanding: AgentUnderstandingReader,
        receipt: CaptureHealthReceipt?, work: AgentWorkReader, client: SendCardClient, calendarReader: DemoCalendar
    ) {
        self.folder = folder
        self.database = database
        self.keyHex = keyHex
        self.calendar = calendar
        self.now = now
        self.agent = agent
        self.reader = reader
        self.screenshots = screenshots
        self.understanding = understanding
        self.receipt = receipt
        self.work = work
        self.client = client
        self.calendarReader = calendarReader
    }

    /// The made-up founder's AI tools: what a Mac with them installed has.
    static let tools: [InstalledTool] = [
        InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app")),
        InstalledTool(tool: .claudeCode, appURL: URL(fileURLWithPath: "/Applications/Claude.app")),
        InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app")),
        InstalledTool(tool: .codex, appURL: URL(fileURLWithPath: "/Applications/Codex.app")),
        InstalledTool(tool: .cursor, appURL: URL(fileURLWithPath: "/Applications/Cursor.app")),
    ]

    /// What the window's pages reach on the made-up week: the agent's reads
    /// of it, its calendar, the made-up Mac's AI tools, and a Resume that
    /// lists what it would open and opens nothing.
    func services() -> WindowServices {
        // The links each made-up app handles (SPEC 5.3.2's detection).
        let schemes: [String: URL] = [
            "claude": URL(fileURLWithPath: "/Applications/Claude.app"),
            "codex": URL(fileURLWithPath: "/Applications/Codex.app"),
            "cursor": URL(fileURLWithPath: "/Applications/Cursor.app"),
        ]
        let chatGPT = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let detector = DestinationDetector(
            appForScheme: { schemes[$0] },
            appForBundle: { DestinationDetector.chatGPTBundles.contains($0) ? chatGPT : nil },
            isExecutable: { _ in false }, environment: [:])
        let now = self.now
        let calendar = self.calendar
        let reader = self.reader
        // Ren last asked Claude, so the buttons read Ask Claude, as on the
        // person's own Mac once they have picked a tool; kept in memory only.
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        return WindowServices(
            searches: work,
            calendar: calendarReader,
            handoff: HandoffServices(client: client, tools: { Self.tools }, choices: choices, notes: .shared,
                                     open: { _ in false }, home: "/Users/ren"),
            resume: ResumeServices(
                planner: work,
                workspace: FixtureResumeWorkspace(installed: [
                    "com.google.Chrome", "com.microsoft.VSCode", "com.apple.Terminal", "com.tinyspeck.slackmacgap",
                    "us.zoom.xos", "notion.id", "com.figma.Desktop",
                ]),
                tabs: NoOpenTabs(), rules: { .none }, asked: nil, madeUp: true),
            aiTools: AIToolsModel(client: client, detector: detector, understanding: understanding,
                                  choices: .ephemeral(), timeZone: calendar.timeZone, now: { now }),
            privacy: {
                AnyView(PrivacyDashboard(reader: reader, mutator: nil, retention: { .standard },
                                         picturesUsage: { nil }, activity: { [] }, now: { now }, calendar: calendar))
            },
            claudeCodeStarts: true)
    }

    /// The first Working On item's id in the agent's `work` read: the code
    /// project when there is one.
    private func firstWorkItem(_ snapshot: WorkSnapshot) -> String? {
        (snapshot.items.first { $0.kind == .code } ?? snapshot.items.first)?.id
    }

    // MARK: Pictures

    /// One picture of the window on the made-up week, drawn once every
    /// screenshot it shows has opened.
    static func picture(_ shot: Shot, dark: Bool) async -> AnyView {
        guard let world = shared() else {
            return AnyView(Text("Demo Memory couldn't be made for this render.").frame(width: size.width, height: size.height))
        }
        let image = await world.snapshot(shot, dark: dark)
        return AnyView(Image(nsImage: image).resizable().frame(width: size.width, height: size.height))
    }

    private func window(_ shot: Shot, dark: Bool) async -> AnyView {
        let receipt = receipt
        let now = now
        let reader = reader
        let work = work
        let services = services()
        let ask = AskViewModel(
            search: SearchViewModel(
                reader: reader,
                persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: NothingKeptHere()),
                userDictionaryLoader: { .empty },
                work: work),
            history: TimelineViewModel(reader: reader, pageSize: 200, day: MemoryDay(date: now, calendar: calendar),
                                       now: { now }),
            understanding: understanding,
            calendar: calendar)
        let overview = OverviewViewModel(
            understanding: understanding, selectedDate: now, calendar: calendar,
            healthLoader: { receipt }, now: { now },
            deletions: MemoryDeletionSignal(center: NotificationCenter()),
            savedBefore: { try await reader.isAnythingSaved(before: $0) },
            reader: reader, work: work, calendarReader: services.calendar, offers: EphemeralKeyValueStore())
        await overview.reload()
        let you = UserModelViewModel(understanding: understanding, verdicts: VerdictInbox(directory: nil),
                                     deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await you.reload()
        // The sidebar as the window reads it: the week's Working On, and
        // the kinds whose own pages find something.
        let snapshot = (try? await work.work(days: 14)) ?? .empty
        var kinds = LibraryKinds.kinds(apps: (try? await reader.listObservedApps(limit: 200, timeFromUs: nil)) ?? [],
                                       snapshot: snapshot)
        for lens in LibraryLens.allCases {
            if await LibraryLensModel.holdsMoments(lens, reader: reader) {
                kinds.insert(lens.place)
            } else {
                kinds.remove(lens.place)
            }
        }
        if let searches = try? await work.searches(hours: 24 * 14, limit: 1), !searches.isEmpty {
            kinds.insert(.lookedUp)
        }
        let preset = WindowShellPreset(sidebar: SidebarModel.make(snapshot: snapshot, kinds: kinds,
                                                                  hides: SidebarHides.Choices()))
        // Working On's pictures, read before the picture is taken.
        let moments = WorkMomentCache()
        await moments.load(snapshot.items.compactMap(\.thumbnailMoment), reader: reader)
        var place = MemoryWorkspaceSelection.overview
        var route: RecallRoute?
        switch shot {
        case .place(let selection):
            place = selection
        case .history(let select):
            place = .ask
            await ask.history.reload()
            if let hit = ask.history.hits.first(where: { ($0.windowTitle ?? "").contains(select) && $0.thumbnailPath != nil }) {
                ask.history.selectedHitId = hit.id
                ask.history.focusDetail()
            }
        case .ask(let query, let select):
            place = .ask
            ask.query = query
            await ask.search.runSearch()
            if let hit = ask.search.hits.first(where: { ($0.windowTitle ?? "").contains(select) }) {
                ask.search.selectedHitId = hit.id
                ask.search.focusDetail()
            }
        case .route(let wanted):
            route = wanted
        case .workItem:
            if let item = firstWorkItem(snapshot) { place = .item(item) }
        case .resume:
            if let item = firstWorkItem(snapshot) { place = .item(item) }
        case .window:
            place = .overview
        }
        let view = DemoWindowHost(
            place: place,
            route: route,
            make: { selection, request in
                MemoryWorkspaceView(
                    reader: reader, understanding: self.understanding, work: work, selection: selection,
                    routeRequest: request, isSyntheticPreview: false, healthLoader: { receipt },
                    contextExporter: { _ in "" }, calendar: self.calendar, now: { now }, ask: ask,
                    overview: overview, you: you,
                    status: WindowStatus(kind: .remembering, title: NavigationCopy.remembering, action: .pause),
                    isDemoMemory: true, hides: SidebarHides(defaults: nil), drawsWindowControls: true,
                    preset: preset, services: services)
            })
        guard case .resume = shot, case let .item(item) = place, let resume = services.resume else {
            return AnyView(view.environment(\.workNow, { now }).environment(\.workMoments, moments))
        }
        // Resume's sheet over the item's page, as macOS shows it at the
        // window's top: a picture can't capture a sheet's own window.
        let model = ResumeSheetModel(itemId: item, planner: resume.planner, workspace: resume.workspace,
                                     tabs: resume.tabs, madeUp: resume.madeUp)
        await model.load()
        let sheet = ResumeSheetContent(model: model, notes: BottomNotes(), now: now, calendar: calendar,
                                       loads: false) {}
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MCI.Color.surfaceElevated))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 35, y: 18)
        return AnyView(
            ZStack(alignment: .top) {
                view
                Color.black.opacity(0.06)
                sheet.padding(.top, 52)
            }
            .environment(\.workNow, { now })
            .environment(\.workMoments, moments)
        )
    }

    private func snapshot(_ shot: Shot, dark: Bool) async -> NSImage {
        let size = Self.size
        // The window formats times in the Mac's own time zone; for the
        // picture that is the week's, then the renderer's again.
        let hours = calendar.timeZone.secondsFromGMT() / 3600
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", hours == 0 ? "Etc/GMT" : "Etc/GMT\(hours > 0 ? "-" : "+")\(abs(hours))", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
        // The shell draws the window's controls with the Demo tag beside
        // them (SPEC-DELTA 6).
        let content = await window(shot, dark: dark)
        let view = content
            .environment(\.controlActiveState, .key)
            .environment(\.overviewThumbnails, screenshots)
            .environment(\.screenshots, screenshots)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.timeZone, calendar.timeZone)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        // Never ordered in: the window only gives the views a place to lay out.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -24_000, y: -24_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        // Ready when the agent's reads have landed and the screenshots have
        // stopped arriving.
        let started = Date()
        var served = -1
        var stableSince = started
        while Date().timeIntervalSince(started) < 20 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
            let count = screenshots.count
            if count != served {
                served = count
                stableSince = Date()
            } else if Date().timeIntervalSince(started) >= 2.5, Date().timeIntervalSince(stableSince) >= 1.2 {
                break
            }
        }
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let rep {
            rep.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil
        let image = NSImage(size: size)
        if let rep { image.addRepresentation(rep) }
        return image
    }
}

/// The window with a place, and a route applied to it once it shows, as the
/// app applies a link.
private struct DemoWindowHost: View {
    @State private var selection: MemoryWorkspaceSelection
    private let request: RecallRouteRequest?
    private let make: (Binding<MemoryWorkspaceSelection>, RecallRouteRequest?) -> MemoryWorkspaceView

    init(place: MemoryWorkspaceSelection, route: RecallRoute?,
         make: @escaping (Binding<MemoryWorkspaceSelection>, RecallRouteRequest?) -> MemoryWorkspaceView) {
        _selection = State(initialValue: place)
        request = route.map { RecallRouteRequest(route: $0, sequence: 1) }
        self.make = make
    }

    var body: some View {
        make($selection, request)
    }
}

/// The renderer's screenshots, opened by the codec from the made-up week's
/// sealed blobs, counted so a picture is taken once they stop arriving.
final class CountingDemoScreenshots: ThumbnailDataProviding, @unchecked Sendable {
    private let inner: ThumbnailDataProvider
    private let lock = NSLock()
    private var served = 0

    init(_ inner: ThumbnailDataProvider) {
        self.inner = inner
    }

    var count: Int { lock.withLock { served } }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        let data = await inner.thumbnailData(for: url, maxPixelSize: maxPixelSize)
        lock.withLock { served += 1 }
        return data
    }

    func screenshotData(for url: URL) async -> Data? {
        let data = await inner.screenshotData(for: url)
        lock.withLock { served += 1 }
        return data
    }
}

/// Nothing typed is kept: the renderer's Ask writes nowhere.
private final class NothingKeptHere: KeyValueStore, Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
#endif
