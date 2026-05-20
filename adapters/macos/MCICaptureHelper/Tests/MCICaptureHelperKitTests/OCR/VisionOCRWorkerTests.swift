// SPDX-License-Identifier: TBD-private
//
// VisionOCRWorkerTests — pins the ADR-0016 §1.1 concurrency contract
// for the OCR worker WITHOUT touching Apple Vision. Uses a
// `StubOCREngine` that returns canned results / canned timeouts /
// canned errors, the same indirection-seam pattern PRs #36/#37/#38
// established for `SecureEventInputProbe` / `AXSecureSubroleProbe` /
// `BlackedRegionProbe`.
//
// PROTECTED-SET adjacent. The worker itself is helper-internal in
// P3.5 (no IPC seam, no cascade wiring); the §4 invariants in
// ADR-0016 are vacuously held this PR. These tests pin the queue /
// drop-oldest / timeout / ROI-passthrough behavior that P3.6 will
// integrate.

import CoreGraphics
import CoreVideo
import os
import XCTest

@testable import MCICaptureHelperKit

// MARK: - Stub engine

/// Stub `OCREngine` that records every recognize call and returns a
/// caller-configurable canned `OCRResult`. Thread-safe via an
/// `OSAllocatedUnfairLock`; Swift 6 strict concurrency forbids
/// `NSLock` in async contexts.
final class StubOCREngine: OCREngine, @unchecked Sendable {
    /// One observed call.
    struct Call: Sendable, Equatable {
        let roi: CGRect
        let timeoutMs: Int
    }

    /// What the engine will return on the next recognize call.
    enum Mode: Sendable {
        /// Return a canned `OCRResult` immediately.
        case canned(OCRResult)
        /// Sleep `delayMs` ms, then return canned.
        case delayed(delayMs: Int, result: OCRResult)
        /// Hold the call until `release()` is invoked, then return canned.
        case heldUntilReleased(result: OCRResult)
    }

    private struct State {
        var mode: Mode
        var calls: [Call] = []
        var heldContinuations: [CheckedContinuation<Void, Never>] = []
    }

    private let cell: OSAllocatedUnfairLock<State>

    init(mode: Mode) {
        self.cell = OSAllocatedUnfairLock(initialState: State(mode: mode))
    }

    func setMode(_ m: Mode) {
        cell.withLock { $0.mode = m }
    }

    var calls: [Call] {
        cell.withLock { $0.calls }
    }

    var callCount: Int {
        cell.withLock { $0.calls.count }
    }

    /// Release all held continuations (lets every `heldUntilReleased`
    /// call return its canned result).
    func release() {
        let pending: [CheckedContinuation<Void, Never>] = cell.withLock { state in
            let p = state.heldContinuations
            state.heldContinuations.removeAll()
            return p
        }
        for cc in pending { cc.resume() }
    }

    func recognize(
        input: OCREngineInput,
        timeoutMs: Int
    ) async -> OCRResult {
        let captured: Mode = cell.withLock { state in
            state.calls.append(Call(roi: input.roi, timeoutMs: timeoutMs))
            return state.mode
        }

        switch captured {
        case .canned(let r):
            return r
        case .delayed(let delayMs, let r):
            try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
            return r
        case .heldUntilReleased(let r):
            await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
                cell.withLock { state in
                    state.heldContinuations.append(cc)
                }
            }
            return r
        }
    }
}

// MARK: - Pixel-buffer helper

/// Make a tiny opaque `CVPixelBuffer` so the worker has something to
/// shuttle through. The stub engine never reads it; tests only check
/// metadata flow (ROI, timeout, order). 8×8 BGRA is enough.
private func makeTestPixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        8, 8,
        kCVPixelFormatType_32BGRA,
        nil,
        &pb
    )
    precondition(status == kCVReturnSuccess && pb != nil,
                 "CVPixelBufferCreate failed for test fixture")
    return pb!
}

// MARK: - Delivery collector

