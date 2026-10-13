import Foundation
import MindKit
import XCTest

/// Runs the built `hippocampus-mind --serve` binary, and `SlowMindServe`, the
/// same serve loop over an engine that takes a minute per request
/// (`Tests/Fixtures/SlowMindServe`). The loop must answer requests in order
/// (it once deadlocked by blocking the main actor) and must end when its
/// parent closes stdin, even mid-request (it once outlived the app that quit).
final class ServeLoopTests: XCTestCase {
    func testTheServeLoopAnswersEachRequestInOrder() throws {
        let child = try serve("hippocampus-mind")
        // Malformed requests need no model, so this runs on any Mac.
        child.input.write(Data("not json\n{\"id\":7,\"task\":\"nope\",\"input\":{}}\n".utf8))
        let lines = read(child.output) { $0.count >= 3 }
        XCTAssertEqual(lines.count, 3, lines.joined(separator: "\n"))
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[0].contains("\"ready\":true"))
        XCTAssertTrue(lines[1].contains("bad_request"))
        XCTAssertTrue(lines[2].contains("\"id\":7"))
    }

    func testOnlyANewlineEndsARequest() throws {
        let child = try serve("hippocampus-mind")
        // JSON writers leave U+2028 and U+0085 unescaped inside strings, and
        // screen text can hold them. Neither may split the request in two.
        child.input.write(Data("{\"id\":9,\"task\":\"nope\",\"input\":{\"text\":\"a\u{2028}b\u{85}c\"}}\n".utf8))
        child.input.write(Data("{\"id\":10,\"task\":\"nope\",\"input\":{}}\n".utf8))
        let lines = read(child.output) { $0.contains { $0.contains("\"id\":10") } }
        XCTAssertEqual(lines.count, 3, lines.joined(separator: "\n"))
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[1].contains("\"id\":9") && lines[1].contains("bad_request"), lines[1])
    }

    func testClosingStdinEndsTheProcessWithinTwoSeconds() throws {
        let exited = XCTestExpectation(description: "exited")
        let child = try serve("hippocampus-mind", exited: exited)
        XCTAssertEqual(read(child.output) { $0.count >= 1 }.count, 1, "the ready line")
        try child.input.close()
        assertEnded(child.process, within: exited)
    }

    func testClosingStdinEndsTheProcessEvenMidRequest() throws {
        let exited = XCTestExpectation(description: "exited")
        let child = try serve("SlowMindServe", exited: exited)
        XCTAssertEqual(read(child.output) { $0.count >= 1 }.count, 1, "the ready line")
        child.input.write(Data("{\"id\":1,\"task\":\"day\",\"input\":{\"user_name\":\"A\",\"facts\":\"f\",\"episodes\":[],\"propositions\":[]}}\n".utf8))
        XCTAssertTrue(read(child.errors) { $0.contains("answering") }.contains("answering"), "the request is being answered")
        try child.input.close()
        assertEnded(child.process, within: exited)
        // `_exit`, not `exit`: nothing runs at exit while the model may
        // still be working.
        XCTAssertFalse(read(child.errors) { _ in false }.contains("exit handlers ran"))
    }

    func testAModelServerOnThisMacAnswersThroughTheBinary() throws {
        let server = try FakeModelServer { request in
            request.method == "GET"
                ? FakeModelServer.models(["llama3.2:3b", "qwen3:4b"])
                : FakeModelServer.chat(#"{"answer":"You settled on $18 a seat.","sources":[2]}"#)
        }
        defer { server.stop() }
        let child = try serve("hippocampus-mind", home: try home(#"{"engine": "local", "base_url": "\#(server.baseURL)"}"#))
        child.input.write(Data((#"{"id":4,"task":"answer","input":{"user_name":"Sam","question":"team price?","memories":[{"n":2,"when":"Tue 2:16 PM","source":"Slack","text":"$18 a seat"}],"propositions":[],"today":"Friday"}}"# + "\n").utf8))
        let lines = read(child.output) { $0.count >= 2 }
        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].contains(#""available":true"#) && lines[0].contains(#""engine":"local:qwen3:4b""#), lines[0])
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(reply["ok"] as? Bool, true, lines[1])
        XCTAssertEqual((reply["output"] as? [String: Any])?["answer"] as? String, "You settled on $18 a seat.")
        XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testWithNeitherModelTheReadyLineSaysWhatWouldHelp() throws {
        let closed = try FakeModelServer.closedPort()
        let child = try serve("hippocampus-mind", home: try home(#"{"base_url": "http://127.0.0.1:\#(closed)/v1"}"#))
        let ready = read(child.output) { $0.count >= 1 }.first ?? ""
        let apple = EngineChoice.appleEngine()
        if let apple, apple.unavailableReason() == nil {
            XCTAssertTrue(ready.contains(#""engine":"apple-foundation-models""#), "Apple Intelligence is on here: \(ready)")
        } else if apple?.unavailableReason() == "model_not_ready" {
            XCTAssertTrue(ready.contains(#""reason":"model_not_ready""#), ready)
        } else {
            XCTAssertTrue(ready.contains(#""available":false"#), ready)
            XCTAssertTrue(ready.contains(#""reason":"needs_apple_intelligence_or_local_model""#), ready)
        }
    }

    func testTheBinaryLinksFoundationModelsWeaklyAndRunsFromMacOS14() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("hippocampus-mind")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/otool")
        else { throw XCTSkip("needs the built binary and otool") }
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-l", binary.path]
        let output = Pipe()
        otool.standardOutput = output
        try otool.run()
        let commands = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .components(separatedBy: "Load command")
        otool.waitUntilExit()
        // Without the weak link the binary does not launch before macOS 26.
        for command in commands where command.contains("FoundationModels.framework") {
            XCTAssertTrue(command.contains("cmd LC_LOAD_WEAK_DYLIB"), command)
        }
        let build = commands.first { $0.contains("cmd LC_BUILD_VERSION") } ?? ""
        XCTAssertTrue(build.contains("minos 14.0"), build)
    }

    // MARK: Helpers

    private struct Child {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let errors: FileHandle
    }

    /// Starts `name --serve` from beside the tests, on pipes, with PATH as
    /// its only environment, as the onboarding check starts it, or with PATH
    /// and `home` as HOME, as the agent starts it. It is stopped when the
    /// test ends, and after 30 s so that no read waits forever.
    private func serve(_ name: String, home: String? = nil, exited: XCTestExpectation? = nil) throws -> Child {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("\(name) not built next to the tests")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--serve"]
        process.environment = ["PATH": "/usr/bin:/bin"].merging(home.map { ["HOME": $0] } ?? [:]) { first, _ in first }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        if let exited { process.terminationHandler = { _ in exited.fulfill() } }
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
        return Child(process: process, input: input.fileHandleForWriting,
                     output: output.fileHandleForReading, errors: errors.fileHandleForReading)
    }

    /// A home folder for the test holding `settings` as its model.json.
    private func home(_ settings: String) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mind-home-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("Library/Application Support/MCI")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try Data(settings.utf8).write(to: folder.appendingPathComponent("model.json"))
        return home.path
    }

    /// Whole lines read from `handle` once `done` holds for them, or when
    /// the pipe closes.
    private func read(_ handle: FileHandle, until done: ([String]) -> Bool) -> [String] {
        var text = ""
        var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
        while !done(lines) {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        return lines
    }

    private func assertEnded(_ process: Process, within exited: XCTestExpectation) {
        guard XCTWaiter().wait(for: [exited], timeout: 2) == .completed else {
            return XCTFail("still running 2 s after stdin closed")
        }
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
