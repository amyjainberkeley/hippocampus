// SPDX-License-Identifier: TBD-private
//
// TCCStatusMonitor — cycle 8.45 audit risk #2 (TCC revoked mid-run).
// PROTECTED-SET per AGENT_PROTOCOL §5. Privacy invariant STRENGTHENED,
// never weakened: this file adds NO capability — it only observes the
// existing OS-side TCC verdict for each surface MCI already relies on,
// and lets the capture session pause fast when a permission the user
// previously granted has since been revoked via System Settings.
//
// Signals (all read-only OS probes):
//   - Screen Recording — `CGPreflightScreenCaptureAccess()`
//   - Accessibility    — `AXIsProcessTrusted()`
//   - Full Disk Access — indirect: try to read `~/Library/Safari/
//                        Bookmarks.plist` (a well-known FDA-protected
//                        location). A successful open ⇒ granted; a
//                        POSIX EPERM ⇒ denied; missing-file / other
//                        errors ⇒ unknown (safer than a false-denied).
//   - Automation       — STUBBED for follow-up per mission constraint
//                        (per-target `AEDeterminePermissionToAutomateTarget`
//                        is high-implementation-cost + Apple-Events
//                        prompts add UX cost). Enum case exists so a
//                        future PR can wire it without a breaking
//                        change.
//
// Poll cadence: 0.5 Hz (2 s interval). Cheap: three read-only syscalls
// per tick. Never faster (battery + mission constraint). Runs on a
// `.utility` QoS dispatch queue — off the SCStream sample queue.
//
// Debounce: single-sample transitions are surfaced immediately for
// "granted → denied" (fail-safe: we want to pause capture the moment
// the OS revokes) but require 2 consecutive samples for
// "denied → granted" (fail-safe: don't resume capture on a stale-cache
// false-positive; the user just re-granted so an extra 2 s is fine).
//
// The OS-touching probe implementations are `// UNVERIFIED — needs
// live macOS`. The state machine is unit-tested headlessly via the
// `TCCProbe` seam.
//
// This monitor NEVER bypasses TCC — it can only observe the OS-side
// verdict. No new entitlement, no new capability, no wire schema
// change. Fits inside the ADR-0013 §7 fail-closed direction: on a
// probe error we treat the surface as `.unknown`, which the session
// bridge maps to "leave capture as-is" — never a spurious pause OR a
// spurious resume.

import Foundation

#if canImport(AppKit)
    import AppKit
    import ApplicationServices
    import CoreGraphics
#endif

/// The four TCC surfaces MCI depends on. `automation` is enumerated
/// but stubbed (see file header — per-target probe is expensive).
public enum TCCSurface: String, Sendable, CaseIterable {
    case screenRecording
    case accessibility
    case fullDiskAccess
    case automation
}

/// Per-surface verdict. `.unknown` is the fail-safe fallback used when
/// the probe itself errors — we neither pause nor resume capture on
/// unknown, so a probe glitch cannot flap the SCStream.
public enum TCCStatus: String, Sendable, Equatable {
    case granted
    case denied
    case unknown
}

// MARK: - Probe seam (headless-testable)

/// A single-shot read of the current OS-side TCC verdict for one
/// surface. Implementations MUST return `.unknown` on any error path
/// rather than throwing — the monitor's debounce logic is built on
/// tri-state verdicts and cannot recover from a mid-poll throw.
public protocol TCCProbe: Sendable {
    func status(for surface: TCCSurface) -> TCCStatus
}

/// The default OS-touching probe. `// UNVERIFIED — needs live macOS`
/// for the CoreGraphics / AX / filesystem reads. Behaviour is
/// documented; correctness requires the §7 secure-surface corpus.
public struct DefaultTCCProbe: TCCProbe {
    /// Optional override for the FDA probe path — used by tests to
    /// point at a known-readable file (or a known-unreadable one) so
    /// the OS branch can be exercised without an FDA grant.
    public let fdaProbePath: URL

    public init(fdaProbePath: URL? = nil) {
        if let override = fdaProbePath {
            self.fdaProbePath = override
        } else {
            // `Library/Safari/Bookmarks.plist` is FDA-gated on macOS
            // 10.15+ and reliably present in a stock user profile.
            self.fdaProbePath = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Bookmarks.plist")
        }
    }

