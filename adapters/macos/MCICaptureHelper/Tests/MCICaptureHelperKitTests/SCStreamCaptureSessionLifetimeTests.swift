// SPDX-License-Identifier: TBD-private
//
// SCStreamCaptureSessionLifetimeTests — headless regression coverage
// for SCSTREAM-LIVE-001.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ THE BUG, IN ONE SENTENCE                                          │
// │                                                                  │
// │ `SCStream` per Apple convention holds its `SCStreamDelegate` and │
// │ registered `SCStreamOutput` references WEAKLY. The prior         │
// │ `main.swift` declared `captureSession` as a local inside an `if` │
// │ block and kicked `start()` via `Task.detached`. Once the         │
// │ detached closure finished, the only strong reference dropped     │
// │ and `SCStreamCaptureSession` deallocated — `SCStream`'s weak     │
// │ delegate/output refs went nil and the OS callback had nowhere    │
// │ to land. Observable: `startCapture` returned silently, zero      │
// │ sample buffers were delivered, zero `didStopWithError` fired,    │
// │ helper heartbeats kept flowing.                                  │
// └──────────────────────────────────────────────────────────────────┘
//
// These tests DO NOT touch SCStream / SCShareableContent / IOSurface
// — those are `// UNVERIFIED — needs live macOS`. They exercise the
// pure ARC contract that the fix in main.swift depends on:
//
//   1. testSessionDeallocsWhenStrongOwnerDrops — bare-ARC sanity:
//      with no strong owner, `SCStreamCaptureSession` is reachable
//      only through a `weak` and therefore deallocates immediately.
//      Establishes the baseline; if THIS fails the language is broken.
//
//   2. testDetachedTaskClosureDoesNotKeepSessionAlivePastCompletion —
//      the REGRESSION CASE. Reproduces the bug: when the ONLY strong
//      reference to a session is captured by a `Task.detached`
//      closure body, the session deallocates as soon as the task
//      completes. This is the exact pattern that was in main.swift
//      pre-fix; the test must FAIL to deallocate (i.e. PASS the
//      assertion that weak became nil) on current main.swift would
//      only be a regression if main.swift starts depending on
//      detached-task-only retention again. Tests the failure mode
//      explicitly so a future refactor cannot reintroduce it
//      silently.
//
//   3. testTopLevelStrongRefSurvivesDetachedTaskCompletion — the FIX
//      CASE. Mirrors the new main.swift binding pattern: an external
//      strong reference (analogous to the top-level
//      `let captureSession: SCStreamCaptureSession?` binding) keeps
//      the session alive across detached-task completion. Drop the
//      strong ref → weak goes nil. Proves the fix's mechanism is
//      what it claims to be.
//
// Together (2) + (3) document the contract: detached-task closure
// retention is NOT process-lifetime retention; only a top-level
// (or otherwise long-lived) strong reference is. main.swift now
// follows the (3) pattern.

import XCTest

@testable import MCICaptureHelperKit

/// Minimal OS-free stub of every `SCStreamCaptureSession.init`
/// collaborator. None of these touch ScreenCaptureKit. Construction
/// of the session is therefore safe in a headless test.
private enum LifetimeFixtures {
    private struct NoSEI: SecureEventInputProbe {
        func isSecureEventInputEnabled() -> Bool { false }
    }
    private struct AXNonSecure: AXSecureSubroleProbe {
        func focusedHasSecureSubrole() -> Bool? { false }
    }
    private struct NoApps: DenylistProbe {
        func appIsDenied(bundleId _: String) -> Bool { false }
        func urlIsDenied(_: String) -> Bool { false }
        func windowTitleIsDenied(_: String) -> Bool { false }
    }
    private struct NoBlack: BlackedRegionProbe {
        func hasBlackedRegion() -> Bool { false }
    }
    private struct NoopEncoder: FrameEncoder {
        func encodeAllowedFrame(
            input _: EncoderInput?,
            seq _: UInt64,
            context _: WorkflowContext
        ) async throws {}
    }
    private struct NoopSink: FrameSink {
        func write(_: Data) async throws {}
    }

