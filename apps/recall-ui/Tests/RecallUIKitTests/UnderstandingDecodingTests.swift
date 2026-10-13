import XCTest
@testable import RecallUIKit

final class UnderstandingDecodingTests: XCTestCase {
    func testOverviewSampleDecodesEveryPart() throws {
        let overview = try UnderstandingFixture.overview()
        XCTAssertEqual(overview.version, 1)
        XCTAssertEqual(overview.date, "2026-10-12")
        XCTAssertTrue(overview.isToday)
        XCTAssertEqual(overview.nowUs, 1_791_841_025_000_000)
        XCTAssertEqual(overview.tzOffsetSecs, -25_200)
        XCTAssertEqual(overview.dayEndUs - overview.dayStartUs, 86_400_000_000)
        XCTAssertEqual(overview.basis, .measured)
        XCTAssertFalse(overview.truncated)
        XCTAssertEqual(overview.modelStatus.state, .available)
        XCTAssertNil(overview.modelStatus.unavailableReason)

        XCTAssertEqual(overview.now.state, .inProgress)
        XCTAssertEqual(overview.now.sinceUs, 1_791_839_523_000_000)
        XCTAssertEqual(overview.now.lastSavedUs, 1_791_841_000_000_000)
        XCTAssertEqual(overview.now.blockId, overview.blocks.last?.id)
        XCTAssertEqual(overview.now.title, "Trailhead pricing v3")
        XCTAssertEqual(overview.now.reopen, Reopen(url: nil, bundleId: "com.apple.Notes", appName: "Notes"))
        XCTAssertEqual(overview.strip, DayStrip(startUs: 1_791_820_800_000_000, endUs: 1_791_842_400_000_000))

        XCTAssertEqual(overview.blocks.count, 8)
        let first = try XCTUnwrap(overview.blocks.first)
        XCTAssertEqual(first.title, "Invoices and morning messages")
        XCTAssertEqual(first.writtenBy, "apple-foundation-models")
        XCTAssertEqual(first.kind, .communication)
        XCTAssertEqual(first.kinds.map(\.kind), [.communication, .other])
        XCTAssertEqual(first.apps.map(\.name), ["Mail", "Ledgerly", "Slack"])
        XCTAssertEqual(first.windows.first?.title, "Invoice 2291 from Spokewise")
        XCTAssertEqual(first.screenshotEventId, 90_103)
        XCTAssertEqual(first.openEventId, 90_122)
        XCTAssertNil(first.noticed)
        XCTAssertEqual(overview.blocks[1].noticed?.writtenBy, "apple-foundation-models")
        XCTAssertTrue(overview.blocks[2].touchesPrevious)
        XCTAssertEqual(overview.blocks[3].searches.map(\.query), ["rust round half to even"])
        XCTAssertEqual(overview.blocks[3].searches.first?.engine, "google")
        XCTAssertEqual(overview.blocks[3].windows.last?.host, "devnotes.example")
        XCTAssertEqual(overview.blocks[4].sentences.map(\.id), ["switched_between"])
        let last = try XCTUnwrap(overview.blocks.last)
        XCTAssertTrue(last.provisional)
        XCTAssertTrue(last.inProgress)
        XCTAssertEqual(last.writtenBy, "measured")

        XCTAssertEqual(overview.gaps.count, 5)
        XCTAssertEqual(overview.kinds.map(\.kind), [.writing, .code, .communication, .meetings, .design, .research])
        XCTAssertEqual(overview.facts.map(\.kind), [.active, .longest, .returned, .searched])
        XCTAssertEqual(overview.facts[0].text.durations["active"], 11_880_000_000)
        XCTAssertEqual(overview.facts[1].action?.kind, .selectBlocks)
        XCTAssertEqual(overview.facts[1].action?.blockIds, [1_791_828_150_000_000, 1_791_829_955_000_000])
        XCTAssertEqual(overview.facts[3].action?.kind, .showSearches)
        XCTAssertNil(overview.facts[0].action)
        XCTAssertEqual(overview.searches.count, 4)
        XCTAssertEqual(overview.account?.headline, "Pricing page copy, a tax rounding fix and a design review.")
        XCTAssertEqual(overview.aiKnows.recentWork.count, 4)
        XCTAssertEqual(overview.aiKnows.recentWork.first?.times["start"], 1_791_837_660_000_000)
        XCTAssertEqual(overview.aiKnows.aboutYou.map(\.id), [41, 37, 29, 45, 22, 33])
        XCTAssertTrue(overview.aiKnows.hookInstalled)
    }

