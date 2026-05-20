// SPDX-License-Identifier: TBD-private
//
// AXWindowTitleProvider — `WindowTitleProvider` impl backed by the
// macOS Accessibility API. ADR-0015 §1.2 + §6 P2.2.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Window titles are user content
// (ADR-0015 §4 invariant 1 — "context-as-content"). The values
// produced by this provider flow into `WorkflowContext.windowTitle`
// only via the in-process `WorkflowContextSnapshot` actor and reach
// the ADR-0013 cascade BEFORE any storage / IPC sink (ADR-0015 §4
// invariant 2 — "cascade-before-storage"). The cascade wiring lives
// in `SCStreamCaptureSession.swift` and is added by ADR-0015 §6 P2.5;
// this PR ships the provider in isolation, exactly the same shape
// P2.1 / P2.3 / P2.4 used.
//
// ## ADR-0015 §4 invariants on this PR
//
//   1. context-as-content — the produced title string is user
//      content; this file reads it only into the return value of
//      `title(forFrontmost:)`. Callers route it through the cascade
//      before any sink (wiring at P2.5, not this PR).
//   2. cascade-before-storage — vacuous this PR (no cascade wiring).
//   3. no auto-grant Apple Events — vacuous (this provider uses AX
//      only, never AppleScript). NOTE: AX permission grant is its own
//      TCC pane (Privacy & Security → Accessibility); the OS dialog
//      firing the first time `AXUIElementCopyAttributeValue` is called
//      on a cross-process target IS the consent UX. The helper does
//      NOT auto-grant: no `tccutil`, no programmatic permission API.
//   4. real `appBundleId` in tombstone — vacuous this PR (cascade
//      wiring at P2.5).
//
// ## Behaviour summary
//
// - bundleId resolves to a running-app pid → read AX. No running app
//   matches the supplied bundleId → return `nil` cleanly (the
//   provider does not handle that case).
// - AX read path on the resolved pid:
//     `AXUIElementCreateApplication(pid)` →
//     `kAXFocusedWindowAttribute` →
//     `kAXTitleAttribute`.
//   Apple ref: <https://developer.apple.com/documentation/applicationservices/axuielement_h>,
//   constants `kAXFocusedWindowAttribute` / `kAXTitleAttribute`.
//   ADR-0015 §1.2 picked this path (vs `CGWindowListCopyWindowInfo`
//   `kCGWindowName` and vs `SCWindow.title`) on minimum-data-collection
//   + focus-correctness grounds.
// - On any AX failure (permission revoked, no focused window, title
//   attribute unsupported, hostile non-AXUIElement CFType,
//   `apiDisabled` / `notImplemented` / `cannotComplete` etc.) → `nil`.
//   Empty-string title also collapses to `nil` (degenerate "window has
//   no title" shape).
// - Bounded execution: 250 ms cap. The read runs on a private serial
//   `DispatchQueue`; the calling thread waits on a semaphore. If the
//   semaphore times out, the in-flight AX call continues on the
//   dispatch queue and its result is dropped — the caller has already
//   returned `nil`. Mirrors `RealAppleScriptRunner`'s shape from P2.3.
//
// ## Why factor behind `AXTitleReader` + `RunningAppPidSource`
//
// The cascade decision matrix needs to be unit-testable headlessly:
//   - (a) no permission → nil
//   - (b) nil focused window → nil
//   - (c) success → string
//   - (d) timeout → nil
//   - (e) bundleId mismatch (no running app) → nil
// Without indirection seams every test path would have to hit live
// AX, which (1) requires the test process to hold the Accessibility
// entitlement and (2) is non-deterministic across CI hosts. Mirrors
// the P2.1 `FrontmostAppSource` + P2.3 `AppleScriptRunner` patterns;
// production wiring uses the real AX-backed reader, tests inject
// stubs.

import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: – Public trait

