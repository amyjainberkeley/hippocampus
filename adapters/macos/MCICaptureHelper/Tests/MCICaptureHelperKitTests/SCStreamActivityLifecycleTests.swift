import Foundation
import XCTest
@testable import MCICaptureHelperKit

// Headless session-task coverage, not qualification of ScreenCaptureKit, TCC,
// WindowServer, or real input reads. All observations and outbound bytes are synthetic.
final class SCStreamActivityLifecycleTests: XCTestCase {
    func testStartsOnceAndSamplesOnTheFourSecondCadence() async throws {
        let fixture = ActivityLifecycleFixture()
        try fixture.start()
        await fulfillment(of: [fixture.clock.reachedSleep(1)], timeout: 2)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            fixture.session.startMeasuredActivityIfNeeded(dependencies: fixture.dependencies)
        }
        XCTAssertEqual(fixture.clock.sleepDurations, [4_000_000_000])
        XCTAssertTrue(fixture.sink.frames.isEmpty, "Startup alone is not measured time")

        fixture.clock.advance(seconds: 4)
        await fulfillment(of: [fixture.clock.reachedSleep(2)], timeout: 2)
        try await fixture.session.stop()
        let interval = try XCTUnwrap(fixture.intervals().first)
        XCTAssertEqual(fixture.sink.frames.count, 1)
        XCTAssertEqual(interval.startUs, 100_000_000)
        XCTAssertEqual(interval.endUs, 104_000_000)
        XCTAssertEqual(interval.state, .inputActive)
        XCTAssertEqual(interval.appBundleId, ActivityLifecycleFixture.app)
        XCTAssertFalse(fixture.sink.usedUnconditionalWrite)
    }

    func testDisabledInactivePausedAndTerminalSessionsCannotStartSampler() async throws {
        let disabled = ActivityLifecycleFixture(enabled: false)
        try disabled.start()
        XCTAssertEqual(disabled.clock.sleepDurations.count, 0)
        XCTAssertEqual(disabled.probes.sessionReads, 0)
        try await disabled.session.stop()

        let fixture = ActivityLifecycleFixture()
        fixture.session.startMeasuredActivityIfNeeded(dependencies: fixture.dependencies)
        XCTAssertEqual(fixture.probes.sessionReads, 0)
        await fixture.session.pauseForTCC(surface: .screenRecording)
        try fixture.session.prepareCaptureStart()
        XCTAssertNil(fixture.session.beginCaptureLifecycle())
        fixture.session.startMeasuredActivityIfNeeded(dependencies: fixture.dependencies)
        XCTAssertEqual(fixture.probes.sessionReads, 0)
        try await fixture.session.stop()

        fixture.session.recordUnexpectedStreamTerminationForTest()
        XCTAssertThrowsError(try fixture.session.prepareCaptureStart())
        XCTAssertNil(fixture.session.beginCaptureLifecycle())
        fixture.session.startMeasuredActivityIfNeeded(dependencies: fixture.dependencies)
        XCTAssertTrue(fixture.sink.frames.isEmpty)
        XCTAssertEqual(fixture.probes.sessionReads, 0)
        try await fixture.session.stop()
    }

    func testStopJoinsPendingDeliveryAndInvalidatesItsAdmission() async throws {
        try await assertDrain(tcc: false)
    }

    func testTCCRevokeCancelsAndJoinsPendingDeliveryWithoutLateWrites() async throws {
        try await assertDrain(tcc: true)
    }

    private func assertDrain(tcc: Bool) async throws {
        let fixture = ActivityLifecycleFixture(stallDelivery: true)
        try fixture.start()
        await fulfillment(of: [fixture.clock.reachedSleep(1)], timeout: 2)
        fixture.clock.advance(seconds: 4)
        await fulfillment(of: [fixture.sink.entered], timeout: 2)
        let completion = ActivityLifecycleFlag()
        let stopping = Task {
            if tcc {
                await fixture.session.tccStatusDidTransition(.init(
                    surface: .screenRecording, oldStatus: .granted, newStatus: .denied
                ))
            } else {
                try await fixture.session.stop()
            }
            completion.set()
        }
        await fulfillment(of: [fixture.sink.cancelled], timeout: 2)
        XCTAssertFalse(completion.value, "Shutdown must join the in-flight sampler task")
        XCTAssertEqual(fixture.sink.currentAdmission, false, "Epoch invalidation must reject the pending write")
        fixture.sink.release()
        try await stopping.value
        let readsAfterStop = fixture.probes.sessionReads
        fixture.clock.advance(seconds: 4)
        XCTAssertTrue(fixture.sink.frames.isEmpty)
        XCTAssertEqual(fixture.probes.sessionReads, readsAfterStop)
        XCTAssertEqual(fixture.session.isPausedForTCCForTest(), tcc)
        XCTAssertNil(fixture.session.beginCaptureLifecycle())
        try await fixture.session.stop()
    }

    func testRestartHasNewGenerationAndCannotBridgeEvenAShortStoppedGap() async throws {
        let fixture = ActivityLifecycleFixture()
        try fixture.start()
        await fulfillment(of: [fixture.clock.reachedSleep(1)], timeout: 2)
        fixture.clock.advance(seconds: 4)
        await fulfillment(of: [fixture.clock.reachedSleep(2)], timeout: 2)
        try await fixture.session.stop()
        fixture.clock.advance(seconds: 1)

        try fixture.start()
        await fulfillment(of: [fixture.clock.reachedSleep(3)], timeout: 2)
        XCTAssertEqual(fixture.sink.frames.count, 1, "A fresh task must not bridge the one-second stopped gap")
        fixture.clock.advance(seconds: 4)
        await fulfillment(of: [fixture.clock.reachedSleep(4)], timeout: 2)
        try await fixture.session.stop()

        let intervals = try fixture.intervals()
        XCTAssertEqual(intervals.count, 2)
        guard intervals.count == 2 else { return }
        XCTAssertEqual(intervals.map(\.startUs), [100_000_000, 105_000_000])
        XCTAssertEqual(intervals.map(\.endUs), [104_000_000, 109_000_000])
        XCTAssertNotEqual(intervals[0].captureGeneration, intervals[1].captureGeneration)
        XCTAssertNotNil(UUID(uuidString: intervals[0].captureGeneration))
        XCTAssertNotNil(UUID(uuidString: intervals[1].captureGeneration))
    }

    func testSessionEligibilityFlipAtReadBoundaryLosesAttribution() async throws {
        let fixture = ActivityLifecycleFixture(sessionFlip: true)
        let interval = try await sampleTwoObservations(fixture)
        XCTAssertEqual(fixture.probes.sessionReads, 4, "Both endpoints need two session reads")
        XCTAssertEqual(interval.state, .unknown)
        XCTAssertNil(interval.appBundleId)
    }

    func testFocusGenerationFlipAtReadBoundaryLosesAttribution() async throws {
        let fixture = ActivityLifecycleFixture(focusFlip: true)
        let interval = try await sampleTwoObservations(fixture)
        XCTAssertEqual(fixture.store.currentSync().generation, 2)
        XCTAssertEqual(interval.state, .unknown)
        XCTAssertNil(interval.appBundleId)
    }

    func testActualPipelinePrivacyDenialCannotCarryAppIdentity() async throws {
        let fixture = ActivityLifecycleFixture(secureInput: true)
        let interval = try await sampleTwoObservations(fixture)
        XCTAssertEqual(interval.state, .unknown)
        XCTAssertNil(interval.appBundleId)
        XCTAssertFalse(String(decoding: try XCTUnwrap(fixture.sink.frames.first), as: UTF8.self)
            .contains(ActivityLifecycleFixture.app))
    }

    private func sampleTwoObservations(_ fixture: ActivityLifecycleFixture) async throws -> MeasuredActivityInterval {
        try fixture.start()
        await fulfillment(of: [fixture.clock.reachedSleep(1)], timeout: 2)
        fixture.clock.advance(seconds: 4)
        await fulfillment(of: [fixture.clock.reachedSleep(2)], timeout: 2)
        try await fixture.session.stop()
        XCTAssertEqual(fixture.sink.frames.count, 1)
        return try XCTUnwrap(fixture.intervals().first)
    }
}

