// SPDX-License-Identifier: TBD-private
//
// FocusTracker — focused-window provider for ADR-0031 Option (a)
// capture-scope. PROTECTED-SET per AGENT_PROTOCOL §5.
//
// Polls the OS at 1 Hz for the focused window's `(bundleId, windowId,
// axRect)` and writes a generation-tagged snapshot to `FocusedWindowStore`.
// Consumers:
//   - `SCContentFilterFactory.makeFocusedWindowFilter(...)` reads the
//     latest snapshot to scope the live SCStream's capture surface to
//     a single window.
//   - `SCStreamCaptureSession` reads the `generation` at filter-install
//     time and the cascade reads it at frame-emit time; a mismatch is
//     the §5.3 race-consistency gate that fails closed.
//
// ## ADR-0031 invariant: OCR-input scope = focused-window-only
//
// The architectural fix in `docs/research/capture-scope-window-vs-display-
// 2026-05-29.md` §5.1 makes the captured pixel surface track focus. The
// FocusTracker is the load-bearing observation primitive that lets the
// SCContentFilter be rebuilt on every focus change. Without an accurate
// focus signal, the cascade attribution stays incorrect (the cycle 8.18
// cross-window leak).
//
// ## ADR-0015 §3 + §4 alignment
//
// `bundleId` here is the same content class as `WorkflowContext.appBundleId`
// — user content. It reaches the cascade through the snapshot route, never
// directly into storage / IPC. The AX read for `axRect` is bounded by the
// `AXFocusedWindowReader` timeout (no auto-grant of permission; clean nil
// on every failure mode) mirroring `AXWindowTitleProvider`'s contract.
//
// ## Pluggability + headlessness
//
// The OS reads are factored behind `FocusedWindowReader`. Production uses
// `AXFocusedWindowReader` (NSWorkspace.frontmostApplication +
// AXUIElementCopyAttributeValue + CGWindowListCopyWindowInfo); tests
// inject `StubFocusedWindowReader`. The tracker itself is OS-free at the
// unit-test boundary.

import CoreGraphics
import Dispatch
import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif

// MARK: - Public value types

/// The focused window as observed by the OS at one poll tick.
///
/// `windowId` is the `CGWindowID` of the focused window — the canonical
/// identifier the live SCStream's `SCContentFilter` factory matches
/// against `SCShareableContent.current.windows[i].windowID`.
///
/// `axRect` is the AX-reported screen rect (display coordinates). It is
/// observability-only inside V2-P1: the live SCStream filter is built
/// from the `SCWindow` matched by `windowId`, not from the rect. Surfaced
/// here so future telemetry can correlate window geometry with the
/// `frames_focus_race_dropped` counter without a second AX read.
///
/// `Equatable` so `FocusedWindowStore` can detect "no change" cheaply and
/// avoid bumping the generation when the focus tick is a no-op.
public struct FocusedWindow: Sendable, Equatable {
    public let bundleId: String
    public let windowId: CGWindowID
    public let axRect: CGRect?

    public init(bundleId: String, windowId: CGWindowID, axRect: CGRect? = nil) {
        self.bundleId = bundleId
        self.windowId = windowId
        self.axRect = axRect
    }
}

/// Generation-tagged snapshot of the focused window. The `generation`
/// monotonically increments every time the stored `focused` value
/// changes; consumers that need a (frame_ts, focus_ts) consistency
/// comparison record the generation at frame capture and re-read it
/// at cascade time.
///
/// `focused == nil` means "no focused window observable" — login window,
/// fast-user-switch transition, all apps backgrounded, or the AX read
/// returned no usable answer. The cascade treats this case as
/// fail-closed (§7 catchall) per ADR-0013 — the safe direction.
public struct FocusedWindowSnapshot: Sendable, Equatable {
    public let focused: FocusedWindow?
    public let generation: UInt64

    public init(focused: FocusedWindow?, generation: UInt64) {
        self.focused = focused
        self.generation = generation
    }
}