/// Thread-safe accumulator for delivered `OCRResult`s. Tests submit
/// jobs whose completions append to this; `await waitForCount(_:)`
/// blocks until the expected count lands or the deadline expires.
final class ResultCollector: @unchecked Sendable {
    private let cell = OSAllocatedUnfairLock<[OCRResult]>(initialState: [])

    func append(_ r: OCRResult) {
        cell.withLock { $0.append(r) }
    }

    var results: [OCRResult] {
        cell.withLock { $0 }
    }

    var count: Int {
        cell.withLock { $0.count }
    }

    func waitForCount(_ n: Int, timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if count >= n { return true }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        return false
    }
}

// MARK: - Tests

final class VisionOCRWorkerTests: XCTestCase {
    // MARK: Delivery order + canned result passthrough

    func testEnqueueAndDeliverInSubmissionOrder() async {
        // Three jobs, each tagged via a distinct ROI so the collector
        // can prove order. Stub returns a canned OCRResult that
        // encodes its ROI in confidence (cheap order tag).
        let stub = StubOCREngine(mode: .canned(OCRResult(
            recognizedLines: [OCRLine(
                text: "hello",
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 0.0
            )],
            durationMs: 1,
            timedOut: false
        )))
        let worker = VisionOCRWorker(engine: stub, capacity: 8, timeoutMs: 1000)
        await worker.start()
        defer {
            Task { await worker.stop() }
        }

        let collector = ResultCollector()
        for i in 0 ..< 3 {
            let tag = OCRResult(
                recognizedLines: [OCRLine(
                    text: "n=\(i)",
                    boundingBox: CGRect(x: Double(i) / 10.0, y: 0, width: 1, height: 1),
                    confidence: Float(i)
                )],
                durationMs: UInt64(i),
                timedOut: false
            )
            stub.setMode(.canned(tag))
            await worker.submit(
                pixelBuffer: makeTestPixelBuffer(),
                dirtyRectsBoundingROI: CGRect(x: Double(i) / 10.0, y: 0, width: 1, height: 1),
                completion: { r in collector.append(r) }
            )
            // Tiny pause to let the consumer drain before the next
            // setMode runs — otherwise the canned mode may be
            // overwritten before the consumer reads it. This
            // approximates "submit a frame, get OCR'd text, submit
            // the next" which is the real-world cadence the worker
            // is built for.
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }

        let landed = await collector.waitForCount(3, timeout: 2.0)
        XCTAssertTrue(landed, "only \(collector.count) of 3 results landed")
        XCTAssertEqual(collector.results.map { $0.durationMs }, [0, 1, 2])
    }

    // MARK: Drop-oldest at capacity

    func testDropsOldestWhenQueueFull() async {
        // Capacity = 2. Hold the first call so the queue can fill.
        // Submit 3 jobs: first becomes the in-flight call (held);
        // jobs 2 & 3 sit in the queue. With cap=2 the queue cannot
        // hold both — submit(3) drops the oldest pending (which is
        // job 2, since job 1 has already been taken into the
        // consumer's in-flight slot). The test demonstrates the
        // generic "drop on overflow" invariant; the specific job
        // dropped depends on whether the consumer has dequeued yet.
        // To make the assertion deterministic we sequence submits so
        // the consumer is already blocked on job 1 before job 2 lands.
        let stub = StubOCREngine(mode: .heldUntilReleased(result: OCRResult(
            recognizedLines: [],
            durationMs: 1,
            timedOut: false
        )))
        let worker = VisionOCRWorker(engine: stub, capacity: 2, timeoutMs: 1000)
        await worker.start()

        let collector = ResultCollector()

        // Submit 1; wait for consumer to take it off the queue + start
        // awaiting the stub.
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: CGRect(x: 0.1, y: 0, width: 1, height: 1),
            completion: { r in collector.append(r) }
        )
        // Spin until the stub has observed the first call (it logged
        // it before awaiting the continuation).
        let deadline1 = Date().addingTimeInterval(0.5)
        while Date() < deadline1, stub.callCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(stub.callCount, 1, "consumer did not pick up job 1")

