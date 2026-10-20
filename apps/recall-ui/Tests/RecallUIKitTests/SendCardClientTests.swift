// SPDX-License-Identifier: Apache-2.0
//
// The window's way to the one builder (`mci-agent send-card`) and to what
// each AI tool has (`mci-agent clients`): the request goes on standard
// input, never in the arguments; the reply is read as the agent writes it;
// a memory that couldn't be opened is said as such. A stand-in agent script
// only: no real agent, no memory.

import Foundation
import XCTest
@testable import RecallUIKit

final class SendCardClientTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A stand-in `mci-agent` running `body` as /bin/sh.
    private func agent(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("mci-agent")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func client(_ url: URL, dbPath: String? = nil) -> SendCardClient {
        SendCardClient.agent({ url }, dbPath: dbPath, timeoutSeconds: 10)
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheRequestGoesOnStandardInputAndNeverInTheArguments() async throws {
        let url = try agent("""
        printf '%s\\n' "$@" > '\(folder.path)/arguments.txt'
        cat > '\(folder.path)/request.json'
        printf '{"message":"## Moment","words":2,"open":"claude://claude.ai/new?q=x","copy":false,"included":[4812]}\\n'
        """)
        let card = try await client(url, dbPath: "/tmp/sam/brain.sqlite")
            .card(SendCardRequest(to: "claude", question: "private words", moments: [4812]))
        XCTAssertEqual(card.message, "## Moment")
        XCTAssertEqual(card.open, "claude://claude.ai/new?q=x")
        XCTAssertFalse(card.copy)
        XCTAssertEqual(try text("arguments.txt"), "send-card\n--json\n--db-path\n/tmp/sam/brain.sqlite\n")
        let request = try text("request.json")
        XCTAssertTrue(request.contains("private words"), "the question went on standard input")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(object["to"] as? String, "claude")
        XCTAssertEqual(object["moments"] as? [Int], [4812])
    }

    func testALockedMemoryIsTold() async throws {
        for code in [10, 11, 12] {
            let url = try agent("cat > /dev/null\nexit \(code)")
            do {
                _ = try await client(url).card(SendCardRequest(to: "copy"))
                XCTFail("expected a failure")
            } catch {
                XCTAssertEqual(error as? SendCardError, .locked, "exit \(code)")
            }
        }
    }

    func testAnyOtherFailureIsAPlainFailure() async throws {
        for body in ["cat > /dev/null\nexit 1", "cat > /dev/null\nprintf 'not json'", "cat > /dev/null"] {
            let url = try agent(body)
            do {
                _ = try await client(url).card(SendCardRequest(to: "copy"))
                XCTFail("expected a failure: \(body)")
            } catch {
                XCTAssertEqual(error as? SendCardError, .failed, body)
            }
        }
    }

    func testNoAgentMeansUnavailable() async {
        let client = SendCardClient.agent({ throw ContextHandoffError.agentUnavailable })
        do {
            _ = try await client.card(SendCardRequest(to: "copy"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SendCardError, .unavailable)
        }
        do {
            _ = try await SendCardClient.unavailable.card(SendCardRequest(to: "copy"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SendCardError, .unavailable)
        }
    }

    /// An agent that ends before reading what it was given never takes the
    /// window with it.
    func testAnAgentThatNeverReadsItsInputIsHarmless() async throws {
        let url = try agent("printf '{\"message\":\"m\",\"words\":1,\"open\":null,\"copy\":true,\"included\":[]}'")
        let long = String(repeating: "private words ", count: 40_000)
        let card = try await client(url).card(SendCardRequest(to: "copy", question: long))
        XCTAssertEqual(card.message, "m")
    }

    func testWhatEachToolHasIsReadWithoutTheMemory() async throws {
        let url = try agent("""
        printf '%s\\n' "$@" > '\(folder.path)/arguments.txt'
        printf '{"tools":[{"id":"claude-code","name":"Claude Code","installed":true,"look_ups":"on","session_start":"on","start_kind":"hook"},{"id":"codex","name":"Codex","installed":true,"look_ups":"on","session_start":"on","start_kind":"hook","needs_step":"allow_hooks","later":1}]}'
        """)
        let tools = try await client(url, dbPath: "/tmp/sam/brain.sqlite").clients()
        XCTAssertEqual(try text("arguments.txt"), "clients\n--json\n", "content-free: no memory, no key")
        XCTAssertEqual(tools, [
            ClientStatus(id: "claude-code", name: "Claude Code", installed: true, lookUps: "on", sessionStart: "on",
                         startKind: "hook"),
            ClientStatus(id: "codex", name: "Codex", installed: true, lookUps: "on", sessionStart: "on",
                         startKind: "hook", needsStep: "allow_hooks"),
        ])
    }

    func testTheRequestIsWrittenAsTheBuilderReadsIt() throws {
        let request = SendCardRequest(
            to: "claude-code", question: "Why?", moments: [4812], selected: 4812,
            session: .init(startUs: 1, endUs: 2, title: "Shipping"), item: "w_1", includeAboutMe: true,
            includeScreenshot: false, appInstalled: true, full: true, client: "claude-code"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["to", "question", "moments", "selected", "session", "item",
                                          "include_about_me", "include_screenshot", "app_installed", "full", "client"])
        XCTAssertEqual(object["include_about_me"] as? Bool, true)
        XCTAssertEqual(object["app_installed"] as? Bool, true)
        XCTAssertEqual((object["session"] as? [String: Any])?["start_us"] as? Int, 1)
        XCTAssertEqual((object["session"] as? [String: Any])?["end_us"] as? Int, 2)
        XCTAssertEqual(object["client"] as? String, "claude-code")
    }

    func testTheCardIsReadAsTheBuilderWritesIt() throws {
        let json = #"""
        {"message":"m","chars":1,"words":1,"open":"claude://claude.ai/new?q=m","copy":false,"folder":"~/dev/x",
         "included":[4812],"left_out":{"forgotten":1,"kept_out":2,"secret_lines":3,"trimmed_moments":4},
         "shortened":true,"people_messages":true,"screenshot_moment":4812}
        """#
        let card = try JSONDecoder().decode(SendCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.leftOut, SendCard.LeftOut(forgotten: 1, keptOut: 2, secretLines: 3, trimmedMoments: 4))
        XCTAssertEqual(card.folder, "~/dev/x")
        XCTAssertTrue(card.shortened && card.peopleMessages)
        XCTAssertEqual(card.screenshotMoment, 4812)
        let bare = try JSONDecoder().decode(SendCard.self, from: Data(#"{"message":"m"}"#.utf8))
        XCTAssertTrue(bare.copy, "with no link it is copied")
        XCTAssertEqual(bare.leftOut, .init())
    }

    func testConnectedMeansItLooksThingsUpOrStartsSessions() throws {
        let off = try JSONDecoder().decode(ClientStatus.self, from: Data(#"{"id":"codex"}"#.utf8))
        XCTAssertEqual(off.name, "codex")
        XCTAssertFalse(off.isConnected)
        XCTAssertTrue(ClientStatus(id: "codex", name: "Codex", installed: true, lookUps: "on", sessionStart: "off")
            .isConnected)
        XCTAssertTrue(ClientStatus(id: "codex", name: "Codex", installed: true, lookUps: "off", sessionStart: "on")
            .isConnected)
        XCTAssertFalse(ClientStatus(id: "codex", name: "Codex", installed: true, lookUps: "unavailable",
                                    sessionStart: "turned_off_in_tool").isConnected)
    }
}