/// Focused-window title for the frontmost app's bundle id, or `nil`
/// when the AX path could not produce one cleanly.
///
/// Production impl (`AXWindowTitleProvider`) reads
/// `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute`
/// → `kAXTitleAttribute`. Tests inject a stub.
///
/// ## Trait-level invariants (binding on every impl)
///
/// - **MUST be non-blocking on the hot path.** The cascade snapshot
///   actor (ADR-0015 §3) polls at 1 Hz on a dedicated background
///   `Task`; the SCStream callback never invokes this trait
///   directly. Even so, impls must not block the calling thread on
///   the order of seconds — see the bounded-execution clause on the
///   production impl (250 ms cap).
/// - **MUST return `nil` cleanly on every failure mode.** Permission
///   denial (TCC Accessibility pane), no focused window, app not
///   AX-cooperative (Electron / Catalyst intermittencies), AX
///   timeout, unsupported bundle id (no matching running app) —
///   every one of these resolves to `nil`. Impls do not throw, do
///   not log noisily, do not retry within the same call.
/// - **MUST be `Sendable`.** Phase 2 polling runs on a detached
///   background `Task`; the snapshot actor receives the produced
///   value across an isolation boundary.
public protocol WindowTitleProvider: Sendable {
    /// Focused-window title for the supplied frontmost bundle id, or
    /// `nil` when AX could not answer cleanly.
    ///
    /// MUST be non-blocking on the hot path. MUST return `nil`
    /// cleanly (not throw, not block, not retry-storm) on permission
    /// denial / no-focused-window / app-not-AX-cooperative /
    /// unsupported-bundle.
    func title(forFrontmost bundleId: String) -> String?
}

// MARK: – Internal seams (testability)

/// Outcome of one focused-window-title read. The Real and Stub
/// readers both produce this; `AXWindowTitleProvider` consumes it.
///
/// Four distinct outcomes (not just `String?`) so the cascade /
/// telemetry can account for `.timeout` separately from clean
/// `.noTitle` / `.error` if future CRS telemetry needs to (today all
/// three collapse to `nil` at the `WindowTitleProvider` boundary).
internal enum WindowTitleOutcome: Sendable, Equatable {
    /// AX returned a focused window with a non-empty title.
    case success(String)
    /// AX read succeeded but there is no focused window OR the
    /// focused window has no title / an empty title / the title
    /// attribute is unsupported on this window.
    case noTitle
    /// AX read errored (permission revoked, API disabled, invalid
    /// element, hostile non-AXUIElement CFType, `cannotComplete`,
    /// etc.). Single category here so the provider does not need to
    /// disambiguate by error code.
    case error
    /// Execution exceeded the supplied timeout. The underlying AX
    /// call may still be running on the dispatch queue and its
    /// eventual result is discarded.
    case timeout
}

/// Indirection seam in front of the live AX read so tests can drive
/// the `AXWindowTitleProvider` decision matrix headlessly without
/// touching the Accessibility API. Internal: production wiring uses
/// `RealAXTitleReader`; tests inject a stub.
internal protocol AXTitleReader: Sendable {
    /// Read the focused-window title for the AX application at `pid`.
    /// Implementations MUST respect `timeoutMs` (return `.timeout`
    /// rather than blocking the caller indefinitely).
    func read(pid: pid_t, timeoutMs: Int) -> WindowTitleOutcome
}

/// Indirection seam in front of the `bundleId → pid` lookup so tests
/// can simulate "bundleId mismatch" (no running app) without holding
/// `NSRunningApplication` state. Internal: production wiring uses
/// `NSRunningApplicationPidSource`; tests inject a stub.
internal protocol RunningAppPidSource: Sendable {
    /// pid of a running application whose bundle identifier matches
    /// `bundleId`, or `nil` if no such app is currently running.
    func pid(forBundleId bundleId: String) -> pid_t?
}

/// Production `RunningAppPidSource` over `NSRunningApplication`.
///
/// AppKit import is guarded by `#if canImport(AppKit)` so the target
/// still compiles in headless / Linux CI contexts; the non-AppKit
/// fallback returns `nil`, which the provider treats as "no running
/// app for that bundleId" → `nil`.
internal struct NSRunningApplicationPidSource: RunningAppPidSource {
    init() {}

    func pid(forBundleId bundleId: String) -> pid_t? {
        #if canImport(AppKit)
        let matches = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        )
        return matches.first?.processIdentifier
        #else
        _ = bundleId
        return nil
        #endif
    }
}

/// Production runner. Executes the AX read on a private serial
/// `DispatchQueue`; the calling thread waits on a semaphore bounded
/// by `timeoutMs`. If the semaphore times out, the in-flight AX call
/// continues on the dispatch queue and its result is dropped — the
/// caller has already returned `.timeout`. Mirrors P2.3's
/// `RealAppleScriptRunner`.
///
/// AX calls on cross-process targets can block: a non-cooperative
/// app (Electron under load, an unresponsive Catalyst bridge) can
/// stall the AX server long enough to risk the 1 Hz poll cadence.
/// The semaphore cap keeps a stuck call from wedging the poller.
internal struct RealAXTitleReader: AXTitleReader {
    private static let queue = DispatchQueue(
        label: "mci.context.ax.title.reader",
        qos: .utility
    )