    /// Build a session with all OS-free collaborators. Does NOT call
    /// `start()` — the test ARC contract is independent of whether
    /// a real screen is available.
    static func makeSession() -> SCStreamCaptureSession {
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: NoApps(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: []
        )
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: NoopEncoder(),
            sink: NoopSink()
        )
        return SCStreamCaptureSession(
            pipeline: pipeline,
            denylist: Denylist(entries: [])
        )
    }

    /// Stub emitter that records calls but does no real work.
    private struct StubOCREmitter: OCRPostAllowEmitter {
        func processAfterAllow(tsUs _: UInt64, context _: WorkflowContext, input _: OCREngineInput) async {}
    }

    /// Build a session WITH an OCR emitter wired — the P3.6.7 pattern.
    static func makeSessionWithOCREmitter() -> SCStreamCaptureSession {
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: NoApps(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: []
        )
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: NoopEncoder(),
            sink: NoopSink()
        )
        return SCStreamCaptureSession(
            pipeline: pipeline,
            denylist: Denylist(entries: []),
            ocrPostAllowEmitter: StubOCREmitter()
        )
    }
}

final class SCStreamCaptureSessionLifetimeTests: XCTestCase {
    /// (1) Bare-ARC sanity. If a constructed session has no strong
    /// owner, the `weak` reference is nil. Baseline.
    func testSessionDeallocsWhenStrongOwnerDrops() {
        // The session's only strong reference lives in this nested
        // helper's stack frame; on return it is released. A nested
        // function (not a closure) keeps the scope explicit and
        // works in both sync and async test contexts.
        weak var weakSession: SCStreamCaptureSession?
        func scope() {
            let s = LifetimeFixtures.makeSession()
            weakSession = s
            XCTAssertNotNil(
                weakSession,
                "weak ref must observe the session while the strong local is alive"
            )
            _ = s
        }
        scope()
        XCTAssertNil(
            weakSession,
            "with no strong owner, `SCStreamCaptureSession` must deallocate — bare ARC contract"
        )
    }

    /// (2) THE REGRESSION CASE. Reproduces SCSTREAM-LIVE-001 exactly:
    /// the session's only strong reference is the one captured by a
    /// `Task.detached` closure body. After the task completes, the
    /// closure releases its captures; with no other strong owner the
    /// session deallocates.
    ///
    /// If a future refactor reintroduces this pattern in main.swift
    /// the live SCStream callback will go silent again — the assertion
    /// here documents the contract so that pattern's failure mode is
    /// pinned to a unit test rather than rediscovered on a real Mac.
    func testDetachedTaskClosureDoesNotKeepSessionAlivePastCompletion() async {
        weak var weakSession: SCStreamCaptureSession?

        // Build the session inside a nested non-async helper so the
        // local `s` lives only in that frame; the returned `Task`
        // captures `s` and is the ONLY remaining strong reference.
        // This is the exact lifetime shape that broke SCSTREAM-LIVE-001
        // pre-fix: `Task.detached { try await session.start() }` with
        // no external retention.
        func launchDetachedOnlyOwnership() -> Task<Void, Never> {
            let s = LifetimeFixtures.makeSession()
            weakSession = s
            return Task.detached {
                // Mirror `start()` returning after the OS-side stream
                // came up. The closure holds `s` for exactly the body
                // duration.
                _ = s
                return ()
            }
        }

        let task = launchDetachedOnlyOwnership()
        await task.value

        // Give ARC one runloop tick — the closure capture is released
        // by task completion.
        await Task.yield()

        XCTAssertNil(
            weakSession,
            """
            Regression: a session whose only strong reference is held \
            by a `Task.detached` closure body MUST deallocate once \
            the task completes. This is SCSTREAM-LIVE-001 — re-landing \
            this pattern in main.swift will make the live SCStream \
            callback go silent. See \
            docs/audit/2026-05-19-step1-live-scstream.md.
            """
        )
    }

