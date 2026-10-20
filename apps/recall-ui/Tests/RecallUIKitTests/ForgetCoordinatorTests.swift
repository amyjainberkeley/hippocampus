import Darwin
import XCTest
@testable import RecallUIKit

/// Forgetting, from every page, while Hippocampus is remembering (SPEC
/// 3.11): the pending file, the hold over the private pipe, the deletes,
/// Undo, a forget a crash left, and the words when it fails. Everything here
/// is made up and stays in a folder made for the test.
@MainActor
final class ForgetCoordinatorTests: XCTestCase {
    /// The app's end of the pipe: records each op and answers as told.
    private final class FakeApp: WindowChannelSending, @unchecked Sendable {
        var holds = true
        private let lock = NSLock()
        private var ops: [WindowChannelProtocol.Op] = []

        var sent: [WindowChannelProtocol.Op] { lock.withLock { ops } }

        func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
            lock.withLock { ops.append(request.op) }
            return request.op == .hold ? holds : true
        }

        func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
    }

    /// The memory's deletes: each records when it ran, and whether the app
    /// held remembering at that moment.
    private final class FakeMutator: PrivacyMutator, @unchecked Sendable {
        var blocked = false
        weak var app: FakeApp?
        private let lock = NSLock()
        private var deleted: [String] = []
        private var heldWhenDeleting: [Bool] = []

        var deletes: [String] { lock.withLock { deleted } }
        var deletesHappenedHeld: [Bool] { lock.withLock { heldWhenDeleting } }

        func deleteEvent(id: UInt64) async throws -> DeleteResult {
            try record("event:\(id)")
            return DeleteResult(eventsDeleted: 1, vacuumOk: true)
        }

        func deleteEventsInRange(startTsUs: UInt64, endTsUs: UInt64) async throws -> DeleteResult {
            try record("range:\(startTsUs)-\(endTsUs)")
            return DeleteResult(eventsDeleted: 7, vacuumOk: true)
        }

        func prepareWipe() async throws -> String { "" }
        func wipeBrain(token: String) async throws -> DeleteResult { DeleteResult(eventsDeleted: 0, vacuumOk: true) }

        private func record(_ what: String) throws {
            if blocked { throw BrainReaderError.mutationBlocked }
            let ops = app?.sent ?? []
            let held = ops.last(where: { $0 == .hold || $0 == .release }) == .hold
            lock.withLock {
                deleted.append(what)
                heldWhenDeleting.append(held)
            }
        }
    }

    private var folder: URL!
    private var app: FakeApp!
    private var mutator: FakeMutator!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("forget-\(UUID().uuidString)")
        app = FakeApp()
        mutator = FakeMutator()
        mutator.app = app
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: PendingForgetStore { PendingForgetStore(directory: folder, memory: "/tmp/test/mci.sqlite") }

    private func coordinator(channel: (any WindowChannelSending)? = nil, appRunning: Bool = true) -> ForgetCoordinator {
        ForgetCoordinator(mutator: mutator, channel: channel ?? app, store: store,
                          appRunning: { appRunning }, deletions: MemoryDeletionSignal(center: NotificationCenter()))
    }

    // MARK: The hold

    func testWhileRememberingTheWindowHoldsDeletesThenReleases() async throws {
        let forget = coordinator()
        let started = Date()
        let outcome = await forget.forget(ForgetRequest(momentIds: [41, 42]))
        XCTAssertEqual(outcome, .forgotten(moments: 2))
        XCTAssertEqual(app.sent, [.hold, .release], "a hold, never the person's pause")
        XCTAssertFalse(app.sent.contains(.pause))
        XCTAssertEqual(mutator.deletes, ["event:41", "event:42"])
        XCTAssertEqual(mutator.deletesHappenedHeld, [true, true], "nothing is deleted before the hold")
        XCTAssertNil(store.load(), "the promise goes once it is kept")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "within 3 seconds on a made-up store")
        XCTAssertNil(forget.phase)
    }

    func testRecentTimeIsDeletedAsOneSpanFixedAtTheClick() async throws {
        let click = Date(timeIntervalSince1970: 1_791_841_260)
        let request = ForgetRequest.recent(.hour, now: click, calendar: Calendar(identifier: .gregorian))
        let outcome = await coordinator().forget(request)
        XCTAssertEqual(outcome, .forgotten(moments: 7))
        XCTAssertEqual(mutator.deletes, ["range:1791837660000000-1791841260000000"])
    }

    func testWhenTheHoldCantBeHadNothingIsDeleted() async throws {
        app.holds = false
        let outcome = await coordinator().forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .failed, "\(NavigationCopy.couldNotForget) with Try Again")
        XCTAssertTrue(mutator.deletes.isEmpty)
        XCTAssertEqual(app.sent, [.hold])
        XCTAssertNil(store.load(), "the rows come back: nothing is left to finish")
    }

    func testABlockedDeleteFailsAndRemembersAgain() async throws {
        mutator.blocked = true
        let outcome = await coordinator().forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(app.sent, [.hold, .release], "remembering comes back after a failure too")
    }

    func testAWindowOpenedByHandWhileTheAppRunsAsksToOpenItFirst() async throws {
        let forget = ForgetCoordinator(mutator: mutator, channel: nil, store: store, appRunning: { true },
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        let outcome = await forget.forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .needsApp)
        XCTAssertTrue(mutator.deletes.isEmpty)
        XCTAssertEqual(NavigationCopy.openHippocampusToForget, "To forget, open Hippocampus first.")
    }

    func testWithTheAppNotRunningAWindowOpenedByHandDeletesDirectly() async throws {
        let forget = ForgetCoordinator(mutator: mutator, channel: nil, store: store, appRunning: { false },
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        let outcome = await forget.forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .forgotten(moments: 1))
        XCTAssertEqual(mutator.deletes, ["event:41"])
    }

    func testNothingCanDeleteWithoutAMutator() async throws {
        let forget = ForgetCoordinator(mutator: nil, channel: app, store: store, appRunning: { true })
        let outcome = await forget.forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(app.sent.isEmpty, "the synthetic preview never holds remembering")
    }

    func testAForgetTellsEveryListToReadAgain() async throws {
        let center = NotificationCenter()
        let signal = MemoryDeletionSignal(center: center)
        let posted = expectation(forNotification: MemoryDeletionSignal.notification, object: signal,
                                 notificationCenter: center)
        let forget = ForgetCoordinator(mutator: mutator, channel: app, store: store, appRunning: { true },
                                       deletions: signal)
        _ = await forget.forget(ForgetRequest(momentIds: [41]))
        await fulfillment(of: [posted], timeout: 2)
    }

    // MARK: Undo

    func testUndoWithinTheNoteDeletesNothing() async throws {
        let forget = coordinator()
        let started = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        XCTAssertNil(started, "nothing happens while the note shows")
        XCTAssertEqual(forget.undoable?.count, 1)
        XCTAssertNotNil(store.load(), "the promise is written at once")
        XCTAssertTrue(forget.undo())
        XCTAssertNil(forget.undoable)
        XCTAssertNil(store.load())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mutator.deletes.isEmpty)
        XCTAssertTrue(app.sent.isEmpty)
        XCTAssertFalse(forget.undo(), "nothing left to undo")
    }

    func testANewerForgetFinishesTheOneWaitingOutItsNote() async throws {
        let forget = coordinator()
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [42]), count: 1)
        XCTAssertEqual(mutator.deletes, ["event:41"], "the first went ahead when the second came")
        XCTAssertEqual(forget.undoable?.request.momentIds, [42])
        await forget.finishUndoable()
        XCTAssertEqual(mutator.deletes, ["event:41", "event:42"])
    }

    // MARK: A forget a crash left

    func testAForgetLeftByACrashIsFinishedOnTheNextOpen() async throws {
        try store.save(ForgetRequest(momentIds: [41], spans: [.init(startUs: 10, endUs: 20)]))
        let forget = coordinator()
        let outcome = await forget.finishLeftover()
        XCTAssertEqual(outcome, .forgotten(moments: 8))
        XCTAssertEqual(mutator.deletes, ["event:41", "range:10-20"])
        XCTAssertEqual(app.sent, [.hold, .release])
        XCTAssertNil(store.load())
        let again = await forget.finishLeftover()
        XCTAssertNil(again, "nothing left")
    }

    func testAForgetForAnotherMemoryIsNeverApplied() async throws {
        try PendingForgetStore(directory: folder, memory: "/elsewhere/demo.sqlite")
            .save(ForgetRequest(momentIds: [41]))
        let outcome = await coordinator().finishLeftover()
        XCTAssertNil(outcome)
        XCTAssertTrue(mutator.deletes.isEmpty)
    }

    // MARK: The pending file's checks (the writer lease's own)

    func testThePendingFileIsPrivateAndHoldsNoContent() throws {
        try store.save(ForgetRequest(momentIds: [41], spans: [.init(startUs: 10, endUs: 20)]))
        let file = folder.appendingPathComponent(PendingForgetStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("/tmp/test"), "the memory is named by a hash, never its path")
        XCTAssertEqual(store.load(), ForgetRequest(momentIds: [41], spans: [.init(startUs: 10, endUs: 20)]))
    }

    func testAPendingFileOthersCouldWriteIsNeverRead() throws {
        try store.save(ForgetRequest(momentIds: [41]))
        let file = folder.appendingPathComponent(PendingForgetStore.fileName)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertNil(store.load())
    }

    func testASymlinkInThePendingFilesPlaceIsNeverRead() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.appendingPathComponent("elsewhere.json")
        try PendingForgetStore(directory: folder, memory: "/tmp/test/mci.sqlite").save(ForgetRequest(momentIds: [41]))
        try FileManager.default.moveItem(at: folder.appendingPathComponent(PendingForgetStore.fileName), to: real)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(PendingForgetStore.fileName),
                                                   withDestinationURL: real)
        XCTAssertNil(store.load())
    }

    func testWithNoFolderNothingIsWrittenAnywhere() throws {
        let none = PendingForgetStore(directory: nil, memory: "x")
        try none.save(ForgetRequest(momentIds: [41]))
        XCTAssertNil(none.load())
    }
}
