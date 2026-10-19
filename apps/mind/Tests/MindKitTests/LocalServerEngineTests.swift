import Foundation
import XCTest
@testable import MindKit

/// The model-server engine against a fake server on 127.0.0.1.
final class LocalServerEngineTests: XCTestCase {
    private let question = AnswerInput(userName: "Sam", question: "what did we decide for team pricing?", now: nil, memories: [
        Memory(n: 2, when: "Tue 2:16 PM", source: "Slack #pricing", text: "Ravi: Let's land Team at $18 a seat, billed annually."),
        Memory(n: 3, when: "Tue 2:09 PM", source: "Notes Launch plan", text: "Open question: Team plan price before the beta?"),
    ], propositions: [], today: "Friday, October 10")

    private func engine(_ server: FakeModelServer, model: String = "", freshFor: TimeInterval = 30,
                        requestTimeout: TimeInterval = .infinity,
                        onACPower: @escaping @Sendable () -> Bool = { true }) async -> LocalServerEngine {
        await LocalServerEngine.find(EngineSettings(engine: .local, baseURL: server.baseURL, model: model),
                                     onACPower: onACPower, freshFor: freshFor, longestWait: requestTimeout)
    }

    private func assertUnavailable<T>(_ work: () async throws -> T, _ message: String = "",
                                      file: StaticString = #filePath, line: UInt = #line) async {
        await assertFails(with: .unavailable, work, message, file: file, line: line)
    }

    private func assertFails<T>(with expected: MindError, _ work: () async throws -> T, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("answered: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MindError, expected, message, file: file, line: line)
        }
    }

    // MARK: Choosing a model

    func testAModelIsPickedByFamilyInOrderAndNeverOneInACloud() {
        func pick(_ names: [String]) -> String? { try? LocalServerEngine.choose("", from: names).get() }
        XCTAssertEqual(pick(["nomic-embed-text:latest", "phi4:14b", "mistral:7b", "gemma3:4b", "llama3.1:8b", "llama3.2:3b"]), "llama3.2:3b")
        XCTAssertEqual(pick(["llama3.2:3b", "qwen3:4b"]), "qwen3:4b")
        XCTAssertEqual(pick(["llama3.1:8b", "gemma3:4b"]), "llama3.1:8b")
        XCTAssertEqual(pick(["phi4:14b", "gemma3:4b", "mistral:7b"]), "gemma3:4b")
        XCTAssertEqual(pick(["phi4:14b", "mistral:7b"]), "mistral:7b")
        XCTAssertEqual(pick(["phi4:14b"]), "phi4:14b")
        // Ollama runs "-cloud" models on its own servers: never one of those.
        XCTAssertEqual(pick(["qwen3-coder:480b-cloud", "gpt-oss:120b-cloud", "glm-4.6:cloud", "llama3.1:8b"]), "llama3.1:8b")
        // LM Studio's names, in the same order.
        XCTAssertEqual(pick(["text-embedding-nomic-embed-text-v1.5", "google/gemma-3-4b", "meta-llama-3.1-8b-instruct"]),
                       "meta-llama-3.1-8b-instruct")
        XCTAssertEqual(pick(["microsoft/phi-4", "llama-3.2-3b-instruct", "qwen/qwen3-4b-2507"]), "qwen/qwen3-4b-2507")
        XCTAssertEqual(pick(["microsoft/phi-4", "google/gemma-3-12b"]), "google/gemma-3-12b")
        // A family starts a word: "dolphin" holds "phi" but is not one.
        XCTAssertEqual(pick(["dolphin-llama3:8b", "phi3:mini"]), "phi3:mini")
        XCTAssertFalse(LocalServerEngine.isOf("phi", "dolphin-mixtral:8x7b"))
        XCTAssertTrue(LocalServerEngine.isOf("llama3.2", "hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M"))
        // With no family it knows, the first that can chat.
        XCTAssertEqual(pick(["nomic-embed-text:latest", "deepseek-r1:8b"]), "deepseek-r1:8b")
        XCTAssertEqual(LocalServerEngine.choose("", from: ["qwen3-coder:480b-cloud", "nomic-embed-text:latest"]),
                       .failure(.init(reason: "local_model_unset")))
        XCTAssertEqual(LocalServerEngine.choose("", from: []), .failure(.init(reason: "local_model_unset")))
        // A model the person named: as the server lists it, never a cloud one.
        XCTAssertEqual(try? LocalServerEngine.choose("llama3.2", from: ["llama3.2:latest"]).get(), "llama3.2:latest")
        XCTAssertEqual(LocalServerEngine.choose("mistral:7b", from: ["llama3.2:latest"]), .failure(.init(reason: "local_model_missing")))
        XCTAssertEqual(LocalServerEngine.choose("gpt-oss:120b-cloud", from: ["gpt-oss:120b-cloud"]),
                       .failure(.init(reason: "local_model_not_local")))
    }