private struct ActivityLifecycleFixture: Sendable {
    static let app = "com.example.Editor"
    let store: FocusedWindowStore
    let probes: ActivityLifecycleProbes
    let clock = ActivityLifecycleClock()
    let sink: ActivityLifecycleSink
    let session: SCStreamCaptureSession

    init(enabled: Bool = true, stallDelivery: Bool = false, sessionFlip: Bool = false,
         focusFlip: Bool = false, secureInput: Bool = false) {
        store = FocusedWindowStore(initial: .init(
            focused: FocusedWindow(bundleId: Self.app, windowId: 1), generation: 1
        ))
        probes = ActivityLifecycleProbes(store: store, sessionFlip: sessionFlip,
                                        focusFlip: focusFlip, secureInput: secureInput)
        sink = ActivityLifecycleSink(stalled: stallDelivery)
        let cascade = SuppressionCascade(
            secureEventInput: probes, axSecureSubrole: probes, denylist: probes,
            blackedRegion: probes, knownSafeAppBundles: [Self.app]
        )
        session = SCStreamCaptureSession(
            pipeline: SCStreamPipeline(cascade: cascade, encoder: NoActivityEncoder(), sink: sink),
            denylist: Denylist(entries: []), focusedWindowStore: store, measuresActivity: enabled,
            runtimeFailureHandler: { _ in }
        )
    }

