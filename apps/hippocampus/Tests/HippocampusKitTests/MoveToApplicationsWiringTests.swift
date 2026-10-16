// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Where the launch asks to move to Applications (launch plan item 3, D6):
/// before anything starts, so nothing records a path that won't last, and
/// a copy that is leaving opens nothing.
final class MoveToApplicationsWiringTests: XCTestCase {
    func testTheOfferComesBeforeAnythingStarts() throws {
        let app = try source("HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let offer = try XCTUnwrap(launch.range(of: "if MoveToApplicationsPrompt.run() {"))
        let architecture = try XCTUnwrap(launch.range(of: "MciBootGuards.hostIsAppleSilicon()"))
        XCTAssertLessThan(architecture.lowerBound, offer.lowerBound)
        for later in [
            "configurePreferencesController()", "installPreferencesReceiver()", "installStatusItem()", "Task {",
        ] {
            let start = try XCTUnwrap(launch.range(of: later), later)
            XCTAssertLessThan(offer.lowerBound, start.lowerBound, later)
        }
        // A move quits this copy and returns before the rest of the launch.
        let branch = try XCTUnwrap(launch.range(of: "}", range: offer.upperBound..<launch.endIndex))
        XCTAssertEqual(
            launch[offer.upperBound..<branch.lowerBound].split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            ["leavingForApplications = true", "requestQuit()", "return"]
        )
    }

    func testACopyThatIsLeavingOpensNothing() throws {
        let app = try source("HippocampusApp.swift")
        let links = try method("func application(_ application: NSApplication, open urls: [URL])", in: app)
        XCTAssertTrue(links.contains("guard !leavingForApplications else { return }"))
        let reopen = try method("func applicationShouldHandleReopen(", in: app)
        XCTAssertTrue(reopen.contains("if leavingForApplications { return false }"))
    }

    func testThePromptNeverTouchesQuarantine() throws {
        let prompt = try source("MoveToApplications.swift")
        XCTAssertFalse(prompt.contains("quarantine"))
        XCTAssertFalse(prompt.contains("xattr"))
        XCTAssertTrue(prompt.contains("BundleSignature.copy(copy, matches: bundle)"))
        XCTAssertTrue(prompt.contains("trashItem(at: url"))
    }

    private func source(_ name: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/\(name)"), encoding: .utf8)
    }

    private func method(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }
}