    func testTheServerIsAskedForItsModelsAndTheBestIsUsed() async throws {
        let server = try FakeModelServer { _ in FakeModelServer.models(["nomic-embed-text:latest", "gemma3:4b", "llama3.2:3b"]) }
        defer { server.stop() }
        let engine = await engine(server)
        XCTAssertNil(engine.unavailableReason())
        XCTAssertEqual(engine.label, "local:llama3.2:3b")
        XCTAssertEqual(server.requests.map { "\($0.method) \($0.path)" }, ["GET /v1/models"])
    }

    // MARK: Only this Mac

    func testOnlyAnAddressOnThisMacIsUsed() {
        for refused in ["http://example.com/v1", "http://192.168.1.5:11434/v1", "http://127.0.0.1.nip.io/v1",
                        "http://0x7f000001/v1", "http://127.1/v1", "http://[::ffff:127.0.0.1]/v1", "ftp://127.0.0.1/v1",
                        "http://user:secret@127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1?to=example.com",
                        "http://127%2E0.0.1:11434/v1", "127.0.0.1:11434", "not an address", ""] {
            XCTAssertNil(LocalServerEngine.local(refused), refused)
        }
        XCTAssertEqual(LocalServerEngine.local("http://localhost:11434/v1/")?.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(LocalServerEngine.local("http://LocalHost:1234/v1")?.absoluteString, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(LocalServerEngine.local("http://[::1]:11434/v1")?.absoluteString, "http://[::1]:11434/v1")
        XCTAssertEqual(LocalServerEngine.local(" http://127.0.0.1:11434/v1 ")?.absoluteString, "http://127.0.0.1:11434/v1")
    }

    func testAServerElsewhereIsNeverAsked() async throws {
        let engine = await LocalServerEngine.find(EngineSettings(engine: .local, baseURL: "http://192.168.1.5:11434/v1"))
        XCTAssertEqual(engine.unavailableReason(), "local_server_not_local")
        await assertUnavailable { try await engine.answer(question) }
    }

    func testNothingListeningIsUnreachable() async throws {
        let engine = await LocalServerEngine.find(EngineSettings(engine: .local,
                                                                 baseURL: "http://127.0.0.1:\(try FakeModelServer.closedPort())/v1"))
        XCTAssertEqual(engine.unavailableReason(), "local_server_unreachable")
    }

    func testARedirectIsNotFollowed() async throws {
        let elsewhere = try FakeModelServer { _ in FakeModelServer.models(["llama3.2:3b"]) }
        defer { elsewhere.stop() }
        let server = try FakeModelServer { _ in
            FakeModelServer.Reply(status: 302, body: "", headers: ["Location": "\(elsewhere.baseURL)/models"])
        }
        defer { server.stop() }
        let engine = await engine(server)
        XCTAssertEqual(engine.unavailableReason(), "local_server_unreachable")
        XCTAssertTrue(elsewhere.requests.isEmpty)
    }

    func testANamedModelTheServerLacksIsMissing() async throws {
        let server = try FakeModelServer { _ in FakeModelServer.models(["llama3.2:3b"]) }
        defer { server.stop() }
        let missing = await engine(server, model: "mistral:7b")
        XCTAssertEqual(missing.unavailableReason(), "local_model_missing")
        let named = await engine(server, model: "llama3.2:3b")
        XCTAssertEqual(named.label, "local:llama3.2:3b")
    }

    // MARK: Asking

    func testAnAnswerUsesTheFoundationPromptAndComesOutOfACodeFence() async throws {
        let server = try FakeModelServer { request in
            request.method == "GET"
                ? FakeModelServer.models(["llama3.2:3b", "qwen3:4b"])
                : FakeModelServer.chat("<think>\n\n</think>\n```json\n{\"answer\": \"You settled on $18 a seat.\", \"sources\": [2, 2, 9, \"3\"]}\n```")
        }
        defer { server.stop() }
        let engine = await engine(server)
        XCTAssertEqual(engine.label, "local:qwen3:4b")
        let answer = try await engine.answer(question)
        XCTAssertEqual(answer, AnswerOutput(answer: "You settled on $18 a seat.", sources: [2, 3]), "known sources, once each")

        let asked = try XCTUnwrap(server.requests.last)
        XCTAssertEqual("\(asked.method) \(asked.path)", "POST /v1/chat/completions")
        XCTAssertEqual(asked.body["model"] as? String, "qwen3:4b")
        XCTAssertEqual(asked.body["stream"] as? Bool, false)
        XCTAssertEqual(asked.body["temperature"] as? Double, 0.2)
        let messages = try XCTUnwrap(asked.body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"], Prompts.instructions(userName: "Sam"))
        XCTAssertTrue(asked.prompt.hasPrefix(Prompts.answer(question) + "\n\nReply in JSON that follows this schema:\n" + Schemas.answer))
        XCTAssertTrue(asked.prompt.hasSuffix("\n/no_think"), "qwen3 answers without thinking aloud first")
        XCTAssertEqual(asked.schemaName, "answer")
        let format = try XCTUnwrap((asked.body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["schema"] as? [String: Any])
    }

    func testAServerThatRefusesTheFormatIsAskedOnceMoreWithout() async throws {
        let server = try FakeModelServer { request in
            if request.method == "GET" { return FakeModelServer.models(["llama3.2:3b"]) }
            if request.schemaName != nil { return FakeModelServer.Reply(status: 400, body: #"{"error":"response_format is not supported"}"#) }
            return FakeModelServer.chat("Here it is: {\"answer\":\"On Tuesday.\",\"sources\":[2]} Anything else?")
        }
        defer { server.stop() }
        let answer = try await engine(server).answer(question)
        XCTAssertEqual(answer, AnswerOutput(answer: "On Tuesday.", sources: [2]))
        let asked = server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(asked.count, 2)
        XCTAssertNil(asked[1].body["response_format"])
        XCTAssertTrue(asked[1].prompt.hasSuffix("\nReply with JSON only."), asked[1].prompt)
        XCTAssertFalse(asked[1].prompt.contains("/no_think"), "only qwen3 is told that")
    }

    func testRepliesAreHeldToTheLimitsTheGuidedShapesSet() async throws {
        // More than the shapes allow, scores out of range, an unknown kind,
        // ids that were never sent, and a proposition with no scores.
        var propositions: [[String: Any]] = (1...5).map { index -> [String: Any] in
            ["reasoning": "seen", "text": "Sam is pricing the Team plan \(index)", "kind": "project", "confidence": 7, "decay": 4]
        }
        propositions[0]["kind"] = "hobby"
        propositions[0]["confidence"] = 15
        propositions[0]["decay"] = 0
        propositions.append(["text": "Sam has no scores"])
        var suggestions: [[String: Any]] = (1...6).map { index -> [String: Any] in
            ["title": "Resume pricing \(index)", "why": "You were pricing.", "usefulness": 5]
        }
        suggestions[0]["usefulness"] = 99
        let replies: [String: [String: Any]] = [
            "propose": ["propositions": propositions],
            "relate": ["relations": [["id": 4, "relation": "similar"], ["id": 99, "relation": "identical"], ["id": 5, "relation": "maybe"]]],
            "revise": ["reasoning": "both", "text": "Sam prices per seat", "kind": "Goal", "confidence": 11, "decay": -3],
            "episode": ["title": "Pricing the Team plan", "surface": "You read Stripe's pricing docs.", "beneath": ""],
            "suggest": ["suggestions": suggestions],
        ]
        let written = replies.mapValues { FakeModelServer.json($0) }
        let server = try FakeModelServer { request in
            guard let name = request.schemaName else { return FakeModelServer.models(["llama3.2:3b"]) }
            return FakeModelServer.chat(written[name] ?? "{}")
        }
        defer { server.stop() }
        let engine = await engine(server)

        let proposed = try await engine.propose(ProposeInput(userName: "Sam", observation: "Stripe pricing", known: []))
        XCTAssertEqual(proposed.propositions.count, 3, "at most three")
        XCTAssertEqual(proposed.propositions[0], PropositionDraft(text: "Sam is pricing the Team plan 1", reasoning: "seen",
                                                                   kind: "state", confidence: 10, decay: 1))
        let related = try await engine.relate(RelateInput(proposition: "p", candidates: [Candidate(id: 4, text: "a"), Candidate(id: 5, text: "b")]))
        XCTAssertEqual(related.relations, [Relation(id: 4, relation: .similar), Relation(id: 5, relation: .unrelated)], "known ids only")
        let revised = try await engine.revise(ReviseInput(userName: "Sam", new: PropositionDraft(text: "t", reasoning: "r", kind: "goal", confidence: 5, decay: 5), old: []))
        XCTAssertEqual(revised, PropositionDraft(text: "Sam prices per seat", reasoning: "both", kind: "goal", confidence: 10, decay: 1))
        let episode = try await engine.episode(EpisodeInput(userName: "Sam", observation: "o"))
        XCTAssertEqual(episode.beneath, "Nothing notable.", "the sentinel the agent hides")
        let suggested = try await engine.suggest(SuggestInput(userName: "Sam", now: "n", recent: [], propositions: []))
        XCTAssertEqual(suggested.suggestions.map { $0.usefulness }, [10, 5, 5, 5], "at most four, scored 1 to 10")
    }

    func testTheDayIsWrittenAsTheFoundationEngineWritesIt() async throws {
        let server = try FakeModelServer { request in
            switch request.schemaName {
            case "day": FakeModelServer.chat(#"{"headline":"The beta announcement","narrative":"You drafted the beta announcement in Notes. You drafted the beta announcement in Notes."}"#)
            case "day_facts": FakeModelServer.chat(#"{"insights":["You were active for 1 h 5 min.","You were active for two hours."]}"#)
            default: FakeModelServer.models(["llama3.2:3b"])
            }
        }
        defer { server.stop() }
        let day = try await engine(server).day(DayInput(userName: "Sam", facts: "Active at the computer: 1 h 5 min.\nFirst activity 13:10, last 15:40.",
                                                        episodes: ["13:20–13:44 Launch notes: You were drafting the beta announcement."], propositions: []))
        XCTAssertEqual(day.narrative, "You drafted the beta announcement in Notes.", "each sentence once")
        XCTAssertEqual(day.insights, ["You were active for 1 h 5 min."], "only lengths the facts state")
        XCTAssertEqual(server.requests.filter { $0.schemaName == "day" }.first?.body["max_tokens"] as? Int, 300)
    }

    func testCaptionsComeFromTheServerByNumberOnAPowerCable() async throws {
        let server = try FakeModelServer { request in
            switch request.schemaName {
            case "caption":
                FakeModelServer.chat(#"{"captions":[{"n":2,"caption":"Planning a checkout redesign"},{"n":9,"caption":"Not asked"},{"n":1,"caption":"Looking up how to type accents"}]}"#)
            default: FakeModelServer.models(["llama3.2:3b"])
            }
        }
        defer { server.stop() }
        let engine = await engine(server)
        let output = try await engine.caption(CaptionInput(moments: [
            CaptionMoment(n: 1, app: "Chrome", title: "How to type accents on a Mac", text: "Press and hold a letter key, then choose an accent."),
            CaptionMoment(n: 2, app: "Figma", title: "Checkout redesign", text: "Hero, three columns"),
        ]))
        XCTAssertEqual(output.captions, [
            CaptionLine(n: 2, caption: "Planning a checkout redesign"),
            CaptionLine(n: 1, caption: "Looking up how to type accents"),
        ])
        let sent = try XCTUnwrap(server.requests.first { $0.schemaName == "caption" })
        XCTAssertEqual(sent.body["max_tokens"] as? Int, 300)
    }

    func testWorkNobodyAskedForWaitsForAPowerCable() async throws {
        let server = try FakeModelServer { request in
            switch request.schemaName {
            case "answer": FakeModelServer.chat(#"{"answer":"On Tuesday.","sources":[2]}"#)
            case "suggest": FakeModelServer.chat(#"{"suggestions":[]}"#)
            default: FakeModelServer.models(["llama3.2:3b"])
            }
        }
        defer { server.stop() }
        let engine = await engine(server, onACPower: { false })
        await assertFails(with: .onBattery, { try await engine.propose(ProposeInput(userName: "Sam", observation: "o", known: [])) }, "propose")
        await assertFails(with: .onBattery, { try await engine.relate(RelateInput(proposition: "p", candidates: [])) }, "relate")
        await assertFails(with: .onBattery, { try await engine.revise(ReviseInput(userName: "Sam", new: PropositionDraft(text: "t", reasoning: "r", kind: "goal", confidence: 5, decay: 5), old: [])) }, "revise")
        await assertFails(with: .onBattery, { try await engine.episode(EpisodeInput(userName: "Sam", observation: "o")) }, "episode")
        await assertFails(with: .onBattery, { try await engine.day(DayInput(userName: "Sam", facts: "f", episodes: [], propositions: [])) }, "day")
        await assertFails(with: .onBattery, { try await engine.caption(CaptionInput(moments: [CaptionMoment(n: 1, app: "Chrome", title: "t", text: "x")])) }, "caption")
        // The agent stores "unavailable" as the model being gone and the
        // window would say so, so the reply names the battery instead.
        let reply = try JSONSerialization.jsonObject(with: await MindServer(engine: engine).handle(
            try JSONSerialization.data(withJSONObject: ["id": 3, "task": "episode", "input": ["user_name": "Sam", "observation": "o"]] as [String: Any])
        )) as? [String: Any]
        XCTAssertEqual(reply?["error"] as? String, "on_battery")
        XCTAssertNil(engine.unavailableReason(), "the model is still there")
        // Ask still answers on battery.
        _ = try await engine.answer(question)
        _ = try await engine.suggest(SuggestInput(userName: "Sam", now: "n", recent: [], propositions: []))
        XCTAssertEqual(server.requests.compactMap(\.schemaName), ["answer", "suggest"])
    }

    /// Ask stops offering answers for a while after "unavailable", so only a
    /// server that is not there says it; one slow reply only failed.
    func testOnlyAServerThatIsNotThereIsUnavailable() {
        XCTAssertEqual(LocalServerEngine.failure(URLError(.cannotConnectToHost)), .unavailable)
        XCTAssertEqual(LocalServerEngine.failure(URLError(.timedOut)), .failed, "a model loading or a large model")
        XCTAssertEqual(LocalServerEngine.failure(URLError(.networkConnectionLost)), .failed)
        XCTAssertEqual(LocalServerEngine.failure(URLError(.cancelled)), .failed)
        XCTAssertEqual(LocalServerEngine.failure(CocoaError(.fileReadUnknown)), .failed)
    }

    func testAReplyThatTakesTooLongFailsAndTheModelStaysAvailable() async throws {
        let server = try FakeModelServer { request in
            request.method == "GET"
                ? FakeModelServer.models(["llama3.2:3b"])
                : FakeModelServer.Reply(body: FakeModelServer.chat(#"{"answer":"Late.","sources":[]}"#).body, delay: 2)
        }
        defer { server.stop() }
        let engine = await engine(server, requestTimeout: 0.5)
        await assertFails(with: .failed, { try await engine.answer(question) }, "answer")
        XCTAssertNil(engine.unavailableReason())
    }

    func testAServerThatStopsMakesTheEngineUnavailable() async throws {
        let server = try FakeModelServer { _ in FakeModelServer.models(["llama3.2:3b"]) }
        let engine = await engine(server)
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await assertUnavailable { try await engine.answer(question) }
        XCTAssertEqual(engine.unavailableReason(), "local_server_unreachable")
    }

    // MARK: The serve loop

    func testTheServeLoopAnswersWhileTheModelListIsSlow() async throws {
        let slow = Flag()
        let server = try FakeModelServer { request in
            request.method == "GET"
                ? FakeModelServer.Reply(body: FakeModelServer.models(["qwen3:4b"]).body, delay: slow.isSet ? 3 : 0)
                : FakeModelServer.chat(#"{"answer":"On Tuesday.","sources":[2]}"#)
        }
        defer { server.stop() }
        // Every request finds the list stale, so each starts a new check.
        let engine = await engine(server, freshFor: 0)
        slow.set()
        let request = try JSONSerialization.data(withJSONObject: ["id": 1, "task": "answer", "input": [
            "user_name": "Sam", "question": "team price?", "memories": [["n": 2, "when": "w", "source": "s", "text": "$18 a seat"]],
            "propositions": [], "today": "Friday",
        ]] as [String: Any])
        let started = Date()
        let reply = await MindServer(engine: engine).handle(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "no wait on the 3 s list")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true, String(decoding: reply, as: UTF8.self))
        for _ in 0..<20 where server.requests.filter({ $0.method == "GET" }).count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(server.requests.filter { $0.method == "GET" }.count, 2, "the list was being checked meanwhile")
    }

    // MARK: Schemas

    func testEverySchemaIsJSONWithItsPropertiesInOrder() throws {
        for shape in Shape.allCases {
            let schema = try Shape.object(Data(shape.local.utf8))
            XCTAssertEqual(schema["type"] as? String, "object", shape.rawValue)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, shape.rawValue)
            let required = try XCTUnwrap(schema["required"] as? [String], shape.rawValue)
            XCTAssertEqual(Set(required), Set(try XCTUnwrap(schema["properties"] as? [String: Any]).keys), shape.rawValue)
            // The text lists the properties in the order `required` gives.
            let positions = required.map { shape.local.range(of: "\"\($0)\":{")?.lowerBound }
            XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), shape.rawValue)
        }
        XCTAssertEqual(try Shape.proposition.properties.keys.sorted(), ["confidence", "decay", "kind", "reasoning", "text"])
        XCTAssertTrue(Schemas.proposition.hasPrefix(#"{"type":"object","properties":{"reasoning":"#), "reasoning comes first")
    }

    /// The schemas a model server gets ask for what Foundation Models' guided
    /// shapes ask for: the same properties in the same order, guide text,
    /// ranges, counts and choices.
    func testTheServerSchemasMatchTheGuidedShapes() throws {
        guard Shape.day.guided != nil else { throw XCTSkip("needs Foundation Models") }
        for shape in Shape.allCases {
            let guided = try Shape.object(try XCTUnwrap(shape.guided))
            let local = try Shape.object(Data(shape.local.utf8))
            let name = shape.rawValue
            let guidedProperties = try XCTUnwrap(guided["properties"] as? [String: [String: Any]], name)
            let localProperties = try XCTUnwrap(local["properties"] as? [String: [String: Any]], name)
            XCTAssertEqual(Set(guidedProperties.keys), Set(localProperties.keys), name)
            if let order = guided["x-order"] as? [String] {
                XCTAssertEqual(order, local["required"] as? [String], name)
            }
            XCTAssertEqual(Set((guided["required"] as? [String]) ?? []), Set((local["required"] as? [String]) ?? []), name)
            for (key, guidedProperty) in guidedProperties {
                let localProperty = localProperties[key] ?? [:]
                let resolved = resolve(guidedProperty, in: guided)
                XCTAssertEqual(guidedProperty["description"] as? String, localProperty["description"] as? String, "\(name).\(key)")
                for bound in ["maxItems", "minItems", "minimum", "maximum"] where resolved[bound] != nil {
                    XCTAssertEqual(resolved[bound] as? Int, localProperty[bound] as? Int, "\(name).\(key).\(bound)")
                }
                if let choices = resolved["enum"] as? [String] {
                    XCTAssertEqual(Set(choices), Set((localProperty["enum"] as? [String]) ?? []), "\(name).\(key)")
                }
            }
        }
    }

    /// A property with any `$ref` to the schema's `$defs` followed.
    private func resolve(_ property: [String: Any], in schema: [String: Any]) -> [String: Any] {
        guard let reference = property["$ref"] as? String,
              let definition = (schema["$defs"] as? [String: [String: Any]])?[String(reference.split(separator: "/").last ?? "")]
        else { return property }
        return property.merging(definition) { mine, _ in mine }
    }
}

/// Settings and the choice between Apple's model and a model server.
final class EngineChoiceTests: XCTestCase {
    private struct Stub: MindEngine {
        let label: String
        let reason: String?
        func unavailableReason() -> String? { reason }
        func propose(_ input: ProposeInput) async throws -> ProposeOutput { throw MindError.failed }
        func relate(_ input: RelateInput) async throws -> RelateOutput { throw MindError.failed }
        func revise(_ input: ReviseInput) async throws -> PropositionDraft { throw MindError.failed }
        func episode(_ input: EpisodeInput) async throws -> EpisodeOutput { throw MindError.failed }
        func day(_ input: DayInput) async throws -> DayOutput { throw MindError.failed }
        func answer(_ input: AnswerInput) async throws -> AnswerOutput { throw MindError.failed }
        func suggest(_ input: SuggestInput) async throws -> SuggestOutput { throw MindError.failed }
        func caption(_ input: CaptionInput) async throws -> CaptionOutput { throw MindError.failed }
    }

    private let on = Stub(label: "apple-foundation-models", reason: nil)
    private let off = Stub(label: "apple-foundation-models", reason: "apple_intelligence_off")
    private let preparing = Stub(label: "apple-foundation-models", reason: "model_not_ready")

    private func home(_ settings: String?) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mind-home-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("Library/Application Support/MCI")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        if let settings { try Data(settings.utf8).write(to: folder.appendingPathComponent("model.json")) }
        return home.path
    }

    func testSettingsDefaultToAutoAtTheUsualAddresses() throws {
        for missing in [nil, "", "not json", "[]", #"{"engine": "cloud"}"#] {
            let settings = EngineSettings.load(home: try home(missing))
            XCTAssertEqual(settings, EngineSettings(), missing ?? "no file")
            XCTAssertEqual(settings.baseURLs, ["http://127.0.0.1:11434/v1", "http://127.0.0.1:1234/v1"])
        }
        let named = EngineSettings.load(home: try home(#"{"engine": "Local", "base_url": " http://localhost:1234/v1 ", "model": "gemma3:4b"}"#))
        XCTAssertEqual(named, EngineSettings(engine: .local, baseURL: "http://localhost:1234/v1", model: "gemma3:4b"))
        XCTAssertEqual(named.baseURLs, ["http://localhost:1234/v1"])
        let written = try JSONEncoder().encode(named)
        XCTAssertEqual(try JSONDecoder().decode(EngineSettings.self, from: written), named)
        XCTAssertEqual(EngineSettings.load(home: try home(#"{"model": "phi4"}"#)), EngineSettings(model: "phi4"))
    }

    func testAutoUsesAppleIntelligenceThenAModelServerThenSaysWhatWouldHelp() async throws {
        let server = try FakeModelServer { _ in FakeModelServer.models(["llama3.2:3b"]) }
        defer { server.stop() }
        let found = EngineSettings(baseURL: server.baseURL)
        let nothing = EngineSettings(baseURL: "http://127.0.0.1:\(try FakeModelServer.closedPort())/v1")

        var engine = await EngineChoice.engine(for: found, apple: on)
        XCTAssertEqual(engine.label, "apple-foundation-models")
        XCTAssertTrue(server.requests.isEmpty, "no server is asked when Apple Intelligence is on")
        engine = await EngineChoice.engine(for: found, apple: off)
        XCTAssertEqual(engine.label, "local:llama3.2:3b")
        XCTAssertNil(engine.unavailableReason())
        engine = await EngineChoice.engine(for: found, apple: nil)
        XCTAssertEqual(engine.label, "local:llama3.2:3b", "before macOS 26")

        engine = await EngineChoice.engine(for: nothing, apple: off)
        XCTAssertEqual(engine.unavailableReason(), "needs_apple_intelligence_or_local_model")
        engine = await EngineChoice.engine(for: nothing, apple: nil)
        XCTAssertEqual(engine.unavailableReason(), "needs_apple_intelligence_or_local_model")
        engine = await EngineChoice.engine(for: nothing, apple: preparing)
        XCTAssertEqual(engine.unavailableReason(), "model_not_ready", "Apple Intelligence is on and getting ready")
        engine = await EngineChoice.engine(for: EngineSettings(baseURL: "http://10.0.0.2:11434/v1"), apple: off)
        XCTAssertEqual(engine.unavailableReason(), "local_server_not_local", "an address that is not this Mac")
    }

    func testAppleOrLocalUsesOnlyThatOne() async throws {
        let server = try FakeModelServer { _ in FakeModelServer.models(["llama3.2:3b"]) }
        defer { server.stop() }
        var engine = await EngineChoice.engine(for: EngineSettings(engine: .apple, baseURL: server.baseURL), apple: nil)
        XCTAssertEqual(engine.unavailableReason(), "needs_macos_26")
        engine = await EngineChoice.engine(for: EngineSettings(engine: .apple, baseURL: server.baseURL), apple: off)
        XCTAssertEqual(engine.unavailableReason(), "apple_intelligence_off")
        engine = await EngineChoice.engine(for: EngineSettings(engine: .local, baseURL: server.baseURL), apple: on)
        XCTAssertEqual(engine.label, "local:llama3.2:3b")
        let closed = "http://127.0.0.1:\(try FakeModelServer.closedPort())/v1"
        engine = await EngineChoice.engine(for: EngineSettings(engine: .local, baseURL: closed), apple: on)
        XCTAssertEqual(engine.unavailableReason(), "local_server_unreachable")
    }

    func testWithNoSettingsAndNeitherModelTheReadyLineSaysWhatWouldHelp() async throws {
        let settings = EngineSettings.load(home: try home(nil))
        XCTAssertEqual(settings.engine, .auto)
        // The usual addresses are this Mac's own, so a server there is not
        // something a test controls: the finder looks at a closed port instead.
        let closed = "http://127.0.0.1:\(try FakeModelServer.closedPort())/v1"
        let engine = await EngineChoice.engine(for: settings, apple: nil) { _ in
            await LocalServerEngine.find(EngineSettings(baseURL: closed))
        }
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: MindServer(engine: engine).readyLine()) as? [String: Any])
        XCTAssertEqual(ready["available"] as? Bool, false)
        XCTAssertEqual(ready["reason"] as? String, "needs_apple_intelligence_or_local_model")
        XCTAssertNil(ready["engine"])
    }
}
