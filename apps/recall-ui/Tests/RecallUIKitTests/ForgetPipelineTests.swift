import Darwin
import XCTest
@testable import RecallUIKit

/// The window's side of a forget while Hippocampus is remembering (SPEC
/// 3.11): one delete call for a whole forget, and the renewals that keep the
/// app's hold while it runs. Every moment here is made up, and the pending
/// file stays in a folder made for the test.
@MainActor
final class ForgetPipelineTests: XCTestCase {
    /// The app's end of the pipe: answers holds and releases, records every
    /// op, and answers a renewal as told (an app that doesn't know the op
    /// never answers it).
    final class App: WindowChannelSending, @unchecked Sendable {
        var renewAnswer: Bool? = true
        var holds = true
        private let lock = NSLock()
        private var ops: [WindowChannelProtocol.Op] = []

        var sent: [WindowChannelProtocol.Op] { lock.withLock { ops } }

        func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
            lock.withLock { ops.append(request.op) }
            switch request.op {
            case .hold: return holds
            case .renew:
                guard let renewAnswer else {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                return renewAnswer
            default: return true
            }
        }

        func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
    }

    /// A store that deletes a whole forget in one call, as the FFI does: one
    /// transaction for every id. It records each call, and can take a while.
    final class Store: PrivacyMutator, @unchecked Sendable {
        var delay: Duration = .zero
        private let lock = NSLock()
        private var made: [[UInt64]] = []

        var calls: [[UInt64]] { lock.withLock { made } }

        func deleteEvent(id: UInt64) async throws -> DeleteResult {
            try await deleteEvents(ids: [id])
        }

        func deleteEvents(ids: [UInt64]) async throws -> DeleteResult {
            lock.withLock { made.append(ids) }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return DeleteResult(eventsDeleted: UInt64(ids.count), vacuumOk: true)
        }

        func deleteEventsInRange(startTsUs: UInt64, endTsUs: UInt64) async throws -> DeleteResult {
            DeleteResult(eventsDeleted: 0, vacuumOk: true)
        }

        func prepareWipe() async throws -> String { "" }
        func wipeBrain(token: String) async throws -> DeleteResult { DeleteResult(eventsDeleted: 0, vacuumOk: true) }
    }

    private var folder: URL!
    private var app: App!
    private var mutator: Store!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("forget-pipeline-\(UUID().uuidString)")
        app = App()
        mutator = Store()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: PendingForgetStore { PendingForgetStore(directory: folder, memory: "/tmp/pipeline/mci.sqlite") }

    private func coordinator(renewEvery: Duration = ForgetCoordinator.renewEvery) -> ForgetCoordinator {
        ForgetCoordinator(mutator: mutator, channel: app, store: store, appRunning: { true },
                          deletions: MemoryDeletionSignal(center: NotificationCenter()), renewEvery: renewEvery)
    }

    // MARK: One delete call for a whole forget

    /// Twenty picked moments (the most that go without a question) are one
    /// call, so the writer lease, the integrity check and the cleanup run
    /// once, not twenty times inside the hold.
    func testTwentyPickedMomentsAreOneDeleteCall() async {
        let ids = (1...20).map { UInt64(4_000 + $0) }
        let outcome = await coordinator().forget(ForgetRequest(momentIds: ids))
        XCTAssertEqual(outcome, .forgotten(moments: 20))
        XCTAssertEqual(mutator.calls, [ids], "one call for the whole forget")
        XCTAssertEqual(app.sent, [.hold, .release])
    }

    /// A page read on many days: thousands of moments are still a few calls
    /// at most, each within what the store takes in one.
    func testAForgetOfMoreThanOneCallTakesGoesInAsFewCallsAsItCan() async {
        let ids = (1...(ForgetCoordinator.idsPerDelete + 5)).map { UInt64($0) }
        let outcome = await coordinator().forget(ForgetRequest(momentIds: ids))
        XCTAssertEqual(outcome, .forgotten(moments: UInt64(ids.count)))
        XCTAssertEqual(mutator.calls.map(\.count), [ForgetCoordinator.idsPerDelete, 5])
        XCTAssertEqual(mutator.calls.flatMap { $0 }, ids)
    }

