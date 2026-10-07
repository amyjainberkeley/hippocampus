import XCTest
@testable import RecallUIKit

final class ProjectHandoffCommandTests: XCTestCase {
    func testProjectSelectionIsAnArgumentNotAShellCommandAndNeverRefreshes() throws {
        let command = try ContextHandoffCommand.makeProject(
            directory: URL(fileURLWithPath: "/tmp/My project; echo nope", isDirectory: true),
            environment: ["MCI_DB_PATH": "/tmp/scratch.sqlite"],
            recallExecutableURL: URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/recall-ui"),
            isExecutable: { _ in true })
        XCTAssertEqual(command.arguments, ["handoff", "--cwd", "/tmp/My project; echo nope",
            "--no-refresh", "--max-tokens", "600", "--format", "markdown",
            "--db-path", "/tmp/scratch.sqlite"])
    }

    func testNonFileProjectCannotFallBackToGlobalMemory() {
        XCTAssertThrowsError(try ContextHandoffCommand.makeProject(
            directory: URL(string: "https://example.com/project")!, environment: [:],
            isExecutable: { _ in true }))
    }
}

@MainActor
final class ProjectHandoffModelTests: XCTestCase {
    func testReselectingSameFolderKeepsPreparedContext() async {
        let model = ProjectHandoffModel(exporter: { _ in "cited packet" })
        let project = URL(fileURLWithPath: "/tmp/fixture")
        model.selectProject(project)
        await model.refresh()
        model.selectProject(project)
        XCTAssertEqual(model.packet, "cited packet")
    }
    func testDoesNotReadAnythingBeforeProjectSelection() async {
        let model = ProjectHandoffModel(exporter: { _ in XCTFail("Unexpected read"); return "" })
        await model.refresh()
        XCTAssertNil(model.packet)
        XCTAssertFalse(model.isLoading)
    }

    func testPreviewsActualExportAndClearsOldPacketOnFailure() async {
        let model = ProjectHandoffModel(exporter: { directory in
            if directory.lastPathComponent == "broken" { throw ContextHandoffError.commandFailed }
            return "## Next step\n- Ship the fixture (event 42)"
        })
        model.selectProject(URL(fileURLWithPath: "/tmp/fixture"))
        await model.refresh()
        XCTAssertTrue(model.packet?.contains("event 42") == true)
        XCTAssertNotNil(model.preparedAt)
        model.selectProject(URL(fileURLWithPath: "/tmp/broken"))
        XCTAssertNil(model.packet)
        await model.refresh()
        XCTAssertNil(model.packet)
        XCTAssertNotNil(model.errorMessage)
    }

    func testChangingProjectRejectsOldInFlightResponse() async throws {
        let model = ProjectHandoffModel(exporter: { _ in
            try await Task.sleep(for: .milliseconds(100))
            return "old project's private context"
        })
        model.selectProject(URL(fileURLWithPath: "/tmp/old"))
        let request = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        model.selectProject(URL(fileURLWithPath: "/tmp/new"))
        await request.value
        XCTAssertNil(model.packet)
        XCTAssertNil(model.preparedAt)
        XCTAssertFalse(model.isLoading)
    }
}