    init() {}

    func read(pid: pid_t, timeoutMs: Int) -> WindowTitleOutcome {
        #if canImport(ApplicationServices)
        let sem = DispatchSemaphore(value: 0)
        let box = AXOutcomeBox()
        Self.queue.async {
            box.set(Self.readSync(pid: pid))
            sem.signal()
        }
        let wait = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if wait == .timedOut { return .timeout }
        return box.value ?? .error
        #else
        _ = (pid, timeoutMs)
        return .error
        #endif
    }

    #if canImport(ApplicationServices)
    /// Synchronous AX read (no timeout enforcement). Runs on the
    /// private dispatch queue inside `read(pid:timeoutMs:)`.
    private static func readSync(pid: pid_t) -> WindowTitleOutcome {
        let appRef = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        let wr = AXUIElementCopyAttributeValue(
            appRef,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        switch wr {
        case .success:
            guard let ref = windowRef,
                  CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                // Hostile shim or genuinely-absent focused window.
                return .noTitle
            }
            // swiftlint:disable:next force_cast
            let window = (ref as! AXUIElement)

            var titleRef: CFTypeRef?
            let tr = AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleRef
            )
            switch tr {
            case .success:
                guard let s = titleRef as? String else { return .noTitle }
                return s.isEmpty ? .noTitle : .success(s)
            case .noValue, .attributeUnsupported:
                return .noTitle
            case .apiDisabled, .notImplemented:
                return .error
            default:
                return .error
            }

        case .noValue, .attributeUnsupported:
            // App has no focused window right now (background, hidden,
            // mid-transition). Not an error — just no title to read.
            return .noTitle
        case .apiDisabled, .notImplemented:
            // Accessibility has not been granted to the helper. The
            // agent shell handles the onboarding prompt; the cascade
            // sees `nil` here and treats the frame as "unknown app" →
            // fail-closed under §7.
            return .error
        default:
            return .error
        }
    }
    #endif
}

/// Thread-safe single-shot outcome holder used by
/// `RealAXTitleReader` to hand the AX result across the
/// dispatch-queue / caller boundary. Mirrors P2.3's `OutcomeBox`.
private final class AXOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: WindowTitleOutcome?
    func set(_ v: WindowTitleOutcome) {
        lock.lock(); _value = v; lock.unlock()
    }
    var value: WindowTitleOutcome? {
        lock.lock(); defer { lock.unlock() }; return _value
    }
}

// MARK: – Public impl

/// Focused-window-title provider backed by the macOS Accessibility
/// API. ADR-0015 §1.2 + §6 P2.2.
///
/// Production wiring: `NSRunningApplication`-backed `pidSource` +
/// `RealAXTitleReader` (with 250 ms semaphore-capped execution).
/// Tests inject stubs for both seams.
public final class AXWindowTitleProvider: WindowTitleProvider, @unchecked Sendable {
    /// Bounded AX execution. The AX server can stall on
    /// non-cooperative apps; the 250 ms cap keeps a stuck call from
    /// wedging the 1 Hz `NSWorkspaceContextProvider` poll. Matches
    /// the P2.3 `SafariURLProvider.timeoutMs` value.
    internal static let timeoutMs: Int = 250

    private let pidSource: RunningAppPidSource
    private let reader: AXTitleReader

    /// Production initializer. Wires the real
    /// `NSRunningApplication`-backed pid source + the real AX-backed
    /// reader (with semaphore-capped execution).
    public convenience init() {
        self.init(
            pidSource: NSRunningApplicationPidSource(),
            reader: RealAXTitleReader()
        )
    }

    /// Test initializer. Internal so tests in the same module can
    /// inject a stub pid source + stub reader; production callers
    /// use the convenience init above.
    internal init(
        pidSource: RunningAppPidSource,
        reader: AXTitleReader
    ) {
        self.pidSource = pidSource
        self.reader = reader
    }

    public func title(forFrontmost bundleId: String) -> String? {
        // (e) bundleId mismatch — no running app matches. Return nil
        // cleanly without an AX read. Per the trait contract: the
        // composite (P2.5 wiring) decides which provider's value to
        // use; here we just answer "no" for unknown bundle ids.
        guard let pid = pidSource.pid(forBundleId: bundleId) else {
            return nil
        }
        switch reader.read(pid: pid, timeoutMs: Self.timeoutMs) {
        case .success(let title):
            return title
        case .noTitle, .error, .timeout:
            return nil
        }
    }
}
