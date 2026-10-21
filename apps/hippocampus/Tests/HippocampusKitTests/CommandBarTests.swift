import Foundation
import XCTest
@testable import HippocampusKit

final class CommandBarTests: XCTestCase {
    func testHitBodyDropsTheProvenanceHeader() throws {
        let json = #"{"event_id":3,"ts_us":5,"app_bundle_id":"com.apple.Notes","window_title":"Plan","url":null,"text_snippet":"[app=com.apple.Notes | title=Plan]\nBeta ships Oct 21.\nOwner: Maya"}"#
        let hit = try JSONDecoder().decode(BarHit.self, from: Data(json.utf8))
        XCTAssertEqual(hit.body, "Beta ships Oct 21. Owner: Maya")
    }

    /// A table's cells leave several spaces between words (the demo week's
    /// Stripe product catalog): a row reads them as one, as History does.
    func testAHitsTextReadsWithSingleSpaces() throws {
        let json = #"{"event_id":262,"ts_us":5,"app_bundle_id":"com.google.Chrome","window_title":"Studio – Product catalog – Stripe","url":null,"text_snippet":"Pricing  $49.00 USD  Per month\n  Default\t$490.00 USD   Per year  "}"#
        let hit = try JSONDecoder().decode(BarHit.self, from: Data(json.utf8))
        XCTAssertEqual(hit.body, "Pricing $49.00 USD Per month Default $490.00 USD Per year")
    }

    // MARK: "From your memory" (the demo week's own `recall` for "pricing")

    private static let chrome = "com.google.Chrome"
    private static let figma = "com.figma.Desktop"