    /// (3) THE FIX CASE. Mirrors the new main.swift pattern: an
    /// external (process-lifetime) strong reference is held alongside
    /// the detached task. After the task completes, the session is
    /// still alive because the external strong ref retains it. Only
    /// when that ref drops does the session deallocate.
    ///
    /// This is the contract main.swift now relies on:
    /// `let captureSession: SCStreamCaptureSession?` at top-level
    /// scope holds the session until process exit, so SCStream's
    /// weak delegate/output refs to `self` stay live.
    func testTopLevelStrongRefSurvivesDetachedTaskCompletion() async {
        weak var weakSession: SCStreamCaptureSession?
        var strongOwner: SCStreamCaptureSession? = LifetimeFixtures.makeSession()
        weakSession = strongOwner

        // Fire-and-await a detached task that also captures the
        // session for its body. After it completes, the closure's
        // capture is released BUT `strongOwner` still holds the
        // session.
        let task = Task.detached { [s = strongOwner!] in
            _ = s
            return ()
        }
        await task.value
        await Task.yield()

        XCTAssertNotNil(
            weakSession,
            """
            Fix contract: while a top-level / process-lifetime strong \
            reference is alive, the session MUST survive detached-task \
            completion. main.swift relies on this to keep SCStream's \
            weak delegate/output refs live.
            """
        )

        // Drop the external strong ref — now there is no owner, the
        // session must deallocate. Confirms the previous assertion
        // observed the right invariant (the session was alive only
        // because of `strongOwner`, not some hidden retain).
        strongOwner = nil
        await Task.yield()

        XCTAssertNil(
            weakSession,
            "after the external strong ref is dropped, the session must deallocate"
        )
    }

    /// (4) One-shot first-sample log slot. The SCStreamOutput callback
    /// emits a single content-free stderr breadcrumb the first time it
    /// is invoked with a screen sample, then never again — proving
    /// SCSTREAM-LIVE-001 is closed on a real-Mac re-verify without a
    /// wire schema bump. This tests the `claimFirstSampleLogSlot()`
    /// gate directly: first call → true, every subsequent call →
    /// false, including under concurrent contention.
    func testFirstSampleLogSlotIsClaimedExactlyOnce() {
        let session = LifetimeFixtures.makeSession()
        XCTAssertTrue(
            session.claimFirstSampleLogSlot(),
            "first call must claim the slot"
        )
        XCTAssertFalse(
            session.claimFirstSampleLogSlot(),
            "second call must NOT claim the slot — one-shot contract"
        )
        XCTAssertFalse(
            session.claimFirstSampleLogSlot(),
            "subsequent calls must remain false — steady state is locked-read"
        )
    }

    /// (5) One-shot under concurrent contention. The SCStreamOutput
    /// callback is on the `sampleQueue` (a real serial dispatch queue
    /// in production, so a single thread races itself by frame); but
    /// the lock is the contract — confirm under parallel callers that
    /// exactly one observes `true`.
    func testFirstSampleLogSlotIsThreadSafeOneShot() {
        let session = LifetimeFixtures.makeSession()
        let iterations = 256
        let trueCount = NSLock()
        var trueObservations = 0
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            if session.claimFirstSampleLogSlot() {
                trueCount.lock()
                trueObservations += 1
                trueCount.unlock()
            }
        }
        XCTAssertEqual(
            trueObservations, 1,
            "exactly one caller across \(iterations) concurrent invocations must observe true"
        )
    }
}

// MARK: - P3.6.7 OCR emitter wiring test

/// Proves the OCR emitter wire is connected when constructed with
/// the same pattern main.swift now uses (P3.6.7 fix). The prior
/// construction omitted `ocrPostAllowEmitter:`, defaulting it to
/// `nil` — the `if let emitter` guard in the SCStream callback
/// evaluated false on every frame and no OCREvent ever reached the wire.
final class SCStreamCaptureSessionOCRWiringTests: XCTestCase {
    /// Session constructed WITHOUT `ocrPostAllowEmitter` — the pre-fix
    /// default. The accessor MUST return nil.
    func testSessionWithoutEmitterHasNilOCREmitter() {
        let session = LifetimeFixtures.makeSession()
        XCTAssertNil(
            session.ocrPostAllowEmitterForTest,
            "pre-fix default construction must have nil ocrPostAllowEmitter"
        )
    }

    /// Session constructed WITH `ocrPostAllowEmitter` — the P3.6.7
    /// fix pattern. The accessor MUST return non-nil.
    func testSessionWithEmitterHasNonNilOCREmitter() {
        let session = LifetimeFixtures.makeSessionWithOCREmitter()
        XCTAssertNotNil(
            session.ocrPostAllowEmitterForTest,
            "P3.6.7 construction must wire a non-nil ocrPostAllowEmitter"
        )
    }
}
