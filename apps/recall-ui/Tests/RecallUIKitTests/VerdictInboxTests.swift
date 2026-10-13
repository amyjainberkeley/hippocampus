import XCTest
@testable import RecallUIKit

final class VerdictInboxTests: XCTestCase {
    private var folder: URL!
    private var inboxDirectory: URL { folder.appendingPathComponent("understanding-feedback", isDirectory: true) }
    /// 2026-10-12 14:37:05.125 in UTC.
    private let moment = Date(timeIntervalSince1970: 1_791_841_025.125)

    override func setUpWithError() throws {
        folder = try TestFolders.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func inbox(environment: [String: String] = [:]) -> VerdictInbox {
        let moment = self.moment
        return VerdictInbox(directory: inboxDirectory, environment: environment, now: { moment })
    }

    private func body(_ file: URL?) throws -> String {
        String(decoding: try Data(contentsOf: XCTUnwrap(file)), as: UTF8.self)
    }

    func testRightAndForgetWriteTheAskPanelsFilesAtOnce() throws {
        let inbox = inbox()
        let right = inbox.give(.confirm, id: 41)
        XCTAssertEqual(right.file?.lastPathComponent, "1791841025125-41.json")
        XCTAssertEqual(try body(right.file), #"{"id":41,"verdict":"confirm"}"#)
        let forget = inbox.give(.reject, id: 37)
        XCTAssertEqual(forget.file?.lastPathComponent, "1791841025125-37.json")
        XCTAssertEqual(try body(forget.file), #"{"id":37,"verdict":"reject"}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: inboxDirectory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertEqual(VerdictInbox.defaultDirectory(home: URL(fileURLWithPath: "/Users/fixture")).path,
                       "/Users/fixture/Library/Application Support/Hippocampus/understanding-feedback")
    }

    func testUndoWithdrawsAForgetWhileItsFileIsStillThere() throws {
        let inbox = inbox()
        let forget = inbox.give(.reject, id: 37)
        XCTAssertTrue(inbox.pending().rejected.contains(37))
        XCTAssertTrue(inbox.canUndo(forget))
        XCTAssertTrue(inbox.undo(forget))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(forget.file).path))
        XCTAssertFalse(inbox.pending().rejected.contains(37))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testUndoIsNotOfferedOnceTheAgentHasTakenTheFile() throws {
        let inbox = inbox()
        let forget = inbox.give(.reject, id: 37)
        let file = try XCTUnwrap(forget.file)
        try FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("taken"))
        XCTAssertFalse(inbox.canUndo(forget))
        XCTAssertFalse(inbox.undo(forget))
        XCTAssertTrue(inbox.pending().rejected.contains(37), "a taken verdict is still being applied")
        XCTAssertTrue(VerdictInbox.pending(directory: inboxDirectory).rejected.contains(37))
    }

    func testPendingReadsGivenAndTakenFilesAndTheNewestVerdictWins() throws {
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: inboxDirectory.appendingPathComponent(name))
        }
        try write("1791841000000-5.json", #"{"id":5,"verdict":"reject"}"#)
        try write("1791841001000-5.json", #"{"id":5,"verdict":"confirm"}"#)
        try write("1791841002000-6.taken", #"{"id":6,"verdict":"reject"}"#)
        try write("1791841003000-7.json", "not a verdict")
        try write("1791841004000-8.json", #"{"id":8,"verdict":"maybe"}"#)
        try write("1791841005000-9.txt", #"{"id":9,"verdict":"reject"}"#)
        try write("1791841006000-10.json", #"{"id":10,"verdict":"reject","pad":""# + String(repeating: "x", count: 1_100) + #""}"#)
        let pending = VerdictInbox.pending(directory: inboxDirectory)
        XCTAssertEqual(pending.confirmed, [5])
        XCTAssertEqual(pending.rejected, [6])
        XCTAssertTrue(VerdictInbox.pending(directory: folder.appendingPathComponent("missing")).isEmpty)
    }

    func testTheDevelopmentKeyWritesNothing() throws {
        let inbox = inbox(environment: ["MCI_DEVELOPMENT_FILE_KEY": "1"])
        XCTAssertNil(inbox.directory)
        let forget = inbox.give(.reject, id: 41)
        XCTAssertNil(forget.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxDirectory.path))
        XCTAssertTrue(inbox.pending().rejected.contains(41), "the window's own verdict still applies on screen")
        XCTAssertTrue(inbox.undo(forget))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testThisWindowsVerdictsStayAppliedAfterTheAgentRemovesTheFile() throws {
        let inbox = inbox()
        let forget = inbox.give(.reject, id: 41)
        try FileManager.default.removeItem(at: try XCTUnwrap(forget.file))
        XCTAssertTrue(inbox.pending().rejected.contains(41))
        XCTAssertTrue(VerdictInbox.pending(directory: inboxDirectory).isEmpty)
    }

    func testForgottenItemsAreHiddenAndConfirmedOnesSaySo() throws {
        let inbox = inbox()
        inbox.give(.reject, id: 41)
        inbox.give(.reject, id: 27)
        inbox.give(.confirm, id: 45)
        inbox.give(.confirm, id: 12)
        let page = try UnderstandingFixture.modelPage().overlaying(inbox.pending())
        XCTAssertFalse(page.shared.contains { $0.id == 41 })
        XCTAssertFalse(page.keptBack.contains { $0.id == 27 })
        XCTAssertEqual(page.shared.first { $0.id == 45 }?.basis, .confirmed)
        XCTAssertEqual(page.notSeenLately.first { $0.id == 12 }?.basis, .confirmed)
        XCTAssertEqual(page.shared.count, 6)
        let overview = try UnderstandingFixture.overview().overlaying(inbox.pending())
        XCTAssertEqual(overview.aiKnows.aboutYou.map(\.id), [37, 29, 45, 22, 33])
        let untouched = try UnderstandingFixture.modelPage()
        XCTAssertEqual(untouched.overlaying(PendingVerdicts()), untouched)
    }
}