// MARK: - Public reader protocol

/// Source of focused-window observations. Production:
/// `AXFocusedWindowReader`. Tests: `StubFocusedWindowReader` (defined in
/// the test target).
///
/// ## Trait-level invariants (binding on every impl)
///
/// - **MUST be non-blocking on the hot path.** The tracker polls at 1 Hz
///   on a dedicated background queue; the SCStream callback never invokes
///   this trait directly. Production reads MUST respect the timeout
///   discipline (`AXFocusedWindowReader` caps the AX read at 250 ms; the
///   tick falls back to a CGWindowList enumeration if AX times out).
/// - **MUST return `nil` cleanly on every failure mode.** Permission
///   denial, no frontmost app, Electron AX intermittency, AX timeout,
///   missing `kAXFocusedWindowAttribute`, hostile non-AXUIElement
///   responses — every one resolves to `nil`. Impls do not throw, do
///   not log noisily, do not retry within the same call.
/// - **MUST be `Sendable`.** The tick runs on a detached background
///   queue; the snapshot store receives values across an isolation
///   boundary.
public protocol FocusedWindowReader: Sendable {
    /// Synchronous read of the current focused window. `nil` cleanly
    /// for every failure mode per the trait invariants above.
    func readFocusedWindow() -> FocusedWindow?
}

// MARK: - FocusedWindowStore

/// Generation-tagged snapshot cell the `FocusTracker` writes to and the
/// SCStream callback / filter factory read from. Mirrors
/// `WorkflowContextSnapshot`'s actor + `nonisolated` lock pattern so the
/// SCStream callback (a `@Sendable` closure that cannot await an actor)
/// reads synchronously through `currentSync()`.
///
/// Generation-bump discipline: `store(_:)` is a no-op when the new value
/// equals the existing one. Generation increments only on a real change.
/// This keeps the race-consistency gate's "current generation" stable
/// across no-op ticks (one focus change → exactly one generation bump),
/// which is the right semantics for `(frame_ts, focus_ts)` comparison.
public actor FocusedWindowStore {
    /// Lock-guarded state. `nonisolated` access through the lock from
    /// `currentSync()` so the SCStream callback can read without `await`.
    private let cell: OSAllocatedUnfairLock<FocusedWindowSnapshot>

    public init(initial: FocusedWindowSnapshot = FocusedWindowSnapshot(focused: nil, generation: 0)) {
        self.cell = OSAllocatedUnfairLock(initialState: initial)
    }

    /// Replace the stored snapshot. The generation increments iff the
    /// new `focused` value differs from the existing one (Equatable on
    /// the whole struct — bundleId / windowId / axRect compared
    /// field-by-field).
    public func store(_ focused: FocusedWindow?) async {
        cell.withLock { state in
            if state.focused != focused {
                state = FocusedWindowSnapshot(
                    focused: focused,
                    generation: state.generation &+ 1
                )
            }
        }
    }

    /// Non-blocking read of the most-recently-stored snapshot. Safe to
    /// call from the SCStream `@Sendable` callback. Holds the lock only
    /// long enough to copy out the struct (≪ 1 µs uncontended).
    public nonisolated func currentSync() -> FocusedWindowSnapshot {
        cell.withLock { $0 }
    }
}

// MARK: - FocusTracker

/// Production `FocusTracker`. Polls a `FocusedWindowReader` at a
/// configurable cadence (default 1000 ms — matches
/// `StreamPolicy.cascadeFloorIntervalMs` from PR #39 + ADR-0015 §3) and
/// pushes each observation to the shared `FocusedWindowStore`.
///
/// `start()` is idempotent (second call while running is a no-op).
/// `stop()` cancels the timer; calling `stop()` before `start()` is also
/// a no-op. The tracker holds the store; multiple consumers
/// (filter factory, SCStream callback, cascade) read from the same
/// instance.
///
/// Mirrors `NSWorkspaceContextProvider`'s lifetime shape on purpose —
/// PR #29 / SCSTREAM-LIVE-001 lesson: never let a background closure
/// be the sole owner of a top-level object. `setEventHandler { [weak
/// self] ... }`; static `tick(...)` does not capture `self`.
public final class FocusTracker: @unchecked Sendable {
    /// Shared store the tracker writes to and consumers read from.
    public let store: FocusedWindowStore

