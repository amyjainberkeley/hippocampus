// SPDX-License-Identifier: TBD-private
//
// NSWorkspaceContextProvider — production `ContextProvider` impl.
// Polls `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`
// at 1 Hz on a dedicated `DispatchSourceTimer` and pushes the result
// to the in-process `WorkflowContextSnapshot`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Cites ADR-0015 §1.1
// (`appBundleId` extraction design + alternatives-rejected),
// §3 (1 Hz cadence + bounded staleness — same period as the
// cascade-floor heartbeat from PR #39), §4 (privacy invariants —
// `appBundleId` is user content, never reaches storage ahead of a
// cascade decision; for P2.1 it never reaches storage at all because
// the provider is not yet wired into `SCStreamCaptureSession.swift`
// — that's PR P2.5).
//
// `windowTitle`, `url`, `pageText` stay `nil` in P2.1:
//   - `windowTitle` — P2.2 (`AXWindowTitleProvider`, reuses the
//     PR #38 AX path).
//   - `url` — P2.3 (`SafariURLProvider`) + P2.4 (Chromium / Firefox /
//     Arc).
//   - `pageText` — Phase 3 (Vision OCR) per ADR-0015 §1.4.
//
// The `NSWorkspace` read is factored behind a small internal
// `FrontmostAppSource` protocol so the polling cadence is testable
// without a real `NSWorkspace` (mirrors the
// `SecureEventInputProbe` / `AXSecureSubroleProbe` test-double
// pattern from PRs #36/#38).

import Dispatch
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Source of the current frontmost-app bundle identifier. Production
/// reads `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`;
/// tests inject a deterministic stub.
public protocol FrontmostAppSource: Sendable {
    /// Current frontmost application's bundle identifier, or `nil`
    /// when nothing is frontmost (rare — login window / fast-user-
    /// switch transitions / Dock-only state).
    func currentBundleId() -> String?
}

/// Default production `FrontmostAppSource` over
/// `NSWorkspace.shared.frontmostApplication`.
///
/// AppKit import is guarded by `#if canImport(AppKit)` so the target
/// still compiles in headless / Linux CI contexts; the
/// non-AppKit fallback returns `nil`, which the cascade treats as
/// "unknown app" → fail-closed under §7 (the safe direction).
public struct NSWorkspaceFrontmostAppSource: FrontmostAppSource {
    public init() {}

    public func currentBundleId() -> String? {
        #if canImport(AppKit)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #else
        return nil
        #endif
    }
}

/// Production `ContextProvider`. Polls a `FrontmostAppSource` at a
/// configurable cadence (default 1000 ms — matches
/// `StreamPolicy.cascadeFloorIntervalMs` from PR #39 per ADR-0015 §3)
/// and pushes each observation to the shared `WorkflowContextSnapshot`.
///
/// `start()` is idempotent (calling twice is a no-op). `stop()`
/// cancels the timer; calling `stop()` before `start()` is also a
/// no-op. The provider holds the snapshot; multiple providers (P2.2/
/// P2.3/P2.4 will wire additional pollers) share the same snapshot
/// instance — actor isolation on `WorkflowContextSnapshot.store(_:)`
/// serializes fan-in.
///
/// For P2.1 only the `appBundleId` field is populated; the provider
/// always writes `WorkflowContext(appBundleId: ..., windowTitle: nil,
/// url: nil, pageText: nil)`. Subsequent PRs fold their per-field
/// providers into a `CompositeContextProvider` (ADR-0015 §2); the
/// in-isolation P2.1 shape is intentional.
public final class NSWorkspaceContextProvider: ContextProvider, @unchecked Sendable {
    /// Shared snapshot the provider writes to and `snapshot()` reads
    /// from. Multiple providers may share one snapshot in later PRs.
    public let snapshotStore: WorkflowContextSnapshot

    /// Source of frontmost-app readings. Production:
    /// `NSWorkspaceFrontmostAppSource`. Tests: stub.
    private let source: FrontmostAppSource

    /// Polling cadence, milliseconds. Default 1000 ms (1 Hz) — see
    /// ADR-0015 §3.
    private let intervalMs: UInt64

    /// Serial queue the timer fires on. Dedicated to the context
    /// provider so polling never contends with the SCStream sample
    /// queue.
    private let queue: DispatchQueue