    func testModelPageSampleDecodesEveryList() throws {
        let page = try UnderstandingFixture.modelPage()
        XCTAssertEqual(page.version, 1)
        XCTAssertEqual(page.modelStatus.state, .available)
        XCTAssertEqual(page.recentWork.count, 4)
        XCTAssertEqual(page.shared.map(\.id), [41, 37, 45, 29, 33, 22, 18])
        XCTAssertEqual(page.keptBack.map(\.id), [51, 27, 31])
        XCTAssertEqual(page.notSeenLately.map(\.id), [12])

        let item = try XCTUnwrap(page.shared.first)
        XCTAssertEqual(item.text, "Sam is redesigning the pricing page for Trailhead Bikes.")
        XCTAssertEqual(item.kind, .project)
        XCTAssertEqual(item.group, .workingOn)
        XCTAssertEqual(item.basis, .confirmed)
        XCTAssertEqual(item.daysSeen, 3)
        XCTAssertEqual(item.evidenceSessions.count, 5)
        XCTAssertEqual(item.evidenceSessions.first?.windowTitle, "Pricing page draft")
        XCTAssertEqual(page.shared[1].basis, .seenOnDays)
        XCTAssertEqual(page.shared[2].basis, .seenOnce)
        XCTAssertEqual(page.keptBack.map(\.group), [.howYouWork, .people, .struggles])
        XCTAssertEqual(page.keptBack.map(\.kind), [.habit, .relationship, .struggle])
    }

    func testSessionsSampleDecodesSegmentsAndTupleSearches() throws {
        let day = try JSONDecoder().decode(SessionsDay.self, from: UnderstandingFixture.data("sessions.sample.json"))
        XCTAssertEqual(day.date, "2026-10-12")
        XCTAssertEqual(day.sessions.count, 7)
        let tax = try XCTUnwrap(day.sessions.first { $0.title == "Checkout tax rounding" })
        XCTAssertEqual(tax.kind, .code)
        XCTAssertEqual(tax.searches, [SessionSearch(tsUs: 1_791_828_600_000_000, engine: "google",
                                                    query: "rust round half to even")])
        XCTAssertEqual(tax.segments?.count, 6)
        XCTAssertEqual(tax.segments?.first?.events, [90_166, 90_167, 90_168, 90_169, 90_170])
        XCTAssertEqual(tax.segments?[1].host, "google.com")
        XCTAssertEqual(day.sessions.first?.id, day.sessions.first?.startUs)
    }

    func testUnreadableNotesKeepNullSegmentsAndSearches() throws {
        var object = try UnderstandingFixture.object("sessions.sample.json")
        var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        sessions[0]["segments"] = NSNull()
        sessions[0]["searches"] = NSNull()
        object["sessions"] = sessions
        let day = try JSONDecoder().decode(SessionsDay.self, from: UnderstandingFixture.json(object))
        XCTAssertNil(day.sessions[0].segments)
        XCTAssertNil(day.sessions[0].searches)
        XCTAssertNotNil(day.sessions[1].segments)
    }

    func testUnknownKeysAndValuesNeverFailAReply() throws {
        var object = try UnderstandingFixture.object("overview.sample.json")
        object["open_loops"] = ["not", "in", "this", "round"]
        object["basis"] = "approximate"
        object["model_status"] = ["state": "warming", "reason": NSNull(), "checked_us": NSNull(), "engine": "local"] as [String: Any]
        var now = try XCTUnwrap(object["now"] as? [String: Any])
        now["state"] = "paused"
        object["now"] = now
        var blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        blocks[0]["kind"] = "gaming"
        blocks[0]["mood"] = "calm"
        object["blocks"] = blocks
        var facts = try XCTUnwrap(object["facts"] as? [[String: Any]])
        facts[0]["id"] = "streak"
        facts[1]["action"] = ["type": "open_url", "block_ids": [Int](), "url": "https://example.invalid"] as [String: Any]
        object["facts"] = facts
        var searches = try XCTUnwrap(object["searches"] as? [[String: Any]])
        searches[0]["engine"] = "altavista"
        object["searches"] = searches

        let overview = try JSONDecoder().decode(DayOverview.self, from: UnderstandingFixture.json(object))
        XCTAssertEqual(overview.basis, .estimated)
        XCTAssertEqual(overview.modelStatus.state, .unknown)
        XCTAssertEqual(overview.now, .nothing)
        XCTAssertEqual(overview.blocks.count, 8)
        XCTAssertEqual(overview.blocks[0].kind, .other)
        XCTAssertEqual(overview.facts[0].kind, .other)
        XCTAssertEqual(overview.facts[1].action?.kind, FactAction.Kind.none)
        XCTAssertEqual(overview.searches[0].engine, "altavista")

        var page = try UnderstandingFixture.object("model-page.sample.json")
        var shared = try XCTUnwrap(page["shared"] as? [[String: Any]])
        shared[0]["group"] = "hobbies"
        shared[0]["kind"] = "hobby"
        shared[0]["basis"] = "maybe"
        shared[0]["confidence"] = 0.9
        page["shared"] = shared
        page["counts"] = ["stale": 3]
        let decoded = try JSONDecoder().decode(ModelPage.self, from: UnderstandingFixture.json(page))
        XCTAssertEqual(decoded.shared[0].group, .other)
        XCTAssertEqual(decoded.shared[0].kind, .other)
        XCTAssertEqual(decoded.shared[0].basis, .seenOnce)
        XCTAssertEqual(decoded.shared.count, 7)
    }