        // Submit 2 + 3 + 4 — these queue. cap=2 means after submit(4)
        // job 2 has been dropped.
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: CGRect(x: 0.2, y: 0, width: 1, height: 1),
            completion: { _ in collector.append(OCRResult(recognizedLines: [], durationMs: 2, timedOut: false)) }
        )
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: CGRect(x: 0.3, y: 0, width: 1, height: 1),
            completion: { _ in collector.append(OCRResult(recognizedLines: [], durationMs: 3, timedOut: false)) }
        )
        let droppedAfter3 = await worker.droppedCount()
        XCTAssertEqual(droppedAfter3, 0,
                       "cap=2, two pending submits should NOT drop")

        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: CGRect(x: 0.4, y: 0, width: 1, height: 1),
            completion: { _ in collector.append(OCRResult(recognizedLines: [], durationMs: 4, timedOut: false)) }
        )
        let droppedAfter4 = await worker.droppedCount()
        XCTAssertEqual(droppedAfter4, 1,
                       "third pending submit should drop the oldest pending")

        // Now release the stub. Job 1 returns; the consumer picks up
        // the survivors from the queue (job 3 + job 4, the dropped
        // job 2 is gone).
        stub.setMode(.canned(OCRResult(
            recognizedLines: [],
            durationMs: 9,
            timedOut: false
        )))
        stub.release()

        let landed = await collector.waitForCount(3, timeout: 2.0)
        XCTAssertTrue(landed, "expected 3 deliveries (1 + 3 + 4), got \(collector.count)")

        await worker.stop()
    }

    // MARK: ocr_dropped_count increments

    func testDroppedCountStartsAtZeroAndIncrements() async {
        let stub = StubOCREngine(mode: .heldUntilReleased(result: OCRResult(
            recognizedLines: [],
            durationMs: 0,
            timedOut: false
        )))
        let worker = VisionOCRWorker(engine: stub, capacity: 1, timeoutMs: 1000)
        await worker.start()
        let initialDropped = await worker.droppedCount()
        XCTAssertEqual(initialDropped, 0)

        // Submit 1 — gets taken by consumer + held.
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { _ in }
        )
        // Wait for consumer to take it.
        let dl = Date().addingTimeInterval(0.5)
        while Date() < dl, stub.callCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Now submit 2 + 3 + 4 with cap=1. Each subsequent submit
        // over capacity drops the previous queued job.
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { _ in })
        let dropped1 = await worker.droppedCount()
        XCTAssertEqual(dropped1, 0)
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { _ in })
        let dropped2 = await worker.droppedCount()
        XCTAssertEqual(dropped2, 1)
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { _ in })
        let dropped3 = await worker.droppedCount()
        XCTAssertEqual(dropped3, 2)

        stub.release()
        await worker.stop()
    }

    // MARK: Canned result delivery

    func testCannedResultIsDeliveredIntact() async {
        let line = OCRLine(
            text: "Lorem ipsum",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1),
            confidence: 0.87
        )
        let canned = OCRResult(
            recognizedLines: [line],
            durationMs: 42,
            timedOut: false
        )
        let stub = StubOCREngine(mode: .canned(canned))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()
        defer { Task { await worker.stop() } }

        let collector = ResultCollector()
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        let landed = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertTrue(landed)
        XCTAssertEqual(collector.results.first, canned)
    }

    // MARK: Timeout result delivery

    func testTimeoutResultIsDeliveredIntact() async {
        let timedOut = OCRResult(
            recognizedLines: [],
            durationMs: 1000,
            timedOut: true
        )
        let stub = StubOCREngine(mode: .canned(timedOut))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()
        defer { Task { await worker.stop() } }

        let collector = ResultCollector()
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        let landed = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertTrue(landed)
        XCTAssertEqual(collector.results.first?.timedOut, true)
        XCTAssertTrue(collector.results.first?.recognizedLines.isEmpty ?? false)
    }

    // MARK: Engine-error result delivery (empty lines, timedOut=false)

    func testEngineErrorResultIsDeliveredAsEmptyLines() async {
        // "Engine error" arm of the contract: empty lines, NOT
        // timed out. Worker delivers the canned result verbatim;
        // the engine is the one that maps internal errors to this
        // shape (see `VisionOCRRunner.runVisionPerform`).
        let errorResult = OCRResult(
            recognizedLines: [],
            durationMs: 7,
            timedOut: false
        )
        let stub = StubOCREngine(mode: .canned(errorResult))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()
        defer { Task { await worker.stop() } }

        let collector = ResultCollector()
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        let landed = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertTrue(landed)
        XCTAssertEqual(collector.results.first?.recognizedLines.count, 0)
        XCTAssertEqual(collector.results.first?.timedOut, false)
    }

    // MARK: ROI normalization passthrough

    func testROIIsPassedToEngineVerbatim() async {
        let stub = StubOCREngine(mode: .canned(.empty))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()
        defer { Task { await worker.stop() } }

        let collector = ResultCollector()
        let roi = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: roi,
            completion: { collector.append($0) }
        )
        let landed = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertTrue(landed)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.roi, roi)
    }

    // MARK: Timeout argument passthrough

    func testTimeoutArgumentIsPassedToEngine() async {
        let stub = StubOCREngine(mode: .canned(.empty))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 750)
        await worker.start()
        defer { Task { await worker.stop() } }

        let collector = ResultCollector()
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        _ = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertEqual(stub.calls.first?.timeoutMs, 750)
    }

    // MARK: Stop cancels consumer / discards pending

    func testStopDiscardsPendingAndIsIdempotent() async {
        let stub = StubOCREngine(mode: .heldUntilReleased(result: OCRResult(
            recognizedLines: [],
            durationMs: 0,
            timedOut: false
        )))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()

        let collector = ResultCollector()

        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        // Wait for consumer to begin awaiting the stub.
        let dl = Date().addingTimeInterval(0.5)
        while Date() < dl, stub.callCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(stub.callCount, 1)

        // Enqueue a few more so stop has pending work to abandon.
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { collector.append($0) })
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { collector.append($0) })
        let pendingBeforeStop = await worker.pendingCount()
        XCTAssertEqual(pendingBeforeStop, 2)

        await worker.stop()
        await worker.stop()  // idempotent — second stop is a no-op
        let stopped = await worker.isStopped()
        XCTAssertTrue(stopped)
        let pendingAfterStop = await worker.pendingCount()
        XCTAssertEqual(pendingAfterStop, 0,
                       "stop() should discard pending jobs")

        // Submits on a stopped worker are silently dropped (no
        // completion fires).
        await worker.submit(pixelBuffer: makeTestPixelBuffer(),
                            dirtyRectsBoundingROI: .zero,
                            completion: { collector.append($0) })
        let pendingAfterPostStopSubmit = await worker.pendingCount()
        XCTAssertEqual(pendingAfterPostStopSubmit, 0)
    }

    // MARK: Start is idempotent

    func testStartIsIdempotent() async {
        let stub = StubOCREngine(mode: .canned(.empty))
        let worker = VisionOCRWorker(engine: stub, capacity: 4, timeoutMs: 1000)
        await worker.start()
        await worker.start()  // second start must NOT spawn a second consumer
        defer { Task { await worker.stop() } }

        // The single-consumer invariant is enforced by the
        // `precondition(awaiter == nil)` guard inside `waitForJob`;
        // a doubled consumer would trip it. Drive a submit through
        // and verify exactly one delivery.
        let collector = ResultCollector()
        await worker.submit(
            pixelBuffer: makeTestPixelBuffer(),
            dirtyRectsBoundingROI: .zero,
            completion: { collector.append($0) }
        )
        let landed = await collector.waitForCount(1, timeout: 1.0)
        XCTAssertTrue(landed)
        XCTAssertEqual(stub.callCount, 1, "doubled start would re-submit")
    }

    // MARK: Default constants

    func testDefaultsMatchADR0016() {
        XCTAssertEqual(VisionOCRWorker.defaultCapacity, 4,
                       "ADR-0016 §1.1 default queue capacity is 4")
        XCTAssertEqual(VisionOCRWorker.defaultTimeoutMs, 1000,
                       "ADR-0016 §1.1 default per-job timeout is 1000 ms")
    }
}