    /// State guarded by `stateLock`. `timer == nil` ↔ stopped.
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?

    /// Construct a provider. Does NOT start polling; call `start()`.
    ///
    /// - Parameters:
    ///   - snapshotStore: snapshot cell to write to. Defaults to a
    ///     fresh one; callers that wire multiple providers across
    ///     P2.2+ MUST pass the shared instance.
    ///   - source: frontmost-app source. Defaults to the real
    ///     `NSWorkspace` reader.
    ///   - intervalMs: poll period, milliseconds. Defaults to 1000
    ///     (1 Hz) per ADR-0015 §3.
    ///   - queue: dispatch queue for the timer. Defaults to a
    ///     dedicated serial queue.
    public init(
        snapshotStore: WorkflowContextSnapshot = WorkflowContextSnapshot(),
        source: FrontmostAppSource = NSWorkspaceFrontmostAppSource(),
        intervalMs: UInt64 = 1000,
        queue: DispatchQueue = DispatchQueue(
            label: "mci.context.nsworkspace",
            qos: .utility
        )
    ) {
        self.snapshotStore = snapshotStore
        self.source = source
        self.intervalMs = intervalMs
        self.queue = queue
    }

    deinit {
        // Best-effort timer release on dealloc. Idempotent with
        // `stop()`. Safe to touch the lock here (deinit runs on the
        // releasing thread, no concurrent users by definition).
        timer?.cancel()
        timer = nil
    }

    /// Begin polling. Idempotent — second call while running is a
    /// no-op.
    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(intervalMs))
        // Start immediately so the snapshot leaves the all-nil
        // initial state on the first tick; thereafter every
        // `intervalMs`. Leeway 100 ms (10% of the period) — same
        // shape as `DispatchSourceTimer` defaults; lets the system
        // coalesce ticks under load and keeps idle power down.
        t.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: .milliseconds(100)
        )
        // Capture `self` weakly so the timer block does not own the
        // provider (matches the SCStream-callback lifetime lessons
        // from PR #29 / SCSTREAM-LIVE-001 — never let a background
        // closure be the sole owner of a top-level object).
        let source = self.source
        let store = self.snapshotStore
        t.setEventHandler { [weak self] in
            guard self != nil else { return }
            Self.tick(source: source, store: store)
        }
        timer = t
        t.resume()
    }

    /// Stop polling. Idempotent — second call (or call before
    /// `start()`) is a no-op.
    public func stop() {
        stateLock.lock()
        let t = timer
        timer = nil
        stateLock.unlock()
        t?.cancel()
    }

    /// `ContextProvider` conformance — non-blocking hot-path read.
    /// Returns the snapshot the most recent timer tick stored, or the
    /// all-nil initial value if no tick has fired yet.
    public func snapshot() -> WorkflowContext {
        snapshotStore.currentSync()
    }

    /// One poll tick — read the source, build the context, push to
    /// the snapshot. Static so the timer block does not capture
    /// `self`; testable in isolation via the `tickOnce(source:store:)`
    /// public test helper below.
    private static func tick(
        source: FrontmostAppSource,
        store: WorkflowContextSnapshot
    ) {
        let bundleId = source.currentBundleId()
        let ctx = WorkflowContext(
            appBundleId: bundleId,
            windowTitle: nil,
            url: nil,
            pageText: nil
        )
        // The actor-isolated `store(_:)` is `async`; schedule onto a
        // detached task. Ordering across ticks is preserved by the
        // serial timer queue (tick N+1 cannot enqueue before tick N
        // has handed off to the actor — `Task` enqueue order from a
        // serial queue is deterministic).
        Task.detached(priority: .utility) {
            await store.store(ctx)
        }
    }

    /// Synchronous test hook — one tick, awaiting the store write.
    /// Lets unit tests drive the polling logic without sleeping on
    /// the timer cadence. Production code does NOT call this; the
    /// path is identical to one timer tick except the actor `await`
    /// is observable to the test driver.
    public static func tickOnce(
        source: FrontmostAppSource,
        store: WorkflowContextSnapshot
    ) async {
        let bundleId = source.currentBundleId()
        let ctx = WorkflowContext(
            appBundleId: bundleId,
            windowTitle: nil,
            url: nil,
            pageText: nil
        )
        await store.store(ctx)
    }
}
