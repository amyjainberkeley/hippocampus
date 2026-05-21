// SPDX-License-Identifier: TBD-private
//
// VisionOCRWorker — bounded-queue + drop-oldest + per-job-timeout
// driver for the Apple Vision OCR pipeline. Owns the ADR-0016 §1.1
// concurrency contract: a single in-flight `OCREngine.recognize(...)`
// at a time, a bounded MPSC channel of pending jobs (default capacity
// 4), drop-oldest-on-overflow with a content-free counter the helper
// can surface as `ocr_dropped_count`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ SCOPE OF P3.5 — NO CASCADE WIRING.                                │
// │                                                                  │
// │ This worker EXISTS but nothing in production invokes it yet.     │
// │ `SCStreamCaptureSession.swift` is NOT modified by this PR; the   │
// │ wire schema is NOT bumped; the IPC seam carries no OCR payload.  │
// │ All of that lands in the CSO-gated P3.6 PR alongside the         │
// │ cascade-twice plumbing (cascade §6 OCR-time secret/PII regex     │
// │ re-runs over the OCR'd text before any IPC emission).            │
// │                                                                  │
// │ The §4 invariants in ADR-0016 are therefore VACUOUSLY HELD this  │
// │ PR — the worker has no production caller, so it cannot leak.     │
// │ The CSO sign-off block on the PR body asserts this explicitly.   │
// └──────────────────────────────────────────────────────────────────┘
//
// Cites ADR-0016 §1.1 (single worker actor, bounded MPSC channel,
// dirty-rect ROI scoping, per-job wall-clock timeout, drop-oldest
// telemetry mirrors the `frames_redacted_by_failsafe` counter from
// PR #47).

import CoreGraphics
import CoreVideo
import Foundation

/// Bounded-queue OCR worker. Submits run against a configured
/// `OCREngine` one at a time; over-capacity submits drop the oldest
/// pending job and increment an internal counter.
///
/// ## Lifecycle
///   - construct with `init(engine:capacity:timeoutMs:)`
///   - call `start()` to spin up the consumer task
///   - call `submit(pixelBuffer:dirtyRectsBoundingROI:completion:)`
///     to enqueue work; results land on the supplied @Sendable
///     completion
///   - call `stop()` to cancel the consumer; pending jobs are
///     discarded (completions are NOT invoked for discarded jobs)
///
/// `start()` and `stop()` are idempotent; submitting after `stop()`
/// silently drops the work (it cannot run — by design; a stopped
/// worker is end-of-life).
///
/// ## Why a manual queue and not `AsyncStream`
///
/// `AsyncStream(bufferingPolicy: .bufferingNewest(n))` would express
/// drop-oldest cleanly, but it silently drops without a count. We need
/// the count for `ocr_dropped_count` telemetry (ADR-0016 §3 cap budget
/// + the Phase-3 P3.11 live-Mac audit). Manual queue keeps the count
/// visible.
public actor VisionOCRWorker {
    /// Default queue capacity per ADR-0016 §1.1.
    public static let defaultCapacity: Int = 4

    /// Default per-job wall-clock timeout per ADR-0016 §1.1.
    public static let defaultTimeoutMs: Int = 1000

    private let engine: OCREngine
    private let capacity: Int
    private let timeoutMs: Int

    private var queue: [Job] = []
    private var dropped: UInt64 = 0
    private var consumer: Task<Void, Never>?
    private var awaiter: CheckedContinuation<Void, Never>?
    private var stopped: Bool = false

    public init(
        engine: OCREngine,
        capacity: Int = VisionOCRWorker.defaultCapacity,
        timeoutMs: Int = VisionOCRWorker.defaultTimeoutMs
    ) {
        precondition(capacity >= 1, "VisionOCRWorker capacity must be ≥ 1")
        precondition(timeoutMs >= 1, "VisionOCRWorker timeoutMs must be ≥ 1")
        self.engine = engine
        self.capacity = capacity
        self.timeoutMs = timeoutMs
    }

    /// Spin up the consumer task. Idempotent — calling twice is a
    /// no-op. A worker that has been `stop()`ped cannot be restarted;
    /// the call is a no-op on a stopped worker.
    public func start() {
        guard consumer == nil, !stopped else { return }
        consumer = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the consumer task and abandon any pending work. Idempotent.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        consumer?.cancel()
        consumer = nil
        queue.removeAll()
        if let a = awaiter {
            awaiter = nil
            a.resume()
        }
    }

    /// Submit one OCR job. If the queue is at capacity, the oldest
    /// pending job is dropped, `ocr_dropped_count` (`droppedCount()`)
    /// is incremented, and the new job is enqueued. A dropped job's
    /// completion is NOT invoked — the caller treats fire-and-forget
    /// submission with no delivery guarantee, exactly mirroring the
    /// `frames_redacted_by_failsafe` pattern from PR #47.
    ///
    /// Submits on a stopped worker are silently discarded.
    public func submit(
        pixelBuffer: CVPixelBuffer,
        dirtyRectsBoundingROI: CGRect,
        completion: @Sendable @escaping (OCRResult) -> Void
    ) {
        submit(
            input: OCREngineInput(
                pixelBuffer: pixelBuffer,
                roi: dirtyRectsBoundingROI
            ),
            completion: completion
        )
    }

    /// Sendable-input overload (ADR-0016 P3.6). `OCREngineInput` is
    /// `@unchecked Sendable` so the caller can construct it in a
    /// non-actor context and pass it across the actor boundary
    /// without tripping Swift 6 strict-concurrency `sending` checks.
    public func submit(
        input: OCREngineInput,
        completion: @Sendable @escaping (OCRResult) -> Void
    ) {
        guard !stopped else { return }
        if queue.count >= capacity {
            _ = queue.removeFirst()
            dropped &+= 1
        }
        queue.append(Job(input: input, completion: completion))
        if let a = awaiter {
            awaiter = nil
            a.resume()
        }
    }

    /// Snapshot of the drop-oldest counter. Content-free — the counter
    /// is the count of dropped pending jobs, never per-frame content.
    /// P3.6 surfaces this on `HelperHealthCounters` for the wire.
    public func droppedCount() -> UInt64 {
        dropped
    }

    /// Snapshot of the current pending count. Test helper; the
    /// production helper does not consult this on the hot path.
    public func pendingCount() -> Int {
        queue.count
    }

    /// True iff `stop()` has been called on this worker.
    public func isStopped() -> Bool {
        stopped
    }

    // MARK: - Consumer loop

    private func runLoop() async {
        while !Task.isCancelled, !stopped {
            if let job = takeJob() {
                let result = await engine.recognize(
                    input: job.input,
                    timeoutMs: timeoutMs
                )
                // Invoke completion outside the actor's queue would
                // require a hop; we accept the actor-isolated call
                // because the completion is @Sendable and we want a
                // strict order-of-delivery guarantee (test #1).
                job.completion(result)
            } else {
                await waitForJob()
            }
        }
    }

    private func takeJob() -> Job? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func waitForJob() async {
        if stopped { return }
        await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
            if stopped {
                cc.resume()
                return
            }
            // Single-waiter contract — only the consumer awaits here.
            // A second awaiter would be a programmer bug; trap so
            // tests catch it.
            precondition(
                awaiter == nil,
                "VisionOCRWorker: multiple consumers awaiting — single-consumer invariant violated"
            )
            awaiter = cc
        }
    }

    private struct Job {
        let input: OCREngineInput
        let completion: @Sendable (OCRResult) -> Void
    }
}