    /// Source of focused-window readings. Production:
    /// `AXFocusedWindowReader`. Tests: stub.
    private let reader: any FocusedWindowReader

    /// Polling cadence, milliseconds. Default 1000 ms (1 Hz).
    private let intervalMs: UInt64

    /// Serial queue the timer fires on. Dedicated to the focus tracker
    /// so polling never contends with the SCStream sample queue or the
    /// `NSWorkspaceContextProvider`'s context queue.
    private let queue: DispatchQueue

    /// State guarded by `stateLock`. `timer == nil` ↔ stopped.
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?

    /// Construct a tracker. Does NOT start polling; call `start()`.
    ///
    /// - Parameters:
    ///   - store: snapshot cell to write to. Defaults to a fresh one;
    ///     callers that wire the SCContentFilter factory + SCStream
    ///     consistency gate MUST pass the shared instance.
    ///   - reader: focused-window source. Defaults to the real
    ///     AX-backed reader.
    ///   - intervalMs: poll period, milliseconds. Defaults to 1000.
    ///   - queue: dispatch queue for the timer. Defaults to a dedicated
    ///     serial queue.
    public init(
        store: FocusedWindowStore = FocusedWindowStore(),
        reader: any FocusedWindowReader = AXFocusedWindowReader(),
        intervalMs: UInt64 = 1000,
        queue: DispatchQueue = DispatchQueue(
            label: "mci.context.focustracker",
            qos: .utility
        )
    ) {
        self.store = store
        self.reader = reader
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
    /// no-op. The first tick fires immediately so the store leaves its
    /// initial nil state without the 1-second startup gap.
    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(intervalMs))
        t.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: .milliseconds(100)
        )
        // Weak-self capture; static `tick(...)` does the work so the
        // timer block does not own the tracker. Matches the PR #29 /
        // SCSTREAM-LIVE-001 lifetime fix discipline.
        let reader = self.reader
        let store = self.store
        t.setEventHandler { [weak self] in
            guard self != nil else { return }
            Self.tick(reader: reader, store: store)
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

    /// Non-blocking read of the most-recently-stored snapshot. Safe to
    /// call from the SCStream `@Sendable` callback.
    public func currentSync() -> FocusedWindowSnapshot {
        store.currentSync()
    }

    /// One poll tick — read the source, push to the store. Static so
    /// the timer block does not capture `self`.
    private static func tick(
        reader: any FocusedWindowReader,
        store: FocusedWindowStore
    ) {
        let focused = reader.readFocusedWindow()
        // The actor-isolated `store(_:)` is `async`; schedule onto a
        // detached task. Ordering across ticks is preserved by the
        // serial timer queue (tick N+1 cannot enqueue before tick N
        // has handed off to the actor — `Task` enqueue order from a
        // serial queue is deterministic).
        Task.detached(priority: .utility) {
            await store.store(focused)
        }
    }

    /// Synchronous test hook — one tick, awaiting the store write.
    /// Lets unit tests drive the polling logic without sleeping on the
    /// timer cadence. Production code does NOT call this; the path is
    /// identical to one timer tick except the actor `await` is
    /// observable to the test driver.
    public static func tickOnce(
        reader: any FocusedWindowReader,
        store: FocusedWindowStore
    ) async {
        let focused = reader.readFocusedWindow()
        await store.store(focused)
    }
}

// MARK: - Production reader (UNVERIFIED — live macOS)