    func testOneMalformedElementDropsOnlyItself() throws {
        var object = try UnderstandingFixture.object("overview.sample.json")
        var blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        blocks[0]["start_us"] = "soon"
        object["blocks"] = blocks
        var facts = try XCTUnwrap(object["facts"] as? [[String: Any]])
        facts[2].removeValue(forKey: "template")
        object["facts"] = facts
        var knows = try XCTUnwrap(object["ai_knows"] as? [String: Any])
        knows["about_you"] = [["id": 41, "text": "Sam is redesigning the pricing page."] as [String: Any], ["text": "no id"], NSNull()] as [Any]
        object["ai_knows"] = knows

        let overview = try JSONDecoder().decode(DayOverview.self, from: UnderstandingFixture.json(object))
        XCTAssertEqual(overview.blocks.count, 7)
        XCTAssertEqual(overview.blocks.first?.title, "Pricing page copy")
        XCTAssertEqual(overview.facts.map(\.kind), [.active, .longest, .searched])
        XCTAssertEqual(overview.aiKnows.aboutYou.map(\.id), [41])
    }

    func testMissingListsAndObjectsReadAsEmpty() throws {
        let minimal = #"{"date":"2026-10-11","day_start_us":1791702000000000,"day_end_us":1791788400000000}"#
        let overview = try JSONDecoder().decode(DayOverview.self, from: Data(minimal.utf8))
        XCTAssertEqual(overview.date, "2026-10-11")
        XCTAssertFalse(overview.isToday)
        XCTAssertEqual(overview.basis, .estimated)
        XCTAssertEqual(overview.modelStatus, .unknown)
        XCTAssertEqual(overview.now, .nothing)
        XCTAssertNil(overview.strip)
        XCTAssertTrue(overview.blocks.isEmpty && overview.gaps.isEmpty && overview.kinds.isEmpty)
        XCTAssertTrue(overview.facts.isEmpty && overview.searches.isEmpty)
        XCTAssertNil(overview.account)
        XCTAssertEqual(overview.aiKnows, .nothing)

        let page = try JSONDecoder().decode(ModelPage.self, from: Data(#"{"now_us":1}"#.utf8))
        XCTAssertTrue(page.shared.isEmpty && page.keptBack.isEmpty && page.notSeenLately.isEmpty)
        XCTAssertEqual(page.modelStatus.state, .unknown)

        XCTAssertThrowsError(try JSONDecoder().decode(DayOverview.self, from: Data(#"{"date":"2026-10-11"}"#.utf8)),
                             "a reply without the day's bounds is not an overview")
    }

    func testModelStatusNamesWhyTheModelCannotWrite() throws {
        let cases: [(String, ModelUnavailableReason)] = [
            ("apple_intelligence_off", .appleIntelligenceOff),
            ("device_not_eligible", .deviceNotEligible),
            ("model_not_ready", .modelNotReady),
            ("cannot_launch", .notAvailable),
            ("a reason from a later engine", .notAvailable),
        ]
        for (code, reason) in cases {
            let json = #"{"state":"unavailable","reason":"\#(code)","checked_us":1}"#
            let status = try JSONDecoder().decode(ModelStatus.self, from: Data(json.utf8))
            XCTAssertEqual(status.unavailableReason, reason, code)
        }
        let available = try JSONDecoder().decode(ModelStatus.self, from: Data(#"{"state":"available","reason":null,"checked_us":1}"#.utf8))
        XCTAssertNil(available.unavailableReason)
    }

    func testAnswersDecodeWithAndWithoutText() throws {
        let answered = """
        {"answer":"On Tuesday.","unavailable":null,"sources":[{"n":1,"event_id":7,"ts_us":5,"app":"Notes","title":null,"url":null,"text":"Tuesday plan"},{"n":3,"event_id":9,"ts_us":6,"app":"Safari","title":"Plans","url":"https://example.invalid","text":"x"}]}
        """
        let answer = try JSONDecoder().decode(AskAnswer.self, from: Data(answered.utf8))
        XCTAssertEqual(answer.answer, "On Tuesday.")
        XCTAssertNil(answer.unavailableReason)
        XCTAssertEqual(answer.sources.map(\.n), [1, 3])
        XCTAssertEqual(answer.sources[1].url, "https://example.invalid")

        let unanswered = #"{"answer":null,"unavailable":"apple_intelligence_off","sources":[]}"#
        let none = try JSONDecoder().decode(AskAnswer.self, from: Data(unanswered.utf8))
        XCTAssertNil(none.answer)
        XCTAssertEqual(none.unavailableReason, .appleIntelligenceOff)
        XCTAssertTrue(none.sources.isEmpty)
    }

    func testNoDecodedTextCarriesAHeaderOrTheSeparator() throws {
        let header = "[app=com.apple.Notes | title=Draft | url=? | ts=2026-10-12T16:41:05.000Z]\n"
        var object = try UnderstandingFixture.object("overview.sample.json")
        var blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        blocks[0]["title"] = "Invoices\u{1E}and messages"
        blocks[1]["noticed"] = ["text": header + "You rewrote the plan names.\n\n\u{1E}\nFile Edit", "written_by": "apple-foundation-models"]
        object["blocks"] = blocks
        var knows = try XCTUnwrap(object["ai_knows"] as? [String: Any])
        knows["about_you"] = [["id": 41, "text": header + "Sam is redesigning\u{1E}the pricing page."] as [String: Any]]
        object["ai_knows"] = knows
        let overview = try JSONDecoder().decode(DayOverview.self, from: UnderstandingFixture.json(object))
        let page = try UnderstandingFixture.modelPage()
        var texts = overview.blocks.flatMap { block in
            [block.title, block.noticed?.text ?? ""] + block.windows.compactMap(\.title)
                + block.sentences.map(\.text.template) + block.searches.map(\.query)
        }
        texts += overview.aiKnows.aboutYou.map(\.text) + overview.facts.map(\.text.template)
        texts += page.shared.map(\.text) + page.shared.map(\.reasoning)
        for text in texts {
            XCTAssertFalse(text.contains("\u{1E}"), text)
            XCTAssertFalse(text.hasPrefix("[app="), text)
        }
        XCTAssertEqual(overview.blocks[0].title, "Invoices and messages")
        XCTAssertEqual(overview.blocks[1].noticed?.text, "You rewrote the plan names.\n\nFile Edit")
        XCTAssertEqual(overview.aiKnows.aboutYou.first?.text, "Sam is redesigning the pricing page.")
    }

    #if DEBUG
    func testPreviewFixturesAreTheContractSamples() async throws {
        let reader = PreviewUnderstandingReader()
        let overview = try await reader.overview(PreviewUnderstandingReader.sampleDay)
        XCTAssertEqual(overview, try UnderstandingFixture.overview())
        let page = try await reader.modelPage()
        XCTAssertEqual(page, try UnderstandingFixture.modelPage())
        let answer = try await reader.ask("What did I fix?", app: nil, title: nil, now: nil)
        XCTAssertEqual(answer.sources.count, 2)
        XCTAssertNotNil(answer.answer)
    }

    func testPreviewScenariosCoverEmptyUnavailableAndModelOff() async throws {
        let day = PreviewUnderstandingReader.sampleDay
        let empty = try await PreviewUnderstandingReader(scenario: .empty).overview(day)
        XCTAssertTrue(empty.isToday)
        XCTAssertTrue(empty.blocks.isEmpty)
        XCTAssertEqual(empty.now, .nothing)
        let otherDay = UnderstandingDay(dateLocal: "2026-10-11", tzOffsetSeconds: -25_200)
        let past = try await PreviewUnderstandingReader().overview(otherDay)
        XCTAssertFalse(past.isToday)
        XCTAssertTrue(past.blocks.isEmpty)
        XCTAssertEqual(past.dayEndUs - past.dayStartUs, 86_400_000_000)

        do {
            _ = try await PreviewUnderstandingReader(scenario: .unavailable).overview(day)
            XCTFail("the unavailable preview must throw")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .unavailable)
        }

        let off = PreviewUnderstandingReader(scenario: .nomodel)
        let offDay = try await off.overview(day)
        XCTAssertEqual(offDay.modelStatus.unavailableReason, .appleIntelligenceOff)
        XCTAssertNil(offDay.account)
        let offPage = try await off.modelPage()
        XCTAssertTrue(offPage.shared.isEmpty)
        XCTAssertEqual(offPage.modelStatus.unavailableReason, .appleIntelligenceOff)
        let offAnswer = try await off.ask("What did I fix?", app: nil, title: nil, now: nil)
        XCTAssertNil(offAnswer.answer)
        XCTAssertEqual(offAnswer.unavailableReason, .appleIntelligenceOff)
        XCTAssertFalse(offAnswer.sources.isEmpty)
    }
    #endif
}
