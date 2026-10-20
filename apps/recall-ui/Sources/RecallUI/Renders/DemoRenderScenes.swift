#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// The window on Demo Memory (`demo-*`), light and dark: Today, History
    /// with a moment, Ask's results, About You, the window's title with its
    /// Demo tag, and, once those pages exist, a Working On page and AI Tools.
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
            ("ask", .ask(query: "yearly", select: "Prorating yearly upgrades")),
            ("about-you", .place(.you)),
            ("window", .window),
        ]
        // The new pages, once the window has them (WP1 and WP4).
        if RecallRoute(tab: "work") != nil {
            shots.append(("working-on", .workItem))
        }
        if let route = RecallRoute(tab: "ai-tools") {
            shots.append(("ai-tools", .route(route)))
        }
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
    /// show a week under way whenever they are drawn.
    static func afternoonOffset(now: Date) -> Int {
        let hour = Int(now.timeIntervalSince1970) / 3600 % 24
        var offset = (14 - hour + 24) % 24
        if offset > 14 { offset -= 24 }
        return offset * 3600
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
        let store = folder.appendingPathComponent("Demo Memory", isDirectory: true)
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
        let tz = afternoonOffset(now: nowDate)
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
        return DemoRenderWorld(
            folder: folder, database: database, keyHex: keyHex, calendar: calendar, now: nowDate, agent: agent,
            reader: reader, screenshots: CountingDemoScreenshots(provider), understanding: understanding,
            receipt: try? CaptureHealthReceipt.decode(Data(receiptText.utf8)))
    }

    private init(
        folder: URL, database: URL, keyHex: String, calendar: Calendar, now: Date, agent: URL,
        reader: FFIBrainReader, screenshots: CountingDemoScreenshots, understanding: AgentUnderstandingReader,
        receipt: CaptureHealthReceipt?
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
    }

    /// The first Working On item's id, from the agent's `work` read.
    private func firstWorkItem() -> String? {
        let environment = Self.toolEnvironment(home: folder.appendingPathComponent("home"), keyHex: keyHex)
        let offset = calendar.timeZone.secondsFromGMT(for: now)
        guard let data = try? Self.run(agent, ["work", "--json", "--tz-offset-secs", String(offset),
                                               "--db-path", database.path], environment: environment),
              let snapshot = try? JSONDecoder().decode(WorkSnapshot.self, from: data)
        else { return nil }
        return (snapshot.items.first { $0.kind == .code } ?? snapshot.items.first)?.id
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
        let ask = AskViewModel(
            search: SearchViewModel(
                reader: reader,
                persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"], store: NothingKeptHere()),
                userDictionaryLoader: { .empty }),
            history: TimelineViewModel(reader: reader, pageSize: 200, day: MemoryDay(date: now, calendar: calendar),
                                       now: { now }),
            understanding: understanding,
            calendar: calendar)
        let overview = OverviewViewModel(
            understanding: understanding, selectedDate: now, calendar: calendar,
            healthLoader: { receipt }, now: { now },
            deletions: MemoryDeletionSignal(center: NotificationCenter()),
            savedBefore: { try await reader.isAnythingSaved(before: $0) })
        await overview.reload()
        let you = UserModelViewModel(understanding: understanding, verdicts: VerdictInbox(directory: nil),
                                     deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await you.reload()
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
            route = firstWorkItem().map { RecallRoute(workItem: $0) }
        case .window:
            place = .overview
        }
        let view = DemoWindowHost(
            place: place,
            route: route,
            make: { selection, request in
                MemoryWorkspaceView(
                    reader: reader, understanding: self.understanding, selection: selection, routeRequest: request,
                    isSyntheticPreview: false, healthLoader: { receipt }, contextExporter: { _ in "" },
                    calendar: self.calendar, now: { now }, ask: ask, overview: overview, you: you,
                    status: SidebarStatus(receipt: receipt, now: now), isDemoMemory: true)
            })
        return AnyView(view)
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
        var content = await window(shot, dark: dark)
        if case .window = shot {
            content = AnyView(VStack(spacing: 0) {
                DemoTitleBar()
                content.frame(width: size.width, height: size.height - DemoTitleBar.height)
            })
        }
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

/// The window's title bar as the Mac draws it while the window reads Demo
/// Memory: the window's buttons, then the Demo tag. An off-screen render
/// draws no toolbar, so this picture adds it where the window shows it.
private struct DemoTitleBar: View {
    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.373, blue: 0.341), Color(red: 0.996, green: 0.737, blue: 0.180),
                     Color(red: 0.157, green: 0.784, blue: 0.251)], id: \.self) { color in
                Circle().fill(color).frame(width: 12, height: 12)
            }
            Image(systemName: "sidebar.left")
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .padding(.leading, 18)
            DemoTag()
                .padding(.leading, 8)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(MCI.Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(MCI.Color.border).frame(height: 1) }
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
