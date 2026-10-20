// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// How the app makes the made-up week (SPEC-DELTA 6): the bundled tools,
/// told the week's clock and time zone, with the key on standard input and
/// an environment that names no memory and no key. With the real tools
/// (`MCI_DEMO_SEEDER`, `MCI_DEMO_SCREENS`), the week itself: sealed, dated
/// from now, the same for the same clock, and the person's memory untouched.
@MainActor
final class DemoMemoryMakerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_446_060)
    private let zone = TimeZone(secondsFromGMT: -7 * 3600)!

    func testTheToolsGetTheClockAndTheKeyOnStandardInputAndNothingElse() async throws {
        let scratch = try makeScratch()
        let log = scratch.appendingPathComponent("tools.log")
        let seeder = try script(scratch, "mci-seed-brain", """
            printf 'SEEDER %s\\n' "$*" >> '\(log.path)'
            env | sed 's/^/SEEDER-ENV /' >> '\(log.path)'
            case " $* " in
              *" --print-screens "*) printf '{"version":1,"screens":[]}' ;;
              *) printf 'SEEDER-KEY %s\\n' "$(cat)" >> '\(log.path)'
                 printf '{"moments":3,"screenshots":2,"notes":1,"claims":1}' ;;
            esac
            """)
        let drawer = try script(scratch, "demo-screens", """
            printf 'DRAWER %s\\n' "$*" >> '\(log.path)'
            printf 'DRAWER-KEY %s\\n' "$(cat)" >> '\(log.path)'
            env | sed 's/^/DRAWER-ENV /' >> '\(log.path)'
            """)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let folder = DemoMemoryFolder.standard(home: home)
        try folder.prepareEmpty(home: home)
        let key = try folder.makeKey()

        let maker = BundledDemoMemoryMaker(seeder: seeder, drawer: drawer, home: home)
        let week = try await maker.make(into: folder, keyHex: key, now: now, timeZone: zone)
        XCTAssertEqual(week, DemoMemoryWeek(moments: 3, screenshots: 2))

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let clock = "--now-us 1792446060000000 --tz-offset-secs -25200"
        XCTAssertEqual(lines.filter { $0.hasPrefix("SEEDER --") || $0.hasPrefix("DRAWER --") }, [
            "SEEDER --demo-week --print-screens \(clock)",
            "DRAWER --spec \(folder.making.path)/screens.json --blob-root \(folder.blobs.path) "
                + "--manifest \(folder.making.path)/manifest.json --key-stdin",
            "SEEDER --demo-week --screens \(folder.making.path)/manifest.json --db-path \(folder.database.path) "
                + "--key-stdin \(clock)",
        ])
        XCTAssertEqual(lines.filter { $0.hasSuffix("-KEY \(key)") }.count, 2, "the key comes on standard input")
        let environment = lines.filter { $0.contains("-ENV ") }
        XCTAssertFalse(environment.contains { $0.contains("-ENV MCI_") }, "no memory and no key in the environment")
        XCTAssertFalse(environment.contains { $0.contains(key) })
        XCTAssertTrue(environment.contains("SEEDER-ENV HOME=\(home.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.making.path), "the lists go once it is made")
    }

    func testAMissingOrFailingToolSaysWhich() async throws {
        let scratch = try makeScratch()
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let folder = DemoMemoryFolder.standard(home: home)
        try folder.prepareEmpty(home: home)
        let drawer = try script(scratch, "demo-screens", "exit 0")
        let missing = BundledDemoMemoryMaker(seeder: scratch.appendingPathComponent("nowhere"), drawer: drawer,
                                             home: home)
        do {
            _ = try await missing.make(into: folder, keyHex: String(repeating: "0", count: 64), now: now,
                                       timeZone: zone)
            XCTFail("a missing tool is said")
        } catch {
            XCTAssertEqual(error as? DemoMemoryMakeError, .missingTool("nowhere"))
        }
        let failing = BundledDemoMemoryMaker(seeder: try script(scratch, "mci-seed-brain", "exit 15"),
                                             drawer: drawer, home: home)
        do {
            _ = try await failing.make(into: folder, keyHex: String(repeating: "0", count: 64), now: now,
                                       timeZone: zone)
            XCTFail("a failing tool is said")
        } catch {
            XCTAssertEqual(error as? DemoMemoryMakeError, .failed(tool: "mci-seed-brain", status: 15))
        }
    }

    func testAReleaseBuildUsesOnlyTheToolsInItsBundle() {
        let environment = ["MCI_DEMO_SEEDER": "/tmp/other-seeder", "MCI_DEMO_SCREENS": "/tmp/other-screens"]
        let release = BundledDemoMemoryMaker.bundled(bundle: .main, environment: environment, developmentBuild: false)
        XCTAssertEqual(release.seeder.lastPathComponent, "mci-seed-brain")
        XCTAssertEqual(release.drawer.lastPathComponent, "demo-screens")
        XCTAssertTrue(release.seeder.path.hasPrefix(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path))
        let development = BundledDemoMemoryMaker.bundled(bundle: .main, environment: environment,
                                                         developmentBuild: true)
        XCTAssertEqual(development.seeder.path, "/tmp/other-seeder")
        XCTAssertEqual(development.drawer.path, "/tmp/other-screens")
    }

    // MARK: With the real tools

    func testTheRealToolsMakeASealedWeekDatedFromNow() async throws {
        let (seeder, drawer) = try realTools()
        let scratch = try makeScratch()
        let home = try makeHomeWithAMemory(scratch)
        let before = try snapshot(home.appendingPathComponent("Library/Application Support/MCI"))
        let host = FakeDemoHost()
        let folder = DemoMemoryFolder.standard(home: home)
        let maker = BundledDemoMemoryMaker(seeder: seeder, drawer: drawer, home: home)
        let now = Date()
        let controller = DemoMemoryController(host: host, maker: maker, folder: folder, home: home,
                                              now: { now }, timeZone: { .current })
        let used = await controller.use()
        XCTAssertTrue(used, "\(host.reports)")

        // Sealed: the store is no plain database, and no screenshot is a
        // picture until it is opened with the week's key.
        let header = try Data(contentsOf: folder.database).prefix(16)
        XCTAssertNotEqual(header, Data("SQLite format 3\u{0}".utf8))
        let blobs = try FileManager.default.contentsOfDirectory(atPath: folder.blobs.path)
        XCTAssertGreaterThanOrEqual(blobs.count, 40)
        for name in blobs.prefix(10) {
            let bytes = try Data(contentsOf: folder.blobs.appendingPathComponent(name))
            XCTAssertFalse(bytes.starts(with: [0xFF, 0xD8, 0xFF]), "\(name) is sealed")
            XCTAssertFalse(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(name) is sealed")
        }
        // Dated from now: the made-up calendar is this week's, with
        // meetings today.
        let events = try calendarEvents(folder.calendar)
        XCTAssertGreaterThan(events.count, 5)
        for event in events {
            XCTAssertLessThan(event.start, now.addingTimeInterval(8 * 86_400))
            XCTAssertGreaterThan(event.start, now.addingTimeInterval(-8 * 86_400))
        }
        XCTAssertTrue(events.contains { Foundation.Calendar.current.isDate($0.start, inSameDayAs: now) })
        await controller.leave()
        XCTAssertEqual(try snapshot(home.appendingPathComponent("Library/Application Support/MCI")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
    }

    func testTheSameClockMakesTheSameWeekAndALaterClockMovesIt() async throws {
        let (seeder, drawer) = try realTools()
        let scratch = try makeScratch()
        let home = try makeHomeWithAMemory(scratch)
        let maker = BundledDemoMemoryMaker(seeder: seeder, drawer: drawer, home: home)
        func make(_ name: String, at clock: Date) async throws -> (calendar: Data, blobs: Int) {
            let folder = DemoMemoryFolder(url: scratch.appendingPathComponent(name, isDirectory: true))
            try folder.prepareEmpty(home: home)
            let key = try folder.makeKey()
            _ = try await maker.make(into: folder, keyHex: key, now: clock, timeZone: zone)
            let blobs = try FileManager.default.contentsOfDirectory(atPath: folder.blobs.path).count
            return (try Data(contentsOf: folder.calendar), blobs)
        }
        let first = try await make("first", at: now)
        let again = try await make("again", at: now)
        XCTAssertEqual(first.calendar, again.calendar, "the same clock makes the same week")
        XCTAssertEqual(first.blobs, again.blobs)

        let weekLater = try await make("later", at: now.addingTimeInterval(7 * 86_400))
        let earlier = try calendarEvents(data: first.calendar).map(\.start)
        let later = try calendarEvents(data: weekLater.calendar).map(\.start)
        XCTAssertEqual(later.count, earlier.count)
        XCTAssertEqual(later, earlier.map { $0.addingTimeInterval(7 * 86_400) }, "dates follow now")
    }

    // MARK: Helpers

    private struct Event: Decodable {
        let startUs: UInt64
        var start: Date { Date(timeIntervalSince1970: TimeInterval(startUs) / 1_000_000) }
        enum CodingKeys: String, CodingKey { case startUs = "start_us" }
    }

    private struct CalendarFile: Decodable {
        let version: Int
        let events: [Event]
    }

    private func calendarEvents(_ url: URL) throws -> [Event] {
        try calendarEvents(data: Data(contentsOf: url))
    }

    private func calendarEvents(data: Data) throws -> [Event] {
        let calendar = try JSONDecoder().decode(CalendarFile.self, from: data)
        XCTAssertEqual(calendar.version, 1)
        return calendar.events
    }

    private func realTools() throws -> (URL, URL) {
        let environment = ProcessInfo.processInfo.environment
        guard let seeder = environment["MCI_DEMO_SEEDER"], let drawer = environment["MCI_DEMO_SCREENS"],
              FileManager.default.isExecutableFile(atPath: seeder),
              FileManager.default.isExecutableFile(atPath: drawer)
        else {
            throw XCTSkip("name the built tools with MCI_DEMO_SEEDER and MCI_DEMO_SCREENS")
        }
        return (URL(fileURLWithPath: seeder), URL(fileURLWithPath: drawer))
    }

    private func makeScratch() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-memory-maker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        return scratch
    }

    private func makeHomeWithAMemory(_ scratch: URL) throws -> URL {
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let own = home.appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: own.appendingPathComponent("mci.sqlite"))
        return home
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            out[name] = try? Data(contentsOf: folder.appendingPathComponent(name))
        }
        return out
    }

    private func script(_ folder: URL, _ name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