    var dependencies: MeasuredActivityDependencies {
        MeasuredActivityDependencies(
            now: { [clock] in clock.now },
            sleep: { [clock] in try await clock.sleep(nanoseconds: $0) },
            sessionEligible: { [probes] in probes.permitsMeasurement() },
            secondsSinceLastInput: { 0 }
        )
    }

    func start() throws {
        try session.prepareCaptureStart()
        guard session.beginCaptureLifecycle() != nil else { throw ActivityLifecycleError.inactive }
        session.startMeasuredActivityIfNeeded(dependencies: dependencies)
    }

    func intervals() throws -> [MeasuredActivityInterval] {
        try sink.frames.map { frame in
            var cursor = minFrameHeaderBytes
            func integer(_ count: Int) throws -> UInt64 {
                guard cursor + count <= frame.count else { throw ActivityLifecycleError.malformedFrame }
                defer { cursor += count }
                return frame[cursor..<(cursor + count)].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
            }
            func string() throws -> String {
                let length = Int(try integer(2))
                guard cursor + length <= frame.count else { throw ActivityLifecycleError.malformedFrame }
                defer { cursor += length }
                return String(decoding: frame[cursor..<(cursor + length)], as: UTF8.self)
            }
            let start = try integer(8), end = try integer(8)
            guard let state = MeasuredActivityState(rawValue: UInt8(try integer(1))) else {
                throw ActivityLifecycleError.malformedFrame
            }
            let app = try string(), generation = try string()
            guard cursor == frame.count else { throw ActivityLifecycleError.malformedFrame }
            return MeasuredActivityInterval(startUs: start, endUs: end, state: state,
                                            appBundleId: app.isEmpty ? nil : app, captureGeneration: generation)
        }
    }
}

private enum ActivityLifecycleError: Error { case inactive, malformedFrame }

private struct NoActivityEncoder: FrameEncoder {
    func encodeAllowedFrame(input: EncoderInput?, seq: UInt64, context: WorkflowContext) async throws {
        XCTFail("Activity must never encode a screen frame")
    }
}

