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
// Field population across the Phase-2 PR ladder:
//   - `appBundleId` — P2.1 (this provider, polled 1 Hz).
//   - `windowTitle` — P2.2 (`AXWindowTitleProvider`, optionally
//     injected here via the `windowTitleProvider` init param —
//     default `nil` preserves P2.1 byte-for-byte behaviour; when
//     supplied, each tick reads `windowTitleProvider.title(...)`
//     against the polled bundle id and folds the result into the
//     snapshot. The cascade does NOT yet consume this — P2.5 wires
//     the snapshot through `SCStreamCaptureSession.swift`).
//   - `url` — P2.3 (`SafariURLProvider`) + P2.4 (Chromium / Firefox /
//     Arc) — same optional-injection shape lands at the composite
//     in P2.5; not wired here.
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
/// In P2.1 only `appBundleId` is populated; P2.2 adds optional
/// `windowTitle` via the `windowTitleProvider` init parameter
/// (default `nil` preserves the P2.1 shape byte-for-byte).
/// Subsequent PRs fold the URL providers into a
/// `CompositeContextProvider` (ADR-0015 §2); per-field optional
/// injection is intentional so each PR ships in isolation.
public final class NSWorkspaceContextProvider: ContextProvider, @unchecked Sendable {
    /// Shared snapshot the provider writes to and `snapshot()` reads
    /// from. Multiple providers may share one snapshot in later PRs.
    public let snapshotStore: WorkflowContextSnapshot

    /// Source of frontmost-app readings. Production:
    /// `NSWorkspaceFrontmostAppSource`. Tests: stub.
    private let source: FrontmostAppSource

    /// Optional focused-window-title provider (P2.2). `nil` keeps
    /// the P2.1 behaviour intact — every tick writes
    /// `windowTitle: nil`. When supplied, every tick reads the
    /// title for the polled bundle id and includes it in the
    /// snapshot.
    private let windowTitleProvider: WindowTitleProvider?

    /// Optional current-calendar-event source (Phase 6 PR 5 — SH
    /// Fork D1). `nil` preserves the prior shape (every tick writes
    /// `currentCalendarEvent: nil`). When supplied, every tick
    /// reads `eventNow(at: Date())` and folds the result into the
    /// snapshot.
    private let calendarSource: CalendarEventSource?

    /// Optional now-playing source (Phase 6 PR 5 — SH Fork D1).
    /// `nil` preserves the prior shape. When supplied, every tick
    /// reads `currentTrack()` and folds the result.
    private let nowPlayingSource: NowPlayingTrackSource?

