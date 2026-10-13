import Foundation
import XCTest

@testable import MCICaptureHelperKit

/// RULINGS G8: nothing in the capture process may raise an Automation prompt.
/// Every Apple Event goes through one runner that asks macOS first, with
/// `askUserIfNeeded: false`, and sends nothing unless the person already
/// allowed it.
final class AutomationPromptTests: XCTestCase {
    private static var sources: [(name: String, text: String)] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, code($0)) }
        }
    }

    /// The text without comments, so prose that names an API is not a call.
    private static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    func testNoCodePathAsksForAutomationWithAPrompt() throws {
        let sources = Self.sources
        XCTAssertGreaterThan(sources.count, 50, "the package's sources were found")
        var calls = 0
        for (name, text) in sources {
            var rest = text[...]
            while let start = rest.range(of: "AEDeterminePermissionToAutomateTarget(") {
                // The call's arguments, up to its closing parenthesis.
                var depth = 1
                var index = start.upperBound
                while depth > 0, index < rest.endIndex {
                    if rest[index] == "(" { depth += 1 }
                    if rest[index] == ")" { depth -= 1 }
                    index = rest.index(after: index)
                }
                let arguments = rest[start.upperBound..<rest.index(before: index)]
                let last = arguments.split(separator: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertEqual(last, "false", "\(name) must never let macOS ask the person")
                calls += 1
                rest = rest[index...]
            }
            for prompt in ["askUserIfNeeded: true", "askUser: true", "askUserIfNeeded:true"] {
                XCTAssertFalse(text.contains(prompt), "\(name) asks for a prompt")
            }
        }
        XCTAssertEqual(calls, 2, "the consent gate and the Automation monitor")
    }

    func testOnlyTheConsentGatedRunnerSendsAppleEvents() {
        for (name, text) in Self.sources {
            for sender in ["osascript", "AESendMessage", "AESend(", ".sendEvent(", "SBApplication", "NSUserAppleScriptTask",
                           "OSAScript"] {
                XCTAssertFalse(text.contains(sender), "\(name) sends Apple Events outside the gated runner")
            }
            let scripts = text.components(separatedBy: "NSAppleScript(").count - 1
            XCTAssertEqual(scripts, name == "SafariURLProvider.swift" ? 1 : 0, name)
        }
    }

    func testTheRunnerSendsNothingWithoutConsent() {
        let asked = Recorder()
        let runner = RealAppleScriptRunner(
            isAlreadyGranted: { asked.add($0); return false },
            execute: { _ in
                XCTFail("no script runs before the person allowed it")
                return .success("ran")
            })
        XCTAssertEqual(runner.run("tell application \"Safari\" to URL of front document",
                                  target: "com.apple.Safari", timeoutMs: 5_000), .scriptError)
        XCTAssertEqual(asked.values, ["com.apple.Safari"])
        // Without a target there is no way to ask, so nothing is sent.
        XCTAssertEqual(runner.run("tell application \"Safari\" to URL of front document", timeoutMs: 5_000),
                       .scriptError)
        XCTAssertEqual(asked.values, ["com.apple.Safari"])
    }

    func testTheRunnerRunsAScriptThePersonAlreadyAllowed() {
        let runner = RealAppleScriptRunner(isAlreadyGranted: { $0 == "com.apple.Safari" }, execute: { .success($0) })
        XCTAssertEqual(runner.run("script", target: "com.apple.Safari", timeoutMs: 5_000), .success("script"))
        XCTAssertEqual(runner.run("script", target: "com.google.Chrome", timeoutMs: 5_000), .scriptError)
    }

    func testEveryProviderNamesTheAppItsScriptTalksTo() {
        let cases: [(provider: (any AppleScriptRunner) -> any URLProvider, frontmost: String, target: String, app: String)] = [
            ({ SafariURLProvider(runner: $0, clock: Date.init) }, "com.apple.Safari", "com.apple.Safari", "Safari"),
            ({ ChromiumURLProvider(runner: $0, clock: Date.init) }, "com.google.Chrome", "com.google.Chrome", "Google Chrome"),
            ({ ChromiumURLProvider(runner: $0, clock: Date.init) }, "com.brave.Browser", "com.brave.Browser", "Brave Browser"),
            ({ ChromiumURLProvider(runner: $0, clock: Date.init) }, "com.microsoft.edgemac", "com.microsoft.edgemac", "Microsoft Edge"),
            ({ FirefoxURLProvider(runner: $0, clock: Date.init) }, "org.mozilla.firefox", "org.mozilla.firefox", "Firefox"),
            ({ FirefoxURLProvider(runner: $0, clock: Date.init) }, "org.mozilla.firefoxdeveloperedition", "org.mozilla.firefox", "Firefox"),
            ({ ArcURLProvider(runner: $0, clock: Date.init) }, "company.thebrowser.Browser", "company.thebrowser.Browser", "Arc"),
        ]
        for item in cases {
            let runner = TargetRecorder()
            XCTAssertEqual(item.provider(runner).activeTabURL(forFrontmost: item.frontmost), "https://example.org/")
            XCTAssertEqual(runner.calls.map(\.target), [item.target], item.frontmost)
            XCTAssertTrue(runner.calls.first?.source.contains("tell application \"\(item.app)\"") ?? false, item.frontmost)
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func add(_ value: String) { lock.withLock { recorded.append(value) } }
        var values: [String] { lock.withLock { recorded } }
    }

    private final class TargetRecorder: AppleScriptRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(source: String, target: String)] = []
        var calls: [(source: String, target: String)] { lock.withLock { recorded } }
        func run(_ source: String, timeoutMs: Int) -> AppleScriptOutcome {
            XCTFail("every script names its target")
            return .scriptError
        }
        func run(_ source: String, target: String, timeoutMs: Int) -> AppleScriptOutcome {
            lock.withLock { recorded.append((source, target)) }
            return .success("https://example.org/")
        }
    }
}