    public func status(for surface: TCCSurface) -> TCCStatus {
        switch surface {
        case .screenRecording: return probeScreenRecording()
        case .accessibility: return probeAccessibility()
        case .fullDiskAccess: return probeFullDiskAccess()
        case .automation:
            // Stubbed — see file header. `.unknown` means the monitor
            // never emits a revoked-transition for automation; a
            // follow-up PR will wire `AEDeterminePermissionToAutomateTarget`.
            return .unknown
        }
    }

    private func probeScreenRecording() -> TCCStatus {
        #if canImport(AppKit)
            // UNVERIFIED — needs live macOS; do not claim working.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        #else
            return .unknown
        #endif
    }

    private func probeAccessibility() -> TCCStatus {
        #if canImport(AppKit)
            // UNVERIFIED — needs live macOS; do not claim working.
            // `AXIsProcessTrusted()` is the non-prompting variant — it
            // never fires a system dialog, so it is safe on the 0.5 Hz
            // poll path.
            return AXIsProcessTrusted() ? .granted : .denied
        #else
            return .unknown
        #endif
    }

    private func probeFullDiskAccess() -> TCCStatus {
        // Indirect probe: try to open the file for reading. FDA-denied
        // returns EPERM (errno 1) or EACCES (errno 13); missing file
        // returns ENOENT (2) which we treat as `.unknown` so a user
        // without Safari installed doesn't trigger a false-denied
        // spurious pause. `.unknown` means the surface-bridge leaves
        // capture as-is.
        let fd = open(fdaProbePath.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        // Copy errno immediately — any subsequent syscall can clobber it.
        let e = errno
        if e == EPERM || e == EACCES {
            return .denied
        }
        return .unknown
    }
}

// MARK: - Monitor

/// Periodic monitor. `@unchecked Sendable`: mutable state is guarded
/// by an `NSLock`.
public final class TCCStatusMonitor: @unchecked Sendable {

    /// State-transition notification. Fires ONLY when the debounced
    /// verdict for a surface flips. `oldStatus`/`newStatus` never
    /// equal each other in a transition event.
    public struct Transition: Sendable, Equatable {
        public let surface: TCCSurface
        public let oldStatus: TCCStatus
        public let newStatus: TCCStatus
        public init(surface: TCCSurface, oldStatus: TCCStatus, newStatus: TCCStatus) {
            self.surface = surface
            self.oldStatus = oldStatus
            self.newStatus = newStatus
        }
    }

    public protocol Observer: AnyObject, Sendable {
        func tccStatusDidTransition(_ transition: Transition) async
    }

    private let probe: TCCProbe
    private let pollIntervalNs: UInt64
    /// The surfaces the monitor polls. Automation is included so a
    /// future PR flipping `DefaultTCCProbe.probeAutomation()` from
    /// `.unknown` to a real verdict starts firing transitions with no
    /// wiring change. Callers can shrink the set for tests.
    private let surfaces: [TCCSurface]

    private let lock = NSLock()
    private weak var observer: (any Observer)?
    private var pollTask: Task<Void, Never>?
    /// Debounced/published state — the "truth" as the outside world
    /// sees it.
    private var published: [TCCSurface: TCCStatus] = [:]
    /// Grant-repeat counter: number of consecutive polls that returned
    /// `.granted` for a surface currently published as `.denied`.
    /// Fail-safe: we only re-publish `.granted` after two consecutive
    /// grants (avoids resuming capture on a stale-cache flap).
    /// Revocation (granted → denied) is single-sample by design —
    /// pause immediately.
    private var grantRepeats: [TCCSurface: Int] = [:]

    public init(
        probe: TCCProbe = DefaultTCCProbe(),
        pollIntervalNs: UInt64 = 2_000_000_000, // 0.5 Hz per mission constraint
        surfaces: [TCCSurface] = TCCSurface.allCases,
        observer: (any Observer)? = nil
    ) {
        self.probe = probe
        self.pollIntervalNs = pollIntervalNs
        self.surfaces = surfaces
        self.observer = observer
    }

    public func setObserver(_ observer: (any Observer)?) {
        lock.lock(); self.observer = observer; lock.unlock()
    }