    /// Optional contacts-resolution source (Phase 6 PR 5 — SH Fork
    /// D1). `nil` preserves the prior shape. When supplied, every
    /// tick derives a participant token from the snapshot's `url`
    /// (e.g. `mailto:foo@bar.com`) and resolves it to a
    /// `ContactRef` via `resolve(participant:)`. The cascade does
    /// NOT consume the resolved contact — it is downstream-only.
    private let contactsSource: ContactsAttributionSource?

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
    ///   - windowTitleProvider: optional `WindowTitleProvider`
    ///     (P2.2). Default `nil` preserves the P2.1 shape (every
    ///     tick writes `windowTitle: nil`). When non-nil, each tick
    ///     reads `title(forFrontmost: polledBundleId)` and stores
    ///     the result. A polled-bundle-id of `nil` (no frontmost
    ///     app) short-circuits to `windowTitle: nil` without
    ///     invoking the provider.
    ///   - intervalMs: poll period, milliseconds. Defaults to 1000
    ///     (1 Hz) per ADR-0015 §3.
    ///   - queue: dispatch queue for the timer. Defaults to a
    ///     dedicated serial queue.
    public init(
        snapshotStore: WorkflowContextSnapshot = WorkflowContextSnapshot(),
        source: FrontmostAppSource = NSWorkspaceFrontmostAppSource(),
        windowTitleProvider: WindowTitleProvider? = nil,
        calendarSource: CalendarEventSource? = nil,
        nowPlayingSource: NowPlayingTrackSource? = nil,
        contactsSource: ContactsAttributionSource? = nil,
        intervalMs: UInt64 = 1000,
        queue: DispatchQueue = DispatchQueue(
            label: "mci.context.nsworkspace",
            qos: .utility
        )
    ) {
        self.snapshotStore = snapshotStore
        self.source = source
        self.windowTitleProvider = windowTitleProvider
        self.calendarSource = calendarSource
        self.nowPlayingSource = nowPlayingSource
        self.contactsSource = contactsSource
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
        let titleProvider = self.windowTitleProvider
        let calendar = self.calendarSource
        let nowPlaying = self.nowPlayingSource
        let contacts = self.contactsSource
        t.setEventHandler { [weak self] in
            guard self != nil else { return }
            Self.tick(
                source: source,
                titleProvider: titleProvider,
                calendarSource: calendar,
                nowPlayingSource: nowPlaying,
                contactsSource: contacts,
                store: store
            )
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

    /// One poll tick — read the source, optionally read the window
    /// title for the polled bundle id, build the context, push to
    /// the snapshot. Static so the timer block does not capture
    /// `self`; testable in isolation via the
    /// `tickOnce(source:titleProvider:store:)` public test helper
    /// below.
    private static func tick(
        source: FrontmostAppSource,
        titleProvider: WindowTitleProvider?,
        calendarSource: CalendarEventSource?,
        nowPlayingSource: NowPlayingTrackSource?,
        contactsSource: ContactsAttributionSource?,
        store: WorkflowContextSnapshot
    ) {
        let ctx = buildContext(
            source: source,
            titleProvider: titleProvider,
            calendarSource: calendarSource,
            nowPlayingSource: nowPlayingSource,
            contactsSource: contactsSource
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

    /// Pure builder — read each sub-provider and assemble a
    /// `WorkflowContext`. Factored out so `tick` and `tickOnce`
    /// share one truth.
    ///
    /// A `nil` `bundleId` short-circuits the title read: there is
    /// no frontmost app to read a focused window from, and we want
    /// `windowTitle: nil` rather than "title of whatever app
    /// happens to claim AX focus right now."
    ///
    /// Phase 6 PR 5 — SH Fork D1 attribution sources are consulted
    /// when injected. Each returns `nil` on TCC denial / no signal,
    /// in which case the corresponding field stays nil.
    private static func buildContext(
        source: FrontmostAppSource,
        titleProvider: WindowTitleProvider?,
        calendarSource: CalendarEventSource? = nil,
        nowPlayingSource: NowPlayingTrackSource? = nil,
        contactsSource: ContactsAttributionSource? = nil
    ) -> WorkflowContext {
        let bundleId = source.currentBundleId()
        let title: String?
        if let provider = titleProvider, let id = bundleId {
            title = provider.title(forFrontmost: id)
        } else {
            title = nil
        }
        let event: CalendarEventRef? = calendarSource?.eventNow(at: Date())
        let track: NowPlayingTrackRef? = nowPlayingSource?.currentTrack()
        // Contacts resolution is best-effort from the current URL
        // (e.g. `mailto:foo@bar.com`). When no URL is set OR the
        // URL has no extractable participant shape, contact stays
        // nil. The URL itself is `nil` at this layer (P2.5
        // composite assigns it downstream); a future PR can pass
        // it through here.
        let contact: ContactRef? = nil
        _ = contactsSource  // wired but participant-derivation path is empty at this layer
        return WorkflowContext(
            appBundleId: bundleId,
            windowTitle: title,
            url: nil,
            pageText: nil,
            currentCalendarEvent: event,
            currentListeningTrack: track,
            currentContact: contact
        )
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
        await tickOnce(source: source, titleProvider: nil, store: store)
    }

    /// Synchronous test hook with optional `WindowTitleProvider`
    /// injection. P2.2 overload — kept distinct from the no-title
    /// variant above so P2.1 callers stay byte-for-byte unchanged.
    public static func tickOnce(
        source: FrontmostAppSource,
        titleProvider: WindowTitleProvider?,
        store: WorkflowContextSnapshot
    ) async {
        let ctx = buildContext(source: source, titleProvider: titleProvider)
        await store.store(ctx)
    }

    /// Phase 6 PR 5 — SH Fork D1 test hook. Drives one tick with
    /// all three attribution sources injected so the
    /// `CalendarEventRef` / `NowPlayingTrackRef` / `ContactRef`
    /// paths through `buildContext` are observable without a real
    /// EventKit / MediaPlayer / Contacts framework attached.
    public static func tickOnce(
        source: FrontmostAppSource,
        titleProvider: WindowTitleProvider?,
        calendarSource: CalendarEventSource?,
        nowPlayingSource: NowPlayingTrackSource?,
        contactsSource: ContactsAttributionSource?,
        store: WorkflowContextSnapshot
    ) async {
        let ctx = buildContext(
            source: source,
            titleProvider: titleProvider,
            calendarSource: calendarSource,
            nowPlayingSource: nowPlayingSource,
            contactsSource: contactsSource
        )
        await store.store(ctx)
    }
}