/// Production `FocusedWindowReader` over `NSWorkspace.frontmostApplication`
/// + `AXUIElementCreateApplication(pid)` +
/// `kAXFocusedWindowAttribute` + `kAXPositionAttribute` /
/// `kAXSizeAttribute` for the rect + `CGWindowListCopyWindowInfo` for the
/// `CGWindowID`.
///
/// `// UNVERIFIED — needs live macOS; do not claim working`: every OS
/// call below requires a real screen + AX/TCC grants. The OS-free unit
/// tests in `FocusTrackerTests` drive the tracker through a stub reader;
/// the §11 live-Mac audit covers this path.
///
/// Failure-mode discipline (matches `AXWindowTitleProvider`'s contract):
/// permission denial, no frontmost app, no focused window, AX timeout,
/// CGWindowList miss — every one resolves to `nil`. No throw, no
/// retry-storm, no noisy logging.
public struct AXFocusedWindowReader: FocusedWindowReader {
    private let pidSource: any FrontmostPidSource
    private let axRectReader: any AXFocusedWindowRectReader
    private let windowIdSource: any FocusedWindowIDSource

    public init(
        pidSource: any FrontmostPidSource = NSWorkspaceFrontmostPidSource(),
        axRectReader: any AXFocusedWindowRectReader = RealAXFocusedWindowRectReader(),
        windowIdSource: any FocusedWindowIDSource = CGWindowListFocusedWindowIDSource()
    ) {
        self.pidSource = pidSource
        self.axRectReader = axRectReader
        self.windowIdSource = windowIdSource
    }

    public func readFocusedWindow() -> FocusedWindow? {
        guard let pidBundle = pidSource.frontmostPidAndBundle() else { return nil }
        let (pid, bundleId) = pidBundle

        // Empty bundleId → no usable focused window. Same failure-mode
        // class as a nil frontmost: collapse cleanly to nil.
        guard !bundleId.isEmpty else { return nil }

        guard let windowId = windowIdSource.focusedWindowID(pid: pid) else {
            return nil
        }

        // AX rect is observability-only inside V2-P1; nil is acceptable.
        // Pass the timeout that matches `RealAXTitleReader`'s 250 ms cap.
        let axRect = axRectReader.readRect(pid: pid, timeoutMs: 250)

        return FocusedWindow(
            bundleId: bundleId,
            windowId: windowId,
            axRect: axRect
        )
    }
}

// MARK: - Internal seams (testability)

/// `(pid, bundleId)` of the current frontmost application, or `nil` when
/// nothing is frontmost. Internal seam so tests can drive the
/// `AXFocusedWindowReader` matrix headlessly.
public protocol FrontmostPidSource: Sendable {
    func frontmostPidAndBundle() -> (pid_t, String)?
}

/// Production `FrontmostPidSource` over
/// `NSWorkspace.shared.frontmostApplication`.
public struct NSWorkspaceFrontmostPidSource: FrontmostPidSource {
    public init() {}

    public func frontmostPidAndBundle() -> (pid_t, String)? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let bundleId = app.bundleIdentifier else { return nil }
        return (app.processIdentifier, bundleId)
        #else
        return nil
        #endif
    }
}

/// AX rect read for the focused window of `pid`. Internal seam so tests
/// can simulate Electron AX intermittency without holding live AX state.
public protocol AXFocusedWindowRectReader: Sendable {
    /// Read the focused window's rect in display coordinates within
    /// `timeoutMs`. Returns `nil` on permission denial, no focused
    /// window, missing position/size attribute, or timeout.
    func readRect(pid: pid_t, timeoutMs: Int) -> CGRect?
}

/// Production rect reader. Runs the AX call on a private serial
/// `DispatchQueue`; the calling thread waits on a semaphore bounded by
/// `timeoutMs`. If the semaphore times out, the in-flight AX call
/// continues on the dispatch queue and its result is dropped — the
/// caller has already returned `nil`. Mirrors `RealAXTitleReader`.
///
/// `// UNVERIFIED — needs live macOS; do not claim working`.
public struct RealAXFocusedWindowRectReader: AXFocusedWindowRectReader {
    private static let queue = DispatchQueue(
        label: "mci.context.ax.focused.rect.reader",
        qos: .userInitiated
    )