    /// Seed the published verdict without firing observer callbacks.
    /// Called at boot with the initial TCC snapshot — the whole point
    /// of the monitor is to detect a mid-run *transition* from the
    /// boot-time verdict, so the boot verdict itself must not fire.
    public func seedInitialSnapshot() {
        lock.lock()
        for surface in surfaces {
            published[surface] = probe.status(for: surface)
            grantRepeats[surface] = 0
        }
        lock.unlock()
    }

    /// Snapshot of currently-published statuses. Lock-guarded.
    public func currentStatuses() -> [TCCSurface: TCCStatus] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Start the poll loop. Idempotent. Callers should invoke
    /// `seedInitialSnapshot()` first (this method does NOT seed —
    /// otherwise the first tick would fire a spurious transition for
    /// every surface).
    public func start() {
        lock.lock()
        guard pollTask == nil else { lock.unlock(); return }
        let interval = pollIntervalNs
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickOnce()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        pollTask = task
        lock.unlock()
    }

    /// Stop the poll loop. Idempotent.
    public func stop() {
        lock.lock()
        let t = pollTask
        pollTask = nil
        lock.unlock()
        t?.cancel()
    }

    /// One poll cycle across all surfaces. `internal` so tests can
    /// drive ticks directly without an async sleep loop.
    internal func tickOnce() async {
        // Snapshot the observer + capture the transitions inside the
        // critical section, fire callbacks outside so a slow observer
        // never blocks the poll loop's next tick.
        var toEmit: [Transition] = []
        var observerSnapshot: (any Observer)?
        lock.lock()
        for surface in surfaces {
            let sample = probe.status(for: surface)
            let old = published[surface] ?? .unknown
            let transition = decideTransition(
                surface: surface, old: old, sample: sample
            )
            if let t = transition {
                published[surface] = t.newStatus
                grantRepeats[surface] = 0
                toEmit.append(t)
            }
        }
        observerSnapshot = observer
        lock.unlock()

        for t in toEmit {
            await observerSnapshot?.tccStatusDidTransition(t)
        }
    }

    /// Pure debounce/decision function — called under `lock`. Returns
    /// a `Transition` when the debounced state flips, otherwise `nil`
    /// (bumping the grant-repeat counter as a side effect for
    /// grant candidates).
    ///
    /// Direction-asymmetric fail-safe:
    ///   - `granted → denied` : ALWAYS single-sample (pause immediately).
    ///   - `denied → granted` : requires 2 consecutive `.granted`
    ///     samples (avoids resuming on a stale-cache flicker).
    ///   - `unknown → anything`: single-sample (the initial verdict
    ///     is authoritative; seed avoids this via `seedInitialSnapshot`).
    ///   - `X → unknown`      : NEVER a transition. Probe errors are
    ///     absorbed as "leave state as-is" — capture continues in
    ///     whichever direction it was already going.
    private func decideTransition(
        surface: TCCSurface,
        old: TCCStatus,
        sample: TCCStatus
    ) -> Transition? {
        if sample == .unknown {
            // Probe error — do not fire. Leave the counter alone; a
            // future good sample will reset it via a real transition.
            return nil
        }
        if sample == old {
            grantRepeats[surface] = 0
            return nil
        }
        // sample != old, sample != .unknown
        if sample == .denied {
            // Immediate pause.
            return Transition(surface: surface, oldStatus: old, newStatus: .denied)
        }
        // sample == .granted, old != .granted
        let prior = grantRepeats[surface] ?? 0
        let next = prior + 1
        if next >= 2 {
            return Transition(surface: surface, oldStatus: old, newStatus: .granted)
        }
        grantRepeats[surface] = next
        return nil
    }
}

// MARK: - Health emission

/// Formats a helper-health stderr breadcrumb for a TCC transition.
/// Content-free: only surface name + boolean cross the process
/// boundary — no file paths, no bundle ids, no user data. The parent
/// Hippocampus app tails stderr and drives the menu-bar red pill from
/// this signal.
public enum TCCHelperHealth {
    public static func line(for transition: TCCStatusMonitor.Transition) -> String {
        let key = transition.newStatus == .denied ? "tcc_revoked" : "tcc_restored"
        return "mci-capture-helper: helper_health \(key)=\(transition.surface.rawValue)\n"
    }
}
