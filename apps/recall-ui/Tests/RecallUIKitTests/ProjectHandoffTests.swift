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

    // MARK: Context for This Folder… from a Working On item (SPEC 3.2)

    func testTheSheetStartsInTheItemsFolderOnlyWhenItIsAFolderOnThisMac() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-home-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("dev/trailhead-shop", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: home.appendingPathComponent("dev/notes.txt"))
        defer { try? FileManager.default.removeItem(at: home) }
        let expected = project.standardizedFileURL.path

        XCTAssertEqual(ProjectHandoffModel.startingFolder("~/dev/trailhead-shop", home: home)?.path, expected)
        XCTAssertEqual(ProjectHandoffModel.startingFolder(" ~/dev/trailhead-shop/ ", home: home)?.path, expected)
        XCTAssertEqual(ProjectHandoffModel.startingFolder(project.path, home: home)?.path, expected, "a full path")
        XCTAssertEqual(ProjectHandoffModel.startingFolder("~", home: home)?.path, home.standardizedFileURL.path)
        XCTAssertNil(ProjectHandoffModel.startingFolder("~/dev/bike-api", home: home), "not a folder on this Mac")
        XCTAssertNil(ProjectHandoffModel.startingFolder("~/dev/notes.txt", home: home), "a file is not a folder")
        XCTAssertNil(ProjectHandoffModel.startingFolder("dev/trailhead-shop", home: home), "a path from nowhere")
        XCTAssertNil(ProjectHandoffModel.startingFolder("  ", home: home))
        XCTAssertNil(ProjectHandoffModel.startingFolder(nil, home: home))
    }

    func testTheSidebarsRowKnowsItsItemsFolder() {
        let item = WorkItem(id: "w_5c1e8a0d2f9b47e3a6d1", kind: .code, name: "trailhead-shop", lastUs: 1,
                            folderGuess: "~/dev/trailhead-shop")
        XCTAssertEqual(SidebarWorkItem(item).folderGuess, "~/dev/trailhead-shop")
    }

    func testASheetStartedInAFolderPreparesThatFolderAndOneStartedEmptyReadsNothing() async {
        let folder = URL(fileURLWithPath: "/tmp/fixture/trailhead-shop", isDirectory: true)
        let started = ProjectHandoffModel(startingIn: folder, exporter: { directory in
            "## Where you stopped in \(directory.lastPathComponent)"
        })
        XCTAssertEqual(started.project, folder)
        await started.refresh()
        XCTAssertEqual(started.packet, "## Where you stopped in trailhead-shop")

        let empty = ProjectHandoffModel(startingIn: nil, exporter: { _ in
            XCTFail("nothing is read before a folder is chosen")
            return ""
        })
        XCTAssertNil(empty.project)
        await empty.refresh()
        XCTAssertNil(empty.packet)
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