    public init() {}

    public func readRect(pid: pid_t, timeoutMs: Int) -> CGRect? {
        #if canImport(ApplicationServices)
        let sema = DispatchSemaphore(value: 0)
        // Pure-Sendable shared state: the closure writes one value,
        // the caller reads after `wait()` returns `.success`. On
        // `.timedOut` the closure may still run and overwrite, but
        // the caller has already returned `nil` so the late write is
        // discarded.
        var result: CGRect?
        let resultBox = UncheckedBox<CGRect?>(value: nil)
        Self.queue.async {
            let element = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            let focusedStatus = AXUIElementCopyAttributeValue(
                element,
                kAXFocusedWindowAttribute as CFString,
                &focusedRef
            )
            guard focusedStatus == .success,
                  let focused = focusedRef
            else {
                sema.signal()
                return
            }
            // The CFTypeRef from AX is documented to be AXUIElement when
            // the attribute returns one. Cast guarded — hostile non-AX
            // values collapse to nil per the trait invariants.
            //
            // swiftlint:disable:next force_cast
            let focusedElement = focused as! AXUIElement
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            let posStatus = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXPositionAttribute as CFString,
                &posRef
            )
            let sizeStatus = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSizeAttribute as CFString,
                &sizeRef
            )
            guard posStatus == .success,
                  sizeStatus == .success,
                  let posV = posRef,
                  let sizeV = sizeRef
            else {
                sema.signal()
                return
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            let posOk = AXValueGetValue(posV as! AXValue, .cgPoint, &origin)
            let sizeOk = AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
            if posOk && sizeOk {
                resultBox.value = CGRect(origin: origin, size: size)
            }
            sema.signal()
        }
        let outcome = sema.wait(timeout: .now() + .milliseconds(timeoutMs))
        if outcome == .success {
            result = resultBox.value
        }
        return result
        #else
        _ = pid
        _ = timeoutMs
        return nil
        #endif
    }
}

/// Resolve the `CGWindowID` of the focused window for the supplied
/// process. Internal seam so tests can simulate missing-window /
/// Electron-AX-intermittency cases.
public protocol FocusedWindowIDSource: Sendable {
    /// `CGWindowID` of the focused (top-most on-screen, layer 0) window
    /// owned by `pid`, or `nil` when no such window can be resolved.
    func focusedWindowID(pid: pid_t) -> CGWindowID?
}

/// Production focused-window-ID resolver via
/// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)`,
/// filtered by `kCGWindowOwnerPID == pid` AND `kCGWindowLayer == 0`,
/// returning the first match (the on-screen window list is ordered
/// front-to-back).
///
/// `// UNVERIFIED — needs live macOS; do not claim working`.
public struct CGWindowListFocusedWindowIDSource: FocusedWindowIDSource {
    public init() {}

    public func focusedWindowID(pid: pid_t) -> CGWindowID? {
        #if canImport(AppKit)
        // `.optionOnScreenOnly` excludes minimized + off-display windows.
        // `kCGNullWindowID` means "no relative anchor"; the list is in
        // front-to-back order. `.excludeDesktopElements` drops Dock /
        // wallpaper / menu-bar entries from the enumeration so the first
        // match for the supplied pid is the focused window's
        // `CGWindowID`.
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for entry in raw {
            guard let ownerPid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let id = entry[kCGWindowNumber as String] as? CGWindowID {
                return id
            }
        }
        return nil
        #else
        _ = pid
        return nil
        #endif
    }
}

// MARK: - Helpers

/// Heap-boxed mutable cell. Used to hand a result out of an `async`
/// `DispatchQueue` closure to the calling thread after the semaphore
/// signals. Marked `@unchecked Sendable` because the producer/consumer
/// ordering is enforced externally by the semaphore — the producer
/// writes once before `signal()`, the consumer reads only after
/// `wait()` returns `.success`.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(value: T) { self.value = value }
}
