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

    // MARK: Two forgets close together

    /// The app's end as `WindowChannelPolicy` decides: one hold at a time (a
    /// hold while holding is refused). With `gated`, the first hold is
    /// answered only when the test opens the gate: the stop takes a while.
    final class AppLikeChannel: WindowChannelSending, @unchecked Sendable {
        var holdsAtAll = true
        var gated = false
        private let lock = NSLock()
        private var holding = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var open = false
        private var ops: [WindowChannelProtocol.Op] = []

        var sent: [WindowChannelProtocol.Op] { lock.withLock { ops } }

        func openGate() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                open = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume()
        }

        func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
            lock.withLock { ops.append(request.op) }
            switch request.op {
            case .hold:
                guard holdsAtAll else { return false }
                let refused: Bool = lock.withLock {
                    if holding { return true }
                    holding = true
                    return false
                }
                if refused { return false }
                if gated {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let resumeNow: Bool = lock.withLock {
                            if open { return true }
                            waiter = continuation
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                }
                return true
            case .release:
                lock.withLock { holding = false }
                return true
            default:
                return true
            }
        }

        func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
    }

    /// The memory's deletes, one at a time; ids in `failing` fail as a busy
    /// writer lease fails them ("writer lease is active").
    final class LeaseMutator: PrivacyMutator, @unchecked Sendable {
        var failing: Set<UInt64> = []
        private let lock = NSLock()
        private var done: [UInt64] = []

        var deleted: [UInt64] { lock.withLock { done } }

        func deleteEvent(id: UInt64) async throws -> DeleteResult {
            if failing.contains(id) { throw BrainReaderError.mutationBlocked }
            lock.withLock { done.append(id) }
            return DeleteResult(eventsDeleted: 1, vacuumOk: true)
        }

        func deleteEventsInRange(startTsUs: UInt64, endTsUs: UInt64) async throws -> DeleteResult {
            DeleteResult(eventsDeleted: 0, vacuumOk: true)
        }

        func prepareWipe() async throws -> String { "" }
        func wipeBrain(token: String) async throws -> DeleteResult { DeleteResult(eventsDeleted: 0, vacuumOk: true) }
    }

    private func coordinator(_ mutator: LeaseMutator, _ channel: AppLikeChannel) -> ForgetCoordinator {
        ForgetCoordinator(mutator: mutator, channel: channel, store: store, appRunning: { true },
                          deletions: MemoryDeletionSignal(center: NotificationCenter()))
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// ⌘⌫ on one moment; when its note closes its delete begins, and the
    /// hold takes a moment. Meanwhile ⌘⌫ on another. Each keeps its own
    /// promise: the second never replaces the first's, and the first one's
    /// end never removes the second's while it still waits out its note.
    func testTwoForgetsAtOnceKeepBothPromisesOnDisk() async {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.gated = true
        let forget = coordinator(mutator, channel)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        let first = Task { await forget.finishUndoable() }
        await eventually { channel.sent == [.hold] }
        XCTAssertEqual(channel.sent, [.hold], "the first forget is waiting for its hold")

        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [99]), count: 1)
        XCTAssertEqual(forget.undoable?.request.momentIds, [99])
        let during = store.load()?.momentIds ?? []
        XCTAssertTrue(during.contains(41),
                      "moment 41's promise was replaced before it was deleted (file now holds \(during))")

        channel.openGate()
        await first.value
        XCTAssertEqual(mutator.deleted, [41])
        XCTAssertEqual(store.load()?.momentIds, [99],
                       "moment 99 still waits out its note: a window that ends now still forgets it")
        forget.undo()
        XCTAssertNil(store.load())
    }

    /// A confirmed forget (a session, an hour, a page) while another
    /// forget's hold is still being asked for: it waits for that one, in the
    /// same hold, instead of asking for a second one the app would refuse.
    func testAConfirmedForgetDuringAnotherForgetsHoldIsNotRefused() async {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.gated = true
        let forget = coordinator(mutator, channel)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        let first = Task { await forget.finishUndoable() }
        await eventually { channel.sent == [.hold] }
        let second = Task { await forget.forget(ForgetRequest(momentIds: [77])) }
        await eventually { self.store.load()?.momentIds.contains(77) == true }
        channel.openGate()
        await first.value
        let outcome = await second.value
        XCTAssertNotEqual(outcome, .failed, "\(NavigationCopy.couldNotForget) for a valid forget")
        XCTAssertEqual(outcome, .forgotten(moments: 1))
        XCTAssertTrue(mutator.deleted.contains(77), "moment 77 is still saved: \(mutator.deleted)")
        XCTAssertEqual(channel.sent, [.hold, .release], "one hold for both")
        XCTAssertNil(store.load())
    }

    // MARK: A forget that deleted only some of it

    /// Three picked moments; the lease turns busy after the first (the hold
    /// ran out mid-forget and the agent came back). One went and two are
    /// still saved: the outcome says so, and the promise is kept for the two,
    /// never for the one that went.
    func testAForgetThatDeletedOnlySomeMomentsIsNotReportedAsForgotten() async {
        let mutator = LeaseMutator()
        mutator.failing = [42, 43]
        let channel = AppLikeChannel()
        let forget = coordinator(mutator, channel)
        let outcome = await forget.forget(ForgetRequest(momentIds: [41, 42, 43]))
        XCTAssertEqual(mutator.deleted, [41])
        XCTAssertNotEqual(outcome, .forgotten(moments: 1),
                          "the note says \"\(NavigationCopy.forgotten)\" while moments 42 and 43 are still saved")
        XCTAssertEqual(outcome, .partlyForgotten(moments: 1))
        XCTAssertNotNil(store.load(), "the promise for the moments still saved was thrown away")
        XCTAssertEqual(store.load()?.momentIds, [42, 43], "only what went leaves the promise")

        // Try Again (or the next open) finishes the rest.
        mutator.failing = []
        let rest = await forget.finishLeftover()
        XCTAssertEqual(rest, .forgotten(moments: 2))
        XCTAssertEqual(mutator.deleted, [41, 42, 43])
        XCTAssertNil(store.load())
    }

    /// A span that fails beside moments that went: the span stays promised.
    func testASpanThatFailsStaysPromisedBesideMomentsThatWent() async {
        final class SpansFail: PrivacyMutator, @unchecked Sendable {
            func deleteEvent(id: UInt64) async throws -> DeleteResult {
                DeleteResult(eventsDeleted: 1, vacuumOk: true)
            }

            func deleteEventsInRange(startTsUs: UInt64, endTsUs: UInt64) async throws -> DeleteResult {
                throw BrainReaderError.mutationBlocked
            }

            func prepareWipe() async throws -> String { "" }
            func wipeBrain(token: String) async throws -> DeleteResult {
                DeleteResult(eventsDeleted: 0, vacuumOk: true)
            }
        }
        let forget = ForgetCoordinator(mutator: SpansFail(), channel: app, store: store, appRunning: { true },
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        let span = ForgetRequest.Span(startUs: 10, endUs: 20)
        let outcome = await forget.forget(ForgetRequest(momentIds: [41], spans: [span]))
        XCTAssertEqual(outcome, .partlyForgotten(moments: 1))
        XCTAssertEqual(store.load(), ForgetRequest(spans: [span]))
        XCTAssertEqual(NavigationCopy.couldNotForgetAll, "Couldn\u{2019}t forget all of it. Some of it is still saved.")
    }

    // MARK: A forget a crash left, kept until it can be done

    private static let remembering = WindowChannelStatus(state: .remembering, title: "Remembering", action: "pause")
    private static let holding = WindowChannelStatus(state: .forgetting, title: "Forgetting\u{2026}")

    /// SPEC 3.11: "the pending file is applied the next time the window
    /// opens". When the app can't hold at that moment (it is still starting,
    /// or the lease stayed busy), the leftover stays promised.
    func testALeftoverForgetIsKeptWhenTheHoldCantBeHadOnOpen() async throws {
        try store.save(ForgetRequest(momentIds: [41]))
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.holdsAtAll = false
        let outcome = await coordinator(mutator, channel).finishLeftover()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(mutator.deleted.isEmpty)
        XCTAssertNotNil(store.load(), "a forget the person confirmed before a crash was dropped without being applied")
    }

    /// The kept leftover is tried again when the app's pushed status says a
    /// hold can be had, never on one that says a hold is under way, and the
    /// footer says "Finishing a forget…" until it's done.
    func testAKeptLeftoverIsFinishedWhenTheAppSaysAHoldCanBeHad() async throws {
        try store.save(ForgetRequest(momentIds: [41]))
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.holdsAtAll = false
        let forget = coordinator(mutator, channel)
        _ = await forget.finishLeftover()
        XCTAssertEqual(forget.phase, .finishing, "\(NavigationCopy.finishingForget) until it's done")

        channel.holdsAtAll = true
        forget.statusArrived(Self.holding)
        await forget.idle()
        XCTAssertEqual(channel.sent, [.hold], "no try while the app says a hold is under way")
        forget.statusArrived(Self.remembering)
        await eventually { mutator.deleted == [41] }
        await forget.idle()
        XCTAssertEqual(mutator.deleted, [41])
        XCTAssertNil(store.load())
        XCTAssertNil(forget.phase)
        XCTAssertEqual(channel.sent, [.hold, .hold, .release])
    }

    /// A forget that keeps failing is tried again only a few times in a
    /// window, so it never keeps stopping remembering; then the footer shows
    /// the app's own status again, and the promise waits for the next open.
    func testAForgetThatKeepsFailingIsTriedAgainOnlyAFewTimes() async throws {
        try store.save(ForgetRequest(momentIds: [41]))
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.holdsAtAll = false
        let forget = coordinator(mutator, channel)
        _ = await forget.finishLeftover()
        for _ in 0..<10 {
            forget.statusArrived(Self.remembering)
            await Task.yield()
            await forget.idle()
        }
        XCTAssertEqual(channel.sent.filter { $0 == .hold }.count, 1 + ForgetCoordinator.automaticTries)
        XCTAssertNil(forget.phase, "the app's own status shows again")
        XCTAssertNotNil(store.load(), "still promised for the next open")
    }

    /// The app's status arrives while the kept forget is under way, and its
    /// hold is then refused: the status isn't lost, and the forget is tried
    /// again as soon as that try ends, not only on the next status.
    func testAStatusHeardMidForgetIsNotLost() async throws {
        /// The first hold is answered only once the gate opens, and then
        /// refused; every later request is granted.
        final class RefusesOnce: WindowChannelSending, @unchecked Sendable {
            private let lock = NSLock()
            private var ops: [WindowChannelProtocol.Op] = []
            private var waiter: CheckedContinuation<Void, Never>?
            private var open = false

            var sent: [WindowChannelProtocol.Op] { lock.withLock { ops } }

            func openGate() {
                let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                    open = true
                    defer { waiter = nil }
                    return waiter
                }
                waiting?.resume()
            }

            func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
                let first: Bool = lock.withLock {
                    ops.append(request.op)
                    return request.op == .hold && ops.filter { $0 == .hold }.count == 1
                }
                guard first else { return true }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now: Bool = lock.withLock {
                        if open { return true }
                        waiter = continuation
                        return false
                    }
                    if now { continuation.resume() }
                }
                return false
            }

            func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
        }
        try store.save(ForgetRequest(momentIds: [41]))
        let mutator = LeaseMutator()
        let channel = RefusesOnce()
        let forget = ForgetCoordinator(mutator: mutator, channel: channel, store: store, appRunning: { true },
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        let first = Task { await forget.finishLeftover() }
        await eventually { channel.sent == [.hold] }
        forget.statusArrived(Self.remembering)
        channel.openGate()
        let outcome = await first.value
        XCTAssertEqual(outcome, .failed, "the first try's hold was refused")
        await forget.idle()
        XCTAssertEqual(mutator.deleted, [41], "tried again at once on the status heard meanwhile")
        XCTAssertNil(store.load())
        XCTAssertNil(forget.phase)
    }

    /// A stop that failed: the app's banner and its Quit show, not "Finishing
    /// a forget…", and nothing is tried until the app says a hold can be had.
    func testAKeptForgetNeverHidesTheAppsCouldNotStop() async throws {
        try store.save(ForgetRequest(momentIds: [41]))
        let channel = AppLikeChannel()
        channel.holdsAtAll = false
        let forget = coordinator(LeaseMutator(), channel)
        _ = await forget.finishLeftover()
        forget.statusArrived(WindowChannelStatus(state: .couldNotStop, title: "Couldn\u{2019}t stop", action: "quit"))
        await forget.idle()
        XCTAssertNil(forget.phase)
        XCTAssertEqual(channel.sent, [.hold])
    }

    /// A forget asked for now that fails goes back to the person (Try Again):
    /// it is never tried again behind their back.
    func testAForgetAskedForNowThatFailsIsNotTriedAgainOnItsOwn() async {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.holdsAtAll = false
        let forget = coordinator(mutator, channel)
        let outcome = await forget.forget(ForgetRequest(momentIds: [41]))
        XCTAssertEqual(outcome, .failed)
        channel.holdsAtAll = true
        forget.statusArrived(Self.remembering)
        await Task.yield()
        await forget.idle()
        XCTAssertEqual(channel.sent, [.hold])
        XCTAssertTrue(mutator.deleted.isEmpty)
        XCTAssertNil(forget.phase)
        XCTAssertNil(store.load())
    }

    // MARK: A forget that ends after its Undo note

    private final class RefusingApp: WindowChannelSending, @unchecked Sendable {
        func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool { request.op != .hold }
        func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
    }

    /// The trash button or ⌘⌫ on one moment: "Forgot 1 moment." with Undo,
    /// and the delete when the note closes. If the app can't hold remembering
    /// then, the moment stays saved, and SPEC 3.11 says "Couldn't forget it.
    /// It's still saved." [Try Again]: the window hears of it, with what to
    /// try again, instead of seeing what it sees after a forget that worked.
    func testAForgetThatFailsAfterItsUndoNoteSaysSo() async {
        let mutator = LeaseMutator()
        let forget = ForgetCoordinator(mutator: mutator, channel: RefusingApp(),
                                       store: PendingForgetStore(directory: nil, memory: "/tmp/verifier/mci.sqlite"),
                                       appRunning: { true }, deletions: MemoryDeletionSignal(center: NotificationCenter()))
        let immediate = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        XCTAssertNil(immediate, "the Undo note shows")
        XCTAssertNotNil(forget.undoable)
        await forget.finishUndoable()
        XCTAssertTrue(mutator.deleted.isEmpty, "the moment is still saved")
        XCTAssertFalse(forget.undoable == nil && forget.phase == nil && forget.lateOutcome == nil,
                       "nothing the window can observe says the forget failed; the row just comes back")
        XCTAssertEqual(forget.lateOutcome?.outcome, .failed)
        XCTAssertEqual(forget.lateOutcome?.request, ForgetRequest(momentIds: [41]), "what Try Again forgets")
        XCTAssertEqual(forget.lateOutcome?.count, 1)
    }

    /// One that went is heard too (for its Activity line), and a newer
    /// forget that moved the earlier one ahead never swallows its outcome.
    func testEveryForgetAfterItsNoteIsHeardOnce() async {
        let mutator = LeaseMutator()
        let forget = coordinator(mutator, AppLikeChannel())
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        await forget.finishUndoable()
        XCTAssertEqual(forget.lateOutcome?.outcome, .forgotten(moments: 1))
        let first = forget.lateOutcome?.id

        mutator.failing = [42]
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [42]), count: 1)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [43]), count: 1)
        XCTAssertEqual(forget.lateOutcome?.outcome, .failed, "the earlier one, moved ahead by the newer")
        XCTAssertEqual(forget.lateOutcome?.request.momentIds, [42])
        XCTAssertNotEqual(forget.lateOutcome?.id, first)
        forget.undo()
    }

    /// The shell says so: a failure with Try Again, which forgets at once,
    /// and the Activity line for one that went.
    func testTheShellSaysWhenAForgetFailsAfterItsNote() throws {
        let source = try Self.source("Sources/RecallUI/MemoryWorkspaceView.swift")
        XCTAssertTrue(source.contains(".onChange(of: forgetting.lateOutcome)"))
        XCTAssertTrue(source.contains("report(late.outcome, audit: audit) { forgetNow(late.request, count: late.count) }"))
        XCTAssertTrue(source.contains("let outcome = await forgetting.forget(request)"))
    }

    // MARK: Rows hidden at the click

    /// SPEC 3.11: "Rows that were hidden at the click stay gone." Through
    /// the Undo note, the wait for the hold and the deletes, and after.
    func testRowsHiddenByUndoStayHiddenWhileTheDeleteRuns() async {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        channel.gated = true
        let forget = coordinator(mutator, channel)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41, 42]), count: 2)
        XCTAssertEqual(forget.hiddenMoments, [41, 42], "hidden at the click")
        let deleting = Task { await forget.finishUndoable() }
        await eventually { channel.sent == [.hold] }
        XCTAssertNil(forget.undoable)
        XCTAssertEqual(forget.hiddenMoments, [41, 42], "still hidden while the delete waits for its hold")
        channel.openGate()
        await deleting.value
        XCTAssertEqual(mutator.deleted, [41, 42])
        XCTAssertTrue(forget.hiddenMoments.isEmpty, "deleted, so there is nothing left to hide")
    }

    /// Undo, or a forget that fails and goes back to the person, brings the
    /// rows back; a failure that keeps the promise keeps them hidden.
    func testRowsComeBackOnlyOnUndoOrWhenTheForgetGoesBackToThePerson() async throws {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        let forget = coordinator(mutator, channel)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        XCTAssertTrue(forget.undo())
        XCTAssertTrue(forget.hiddenMoments.isEmpty, "Undo brings the row back")

        channel.holdsAtAll = false
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [42]), count: 1)
        await forget.finishUndoable()
        XCTAssertEqual(forget.lateOutcome?.outcome, .failed)
        XCTAssertTrue(forget.hiddenMoments.isEmpty, "the row comes back, with Try Again")

        try store.save(ForgetRequest(momentIds: [43]))
        _ = await forget.finishLeftover()
        XCTAssertEqual(forget.hiddenMoments, [43], "kept to finish later: still hidden")

        mutator.failing = [45]
        channel.holdsAtAll = true
        let outcome = await forget.forget(ForgetRequest(momentIds: [44, 45]))
        XCTAssertEqual(outcome, .partlyForgotten(moments: 1))
        XCTAssertTrue(forget.hiddenMoments.contains(45), "the rest of a forget that went partly stays hidden")
        XCTAssertFalse(forget.hiddenMoments.contains(44))
    }

    /// "Finishing a forget…" is laid over the app's own status, so once the
    /// forget is done (or no try is left) the app's words, banner and button
    /// show again, not the last phase's.
    func testTheFooterShowsTheAppsOwnStatusOnceAForgetIsDone() throws {
        let source = try Self.source("Sources/RecallUI/MemoryWorkspaceView.swift")
        XCTAssertTrue(source.contains("status = (baseStatus ?? status).forgetting(phase)"))
        XCTAssertTrue(source.contains("baseStatus = base"))
        XCTAssertTrue(source.contains("baseStatus = current"))
        XCTAssertFalse(source.contains("status = status.forgetting(phase)"))
    }

    func testEveryListLeavesOutWhatTheCoordinatorHides() throws {
        let source = try Self.source("Sources/RecallUI/MemoryWorkspaceView.swift")
        XCTAssertTrue(source.contains(".environment(\\.forgottenMoments, forgetting.hiddenMoments)"))
    }

    // MARK: The Undo note

    /// Undo works for five seconds and the note showed for six, so a click
    /// in the sixth second closed the note while the forget went ahead. The
    /// note now shows exactly while Undo works.
    func testTheUndoNoteShowsExactlyWhileUndoWorks() throws {
        let shell = try Self.source("Sources/RecallUI/MemoryWorkspaceView.swift")
        XCTAssertTrue(shell.contains("for: ForgetCoordinator.undoWindow)"), "the note's time is Undo's")
        XCTAssertTrue(shell.contains("notes.dismiss(undoNote)"), "and it goes the moment Undo stops working")
        let notes = try Self.source("Sources/RecallUI/Notes/BottomNote.swift")
        XCTAssertTrue(notes.contains("for duration: Duration = shownFor"))
        XCTAssertTrue(notes.contains("try? await Task.sleep(for: duration)"))
    }

    /// Undo stops working the moment the forget goes ahead: `undoable` goes
    /// then, and with it the note.
    func testUndoStopsWorkingTheMomentTheForgetGoesAhead() async {
        let forget = coordinator()
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        XCTAssertNotNil(forget.undoable)
        await forget.finishUndoable()
        XCTAssertNil(forget.undoable)
        XCTAssertFalse(forget.undo(), "too late: the note went with it")
    }

    // MARK: Closing the window

    /// History, ⌘⌫ ("Forgot 1 moment." with Undo), then ⌘W within the
    /// note's five seconds. The window's process ends with its last window,
    /// so the forget goes before the reply that lets it quit: never left in
    /// the memory, where Ask and connected AI tools still find it, until the
    /// window next opens.
    func testClosingTheWindowDuringTheUndoNoteForgetsBeforeItQuits() async {
        let mutator = LeaseMutator()
        let channel = AppLikeChannel()
        let forget = coordinator(mutator, channel)
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        var deletedAtReply: [UInt64]?
        let replied = expectation(description: "the reply that lets the window quit")
        let waits = forget.finishBeforeQuitting(within: .seconds(5)) {
            deletedAtReply = mutator.deleted
            replied.fulfill()
        }
        XCTAssertTrue(waits, "terminateLater: a forget is waiting out its note")
        XCTAssertNil(forget.undoable, "the forget goes now, not when the note would have closed")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(deletedAtReply, [41], "deleted before the reply")
        XCTAssertEqual(channel.sent, [.hold, .release])
        XCTAssertNil(store.load())
    }

    /// Nothing waiting: the window quits at once.
    func testWithNothingUnderWayTheWindowQuitsAtOnce() {
        let forget = coordinator()
        XCTAssertFalse(forget.finishBeforeQuitting(within: .seconds(5)) { XCTFail("nothing to wait for") })
    }

    /// An app that takes too long to answer the hold: the window quits once
    /// its time is up, and the forget stays promised, since no note can say
    /// it failed; the next open finishes it.
    func testAQuitNeverWaitsPastItsBoundAndKeepsThePromise() async {
        final class SlowApp: WindowChannelSending, @unchecked Sendable {
            func send(_ request: WindowChannelRequest, timeout: Duration) async -> Bool {
                guard request.op == .hold else { return true }
                try? await Task.sleep(for: .milliseconds(600))
                return false
            }

            func statuses() -> AsyncStream<WindowChannelStatus> { AsyncStream { $0.finish() } }
        }
        let forget = ForgetCoordinator(mutator: LeaseMutator(), channel: SlowApp(), store: store, appRunning: { true },
                                       deletions: MemoryDeletionSignal(center: NotificationCenter()))
        _ = await forget.forgetAfterUndo(ForgetRequest(momentIds: [41]), count: 1)
        let started = ContinuousClock.now
        let replied = expectation(description: "the reply")
        XCTAssertTrue(forget.finishBeforeQuitting(within: .milliseconds(150)) { replied.fulfill() })
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(550), "the bound, not the hold")
        XCTAssertEqual(store.load(), ForgetRequest(momentIds: [41]))
        await forget.idle()
        XCTAssertEqual(store.load(), ForgetRequest(momentIds: [41]), "kept for the next open, not handed back")
    }

    /// The window's process asks before it quits, and waits for the reply.
    func testTheWindowFinishesItsForgetsBeforeItQuits() throws {
        let app = try Self.source("Sources/RecallUI/MCIRecallApp.swift")
        XCTAssertTrue(app.contains("MCIRecallApp.forget.finishBeforeQuitting {"))
        XCTAssertTrue(app.contains("NSApp.reply(toApplicationShouldTerminate: true)"))
        XCTAssertTrue(app.contains("return waits ? .terminateLater : .terminateNow"))
        XCTAssertTrue(app.contains("func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        true"),
                      "closing the last window quits, through applicationShouldTerminate")
    }

    static func source(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: The pending file, as a list

    /// Each forget has its own entry: one finishing removes only its own,
    /// and another memory's entries are kept, never applied here.
    func testAForgetsEndRemovesOnlyItsOwnPromise() throws {
        let other = PendingForgetStore(directory: folder, memory: "/elsewhere/demo.sqlite")
        try other.save(ForgetRequest(momentIds: [7]))
        let first = try store.save(ForgetRequest(momentIds: [41]))
        try store.save(ForgetRequest(spans: [.init(startUs: 10, endUs: 20)]))
        XCTAssertEqual(store.load(), ForgetRequest(momentIds: [41], spans: [.init(startUs: 10, endUs: 20)]))
        store.remove(first)
        XCTAssertEqual(store.load(), ForgetRequest(spans: [.init(startUs: 10, endUs: 20)]))
        XCTAssertEqual(other.load(), ForgetRequest(momentIds: [7]), "another memory's promise is kept")
        store.remove()
        XCTAssertNil(store.load())
        XCTAssertEqual(other.load(), ForgetRequest(momentIds: [7]))
        let file = folder.appendingPathComponent(PendingForgetStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// A forget the first build left, in its one-forget form, is still read
    /// and finished on the next open, then the file goes.
    func testAForgetTheFirstBuildLeftIsStillFinished() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = SidebarHides.memoryKey("/tmp/pipeline/mci.sqlite")
        let json = "{\"version\":1,\"memory\":\"\(key)\",\"request\":{\"momentIds\":[41],\"spans\":[]},\"createdUs\":5}"
        let file = folder.appendingPathComponent(PendingForgetStore.fileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(json.utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(store.load(), ForgetRequest(momentIds: [41]))
        let outcome = await coordinator().finishLeftover()
        XCTAssertEqual(outcome, .forgotten(moments: 1))
        XCTAssertEqual(mutator.calls, [[41]])
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