private final class ActivityLifecycleProbes: SecureEventInputProbe, AXSecureSubroleProbe,
    DenylistProbe, BlackedRegionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let store: FocusedWindowStore
    private let sessionFlip: Bool
    private let focusFlip: Bool
    private let secureInput: Bool
    private var sessionReadCount = 0
    private var axReadCount = 0

    init(store: FocusedWindowStore, sessionFlip: Bool, focusFlip: Bool, secureInput: Bool) {
        self.store = store
        self.sessionFlip = sessionFlip
        self.focusFlip = focusFlip
        self.secureInput = secureInput
    }
    var sessionReads: Int { lock.withLock { sessionReadCount } }
    func permitsMeasurement() -> Bool {
        lock.withLock {
            sessionReadCount += 1
            return !sessionFlip || sessionReadCount != 2
        }
    }
    func focusedHasSecureSubrole() -> Bool? {
        lock.withLock {
            axReadCount += 1
            if focusFlip && axReadCount == 1 {
                store.storeSync(FocusedWindow(bundleId: ActivityLifecycleFixture.app, windowId: 2))
            }
        }
        return false
    }
    func isSecureEventInputEnabled() -> Bool { secureInput }
    func hasBlackedRegion() -> Bool { false }
    func appIsDenied(bundleId: String) -> Bool { false }
    func urlIsDenied(_ url: String) -> Bool { false }
    func windowTitleIsDenied(_ title: String) -> Bool { false }
}

// A manually released continuation also lets the sink model an in-flight
// operation that observes cancellation but must still be joined by its owner.
private final class ActivityLifecycleTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func install(_ next: CheckedContinuation<Void, Error>) {
        let completed = lock.withLock { () -> Result<Void, Error>? in
            if let result { return result }
            continuation = next
            return nil
        }
        if let completed { next.resume(with: completed) }
    }
    func finish(_ outcome: Result<Void, Error> = .success(())) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = outcome
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: outcome)
    }
}

private final class ActivityLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: UInt64 = 100
    private var durations: [UInt64] = []
    private var tickets: [ActivityLifecycleTicket] = []
    private var observers: [(Int, XCTestExpectation)] = []
    var now: (tsUs: UInt64, uptimeNs: UInt64) {
        lock.withLock { (seconds * 1_000_000, seconds * 1_000_000_000) }
    }
    var sleepDurations: [UInt64] { lock.withLock { durations } }
    func reachedSleep(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "sampler reached sleep \(count)")
        let reached = lock.withLock {
            if durations.count >= count { return true }
            observers.append((count, expectation))
            return false
        }
        if reached { expectation.fulfill() }
        return expectation
    }
    func sleep(nanoseconds: UInt64) async throws {
        let ticket = ActivityLifecycleTicket()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ticket.install(continuation)
                let ready = lock.withLock {
                    durations.append(nanoseconds)
                    tickets.append(ticket)
                    let ready = observers.filter { $0.0 <= durations.count }
                    observers.removeAll { $0.0 <= durations.count }
                    return ready
                }
                for (_, observer) in ready { observer.fulfill() }
            }
        } onCancel: {
            ticket.finish(.failure(CancellationError()))
        }
    }
    func advance(seconds step: UInt64) {
        let pending = lock.withLock {
            seconds += step
            defer { tickets.removeAll() }
            return tickets
        }
        for ticket in pending { ticket.finish() }
    }
}

private final class ActivityLifecycleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ActivityLifecycleSink: AdmissionControlledFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private let stalled: Bool
    private let ticket = ActivityLifecycleTicket()
    private var storedFrames: [Data] = []
    private var unconditional = false
    private var admission: (@Sendable () -> Bool)?
    let entered = XCTestExpectation(description: "activity delivery entered")
    let cancelled = XCTestExpectation(description: "activity delivery cancelled")

    init(stalled: Bool) { self.stalled = stalled }
    var frames: [Data] { lock.withLock { storedFrames } }
    var usedUnconditionalWrite: Bool { lock.withLock { unconditional } }
    var currentAdmission: Bool? { lock.withLock { admission }?() }
    func release() { ticket.finish() }
    func write(_ data: Data) async throws {
        lock.withLock { unconditional = true }
        XCTFail("The sampler must use conditional delivery")
    }
    func writeIfCurrent(_ data: Data, admitted: @escaping @Sendable () -> Bool) async throws -> Bool {
        lock.withLock { admission = admitted }
        if stalled {
            entered.fulfill()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { ticket.install($0) }
            } onCancel: {
                self.cancelled.fulfill()
            }
        }
        guard !Task.isCancelled, admitted() else { return false }
        lock.withLock { storedFrames.append(data) }
        return true
    }
}