    /// What the demo week's `recall` gave for "pricing" and "billing" (DEMO-SCRIPT
    /// shot 0:52), with the captions History shows for the same moments.
    private static let demoHits = #"""
    [{"event_id":118,"ts_us":1792407660000000,"app_bundle_id":"com.google.Chrome","window_title":"Pricing · Classbook","url":"https://classbook.example/pricing","text_snippet":"Simple pricing for every studio","caption":"Reading “Pricing”"},
     {"event_id":117,"ts_us":1792407600000000,"app_bundle_id":"com.google.Chrome","window_title":"Pricing · Classbook","url":"https://classbook.example/pricing","text_snippet":"Simple pricing for every studio","caption":"Reading “Pricing”"},
     {"event_id":252,"ts_us":1792502940000000,"app_bundle_id":"com.google.Chrome","window_title":"Pricing & Fees | Stripe","url":"https://stripe.com/pricing","text_snippet":"Pricing built for businesses of all sizes","caption":"Reading “Pricing & Fees”"},
     {"event_id":251,"ts_us":1792502760000000,"app_bundle_id":"com.google.Chrome","window_title":"Pricing & Fees | Stripe","url":"https://www.stripe.com/pricing/","text_snippet":"Pricing built for businesses of all sizes","caption":"Reading “Pricing & Fees”"},
     {"event_id":301,"ts_us":1792500000000000,"app_bundle_id":"com.apple.Terminal","window_title":"pebblewick-app — -zsh — 160×40","url":null,"text_snippet":"$ npm test billing","caption":"Working in Terminal: pebblewick-app"},
     {"event_id":255,"ts_us":1792503300000000,"app_bundle_id":"com.figma.Desktop","window_title":"Pricing page v2","url":null,"text_snippet":"Pricing that grows with your studio","caption":"Designing “Pricing page v2”"},
     {"event_id":254,"ts_us":1792503240000000,"app_bundle_id":"com.figma.Desktop","window_title":"Pricing page v2","url":null,"text_snippet":"Pricing that grows with your studio","caption":"Designing “Pricing page v2”"},
     {"event_id":302,"ts_us":1792500600000000,"app_bundle_id":"com.apple.Terminal","window_title":"pebblewick-app — -zsh — 120×40","url":null,"text_snippet":"$ git diff billing.ts","caption":"Working in Terminal: pebblewick-app"},
     {"event_id":311,"ts_us":1792501000000000,"app_bundle_id":"com.microsoft.VSCode","window_title":"billing.ts — pebblewick-app","url":null,"text_snippet":"export async function switchToYearly","caption":"Working on billing.ts in pebblewick-app"},
     {"event_id":312,"ts_us":1792501200000000,"app_bundle_id":"com.microsoft.VSCode","window_title":"billing.ts — pebblewick-app","url":null,"text_snippet":"export async function switchToYearly","caption":"Working on billing.ts in pebblewick-app"},
     {"event_id":321,"ts_us":1792502000000000,"app_bundle_id":"com.tinyspeck.slackmacgap","window_title":"team (Channel) - Pebblewick - Slack","url":null,"text_snippet":"yearly billing by Thursday?","caption":"Chatting in #team"}]
    """#

    private static func hits(_ json: String) throws -> [BarHit] {
        try JSONDecoder().decode([BarHit].self, from: Data(json.utf8))
    }

    /// Working On and Web Pages over the results, as the demo week lists them.
    private static let pricingItem = PanelItem(id: "w_7ab2f0", kind: "design", name: "Pricing page v2",
                                               apps: [figma], lastUs: 1_792_503_300_000_000, moments: [255])
    private static let pricingPages = [
        PanelPage(title: "Pricing & Fees \u{00B7} Stripe", host: "stripe.com", path: "/pricing", app: chrome, days: 1,
                  lastUs: 1_792_502_940_000_000, moments: [252]),
        PanelPage(title: "Pricing \u{00B7} Classbook", host: "classbook.example", path: "/pricing", app: chrome,
                  days: 1, lastUs: 1_792_407_660_000_000, moments: []),
    ]

    /// Nothing listed above "From your memory" is listed again under it: an
    /// item's or a page's own moment, the same page's address (with or
    /// without "www." and a last "/"), or the item's own window by its name.
    /// The same window read more than once is one row, the newest, where
    /// the first of them stood.
    @MainActor
    func testFromYourMemoryListsEachWindowOnceAndNothingListedAboveIt() throws {
        let shown = CommandBarModel.shownHits(try Self.hits(Self.demoHits), items: [Self.pricingItem],
                                              pages: Self.pricingPages)
        XCTAssertEqual(shown.map(\.eventId), [302, 312, 321])
        XCTAssertEqual(shown.map(\.shownTitle), ["Working in Terminal: pebblewick-app",
                                                 "Working on billing.ts in pebblewick-app", "Chatting in #team"])
    }

    /// With nothing listed above it, every page and window still shows once.
    @MainActor
    func testWithNothingAboveEachWindowShowsOnceInTheSearchesOrder() throws {
        let shown = CommandBarModel.shownHits(try Self.hits(Self.demoHits), items: [], pages: [])
        XCTAssertEqual(shown.map(\.eventId), [118, 252, 302, 255, 312, 321])
        XCTAssertEqual(Set(shown.map(\.shownTitle)).count, shown.count, "no two rows say the same")
    }

    /// At most eight rows, and the search asks for twice as many.
    @MainActor
    func testFromYourMemoryShowsAtMostEightRows() throws {
        let many = (1...20).map { index in
            #"{"event_id":\#(index),"ts_us":\#(index),"app_bundle_id":"com.apple.Notes","window_title":"Note \#(index)","url":null,"text_snippet":"pricing"}"#
        }
        let shown = CommandBarModel.shownHits(try Self.hits("[" + many.joined(separator: ",") + "]"), items: [],
                                              pages: [])
        XCTAssertEqual(shown.map(\.eventId), Array(1...8))
        XCTAssertEqual(CommandBarModel.momentRowLimit, 8)
    }

    /// A row is called what History calls the moment; without a caption
    /// (an older agent), its window's title tidied; without a title, what it
    /// said.
    func testAHitIsCalledByItsCaptionThenItsTitle() throws {
        let hits = try Self.hits(#"""
        [{"event_id":1,"ts_us":1,"app_bundle_id":"com.apple.Terminal","window_title":"pebblewick-app — -zsh — 160×40","url":null,"text_snippet":"$ ls","caption":"Working in Terminal: pebblewick-app"},
         {"event_id":2,"ts_us":2,"app_bundle_id":"com.google.Chrome","window_title":"Pricing & Fees  |  Stripe","url":null,"text_snippet":"Pay as you go"},
         {"event_id":3,"ts_us":3,"app_bundle_id":"com.apple.Notes","window_title":null,"url":null,"text_snippet":"[app=com.apple.Notes]\nLaunch list","caption":"  "},
         {"event_id":4,"ts_us":4,"app_bundle_id":"com.apple.Notes","window_title":"","url":null,"text_snippet":""}]
        """#)
        XCTAssertEqual(hits.map(\.shownTitle), ["Working in Terminal: pebblewick-app", "Pricing & Fees \u{00B7} Stripe",
                                                "Launch list", "Untitled"])
        XCTAssertNil(hits[1].caption, "an agent without captions still decodes")
    }

    private func fakeAgent(_ script: String) throws -> MemorySessionLaunch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-agent")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return MemorySessionLaunch(executable: url, arguments: ["mcp-serve"], environment: ["PATH": "/usr/bin:/bin"])
    }

    func testSessionMatchesRepliesByIdAndUnwrapsResults() async throws {
        // Echo two replies: the understanding shape (result.result) and recall's (result).
        let launch = try fakeAgent(#"""
        read line; echo '{"jsonrpc":"2.0","id":1,"result":{"content":[],"result":{"day":{"x":1}},"isError":false}}'
        read line; echo '{"jsonrpc":"2.0","id":2,"result":{"hits":[],"outcome":"degraded"}}'
        read line; echo '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad args"}}'
        cat >/dev/null
        """#)
        let session = MemorySession()
        let day = try await session.call("mci_day", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: day) as? [String: Any])?["day"] as? [String: Int], ["x": 1])
        let recall = try await session.call("mci_recall", arguments: Data(#"{"query":"q"}"#.utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: recall) as? [String: Any])?["outcome"] as? String, "degraded")
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
            XCTFail("an error reply must throw")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .toolFailed("bad args"))
        }
        await session.stop()
    }

    /// The agent writes U+2028 and U+0085 unescaped inside a reply. Replies
    /// are cut at the 0x0A byte only, so such a reply arrives whole instead
    /// of timing out (RULINGS S11).
    func testARepliesHoldingLineSeparatorsArriveWhole() async throws {
        let launch = try fakeAgent(#"""
        read line; printf '{"jsonrpc":"2.0","id":1,"result":{"text":"one\342\200\250two\302\205three"}}\n'
        read line; echo '{"jsonrpc":"2.0","id":2,"result":{"text":"next"}}'
        cat >/dev/null
        """#)
        let session = MemorySession()
        let first = try await session.call("mci_ask", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: first) as? [String: Any])?["text"] as? String,
                       "one\u{2028}two\u{0085}three")
        let second = try await session.call("mci_ask", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: second) as? [String: Any])?["text"] as? String, "next")
        await session.stop()

        // Splitting at every line break, as `bytes.lines` does, would cut
        // the first reply in three.
        var framer = ReplyFramer()
        let bytes = Data("{\"a\":\"one\u{2028}two\u{0085}three\"}\n{\"b\":1}\n".utf8)
        let frames = bytes.compactMap { framer.append($0) }
        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":\"one\u{2028}two\u{0085}three\"}", "{\"b\":1}"])
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HippocampusKit/CommandBar/MemorySession.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("in reader.bytes.lines"))
        XCTAssertTrue(source.contains("for try await byte in reader.bytes {"))
        XCTAssertTrue(source.contains("var framer = ReplyFramer()"))
    }

    func testSilentAgentTimesOutAndMissingAgentIsUnavailable() async throws {
        let silent = try fakeAgent("sleep 30")
        let session = MemorySession()
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: silent, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .timedOut)
        }
        let missing = MemorySessionLaunch(executable: URL(fileURLWithPath: "/nonexistent/mci-agent"), arguments: [], environment: [:])
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: missing, timeout: .seconds(1))
            XCTFail("expected unavailable")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    /// Quit ends Ask's session even when its child ignores SIGTERM in the
    /// middle of an answer (spec-shell S6.2).
    func testStopAndWaitEndsASilentChildWithinASecondAndAHalf() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ready) }
        let silent = try fakeAgent("trap '' TERM\ntouch '\(ready.path)'\nwhile :; do sleep 0.05; done")
        let session = MemorySession()
        let answer = Task {
            try await session.call("mci_ask", arguments: Data("{}".utf8), launch: silent, timeout: .seconds(30))
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = await session.runningProcessIdentifier
        let child = try XCTUnwrap(pid, "the session started its child, which now ignores SIGTERM")

        let started = ContinuousClock.now
        await session.stopAndWait(timeout: .seconds(1))
        let took = started.duration(to: .now)

        XCTAssertGreaterThanOrEqual(took, .milliseconds(900), "SIGTERM was ignored, so SIGKILL ended it")
        XCTAssertLessThan(took, .milliseconds(1500))
        XCTAssertNotEqual(kill(child, 0), 0, "the child is gone, not just let go")
        let running = await session.isRunning
        XCTAssertFalse(running)
        do {
            _ = try await answer.value
            XCTFail("the answer in flight must fail")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .exited)
        }
    }

    @MainActor
    func testActivatingAHitOpensItsPageOrTheEvent() throws {
        let model = CommandBarModel(launch: { _ in nil })
        XCTAssertEqual(model.rows, [], "no suggestions without a running agent")
        XCTAssertNil(model.activate())
        XCTAssertFalse(model.back(), "Esc on the home screen closes the bar")
    }

    @MainActor
    func testAsksWarmSessionsStopAfterTimeWithoutACall() async throws {
        let launch = try fakeAgent(#"""
        while read line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"hits\":[]}}"
        done
        """#)
        let sessions = WarmMemorySessions(launch: { _ in launch }, idleAfter: .milliseconds(300))
        _ = try await sessions.call(.reads, "mci_recall", arguments: Data(#"{"query":"q"}"#.utf8), timeout: .seconds(5))
        let runningAfterCall = await sessions.reads.isRunning
        XCTAssertTrue(runningAfterCall, "warm between calls")
        _ = try await sessions.call(.reads, "mci_recall", arguments: Data(#"{"query":"r"}"#.utf8), timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(150))
        let runningSoonAfter = await sessions.reads.isRunning
        XCTAssertTrue(runningSoonAfter, "each call starts the wait again")
        var stopped = false
        for _ in 0..<100 where !stopped {
            try await Task.sleep(for: .milliseconds(20))
            stopped = await !sessions.reads.isRunning
        }
        XCTAssertTrue(stopped, "stopped once idle")
        XCTAssertEqual(WarmMemorySessions.idleStop, .seconds(600), "about ten minutes in the app")
    }

    @MainActor
    func testWithoutTheAgentACallSaysUnavailable() async {
        let sessions = WarmMemorySessions(launch: { _ in nil })
        do {
            _ = try await sessions.call(.assistant, "mci_ask", arguments: Data("{}".utf8), timeout: .seconds(1))
            XCTFail("expected unavailable")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("\(error)")
        }
    }
}

private final class RecordingLoginItems: LoginItemService, @unchecked Sendable {
    var registered = 0
    var enabled = false
    func status() -> LoginItemStatus { enabled ? .enabled : .notRegistered }
    func register() throws { registered += 1; enabled = true }
    func unregister() throws { enabled = false }
}

final class LoginItemDefaultTests: XCTestCase {
    /// Only setup's ticked "Open Hippocampus at login" adds the login item
    /// (RULINGS O8); unticked, or a sentinel from an older setup, leaves it
    /// as it is.
    @MainActor
    func testOpenAtLoginFollowsSetupsCheckboxAndNothingElse() throws {
        let service = RecordingLoginItems()
        let model = LoginItemViewModel(service: service)
        model.applySetupChoice(opensAtLogin: false)
        model.applySetupChoice(opensAtLogin: nil)
        XCTAssertEqual(service.registered, 0)
        XCTAssertFalse(model.isEnabled)
        model.applySetupChoice(opensAtLogin: true)
        XCTAssertEqual(service.registered, 1)
        XCTAssertTrue(model.isEnabled)

        let kept = RecordingLoginItems()
        kept.enabled = true
        let existing = LoginItemViewModel(service: kept)
        existing.applySetupChoice(opensAtLogin: false)
        XCTAssertTrue(existing.isEnabled, "an existing install keeps whatever it has")
    }

    func testTheSentinelCarriesTheOpenAtLoginChoice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(OnboardingSentinel.filename)
        XCTAssertNil(OnboardingSentinel.opensAtLogin(at: url), "no file")
        for (body, choice) in [
            ("onboarding-completed-at 2026-10-12T21:05:00Z\nopen-at-login yes\n", true as Bool?),
            ("onboarding-completed-at 2026-10-12T21:05:00Z\nopen-at-login no\n", false),
            ("onboarding-completed-at 2026-10-12T21:05:00Z\n", nil),
        ] {
            try body.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(OnboardingSentinel.opensAtLogin(at: url), choice, body)
        }
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"), encoding: .utf8)
        XCTAssertFalse(app.contains("enableByDefaultOnce"), "no launch turns the login item on by itself")
        XCTAssertTrue(app.contains("loginItemVM.applySetupChoice(opensAtLogin: OnboardingSentinel.opensAtLogin())"))
    }
}