    /// The default for a store without a delete of its own for many: one at
    /// a time, and it says which went when only some did.
    func testTheDefaultDeleteForManySaysWhichWentWhenOnlySomeDid() async throws {
        final class OneAtATime: PrivacyMutator, @unchecked Sendable {
            func deleteEvent(id: UInt64) async throws -> DeleteResult {
                if id == 42 { throw BrainReaderError.mutationBlocked }
                return DeleteResult(eventsDeleted: 1, vacuumOk: true)
            }

            func deleteEventsInRange(startTsUs: UInt64, endTsUs: UInt64) async throws -> DeleteResult {
                DeleteResult(eventsDeleted: 0, vacuumOk: true)
            }

            func prepareWipe() async throws -> String { "" }
            func wipeBrain(token: String) async throws -> DeleteResult {
                DeleteResult(eventsDeleted: 0, vacuumOk: true)
            }
        }
        let store = OneAtATime()
        let all = try await store.deleteEvents(ids: [41, 43])
        XCTAssertEqual(all.eventsDeleted, 2)
        do {
            _ = try await store.deleteEvents(ids: [41, 42, 43])
            XCTFail("a delete that left a moment saved returned")
        } catch let partial as PartialDeletion {
            XCTAssertEqual(partial.deleted, [41, 43])
            XCTAssertEqual(partial.result.eventsDeleted, 2)
        }
        do {
            _ = try await store.deleteEvents(ids: [42])
            XCTFail("a delete that deleted nothing returned")
        } catch {
            XCTAssertEqual(error as? BrainReaderError, .mutationBlocked)
        }
    }

    /// The app's own delete for many goes through the one export that
    /// deletes by id (`{"event_ids":[…]}`), and like every delete it tells
    /// the window's lists to read again.
    func testTheFFIDeletesAWholeForgetInOneCallAndSaysSo() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUIKit/FFIBrainReader.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func deleteEvents(ids: [UInt64])"))
        let next = source.range(of: "public func", range: start.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let body = source[start.upperBound..<next]
        XCTAssertTrue(body.contains("MemoryDeletionSignal.shared.reporting {"))
        XCTAssertTrue(body.contains("DeleteEventsPayload(event_ids: ids)"))
        XCTAssertTrue(body.contains("mci_brain_ffi_delete_event(h, q)"), "no fifth export (readonly_invariant.rs)")
    }

    // MARK: Keeping the hold while the deletes run

    /// A delete longer than the renewal: the window asks the app to keep its
    /// hold while it runs, and never after the release.
    func testALongDeleteAsksTheAppToKeepItsHold() async throws {
        mutator.delay = .milliseconds(450)
        let outcome = await coordinator(renewEvery: .milliseconds(100)).forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .forgotten(moments: 1))
        let sent = app.sent
        XCTAssertEqual(sent.first, .hold)
        XCTAssertEqual(sent.last, .release)
        XCTAssertGreaterThanOrEqual(sent.filter { $0 == .renew }.count, 2, "\(sent)")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(app.sent.last, .release, "no renewal after the release")
    }

    /// An app that refuses a renewal, or doesn't know the op and never
    /// answers it, changes nothing: the forget goes on and is done.
    func testARenewalTheAppDoesNotTakeNeverFailsTheForget() async {
        for answer in [false, nil] as [Bool?] {
            app.renewAnswer = answer
            mutator.delay = .milliseconds(300)
            let started = ContinuousClock.now
            let outcome = await coordinator(renewEvery: .milliseconds(100)).forget(ForgetRequest(momentIds: [41]))
            XCTAssertEqual(outcome, .forgotten(moments: 1), "\(String(describing: answer))")
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the forget never waits on a renewal")
        }
    }

    /// A quick forget sends no renewal at all: just the hold and the release.
    func testAQuickForgetSendsNoRenewal() async {
        _ = await coordinator().forget(ForgetRequest(momentIds: [41, 42]))
        XCTAssertFalse(app.sent.contains(.renew))
    }
}
