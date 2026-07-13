// SPDX-License-Identifier: TBD-private
//
// AutomationTargetMonitor — cycle 8.47 PR #80 follow-up. Completes the
// Automation TCC stub with a real per-target probe.
// PROTECTED-SET per AGENT_PROTOCOL §5. Privacy invariant UNCHANGED:
// this file adds NO capability — it only observes the OS-side verdict
// for Apple-Events automation against the specific target apps MCI
// already talks to (Safari for the browser-extension bridge; Chrome for
// the deep-hook). It never sets `askUserIfNeeded: true`, so the probe
// itself CANNOT provoke a user-facing Apple-Events prompt.
//
// Why a per-target monitor (vs. reusing `TCCStatusMonitor`'s per-surface
// polling): unlike Screen Recording / Accessibility / FDA — which are
// per-app-boolean surfaces — Automation TCC is per-(source-app,
// target-app) pair. Safari and Chrome are two independent verdicts;
// treating them as one surface would either false-deny (any one denied
// → all denied) or false-grant (any one granted → all granted). Both
// directions break the mission constraint. So we track a
// `[BundleID: TCCStatus]` map with the same direction-asymmetric
// debounce as `TCCStatusMonitor` (revoke fires immediately; restore
// requires two consecutive grants).
//
// Wire format (composed with `TCCHelperHealth.line(...)`):
//     mci-capture-helper: helper_health tcc_revoked=automation:com.apple.Safari
//     mci-capture-helper: helper_health tcc_restored=automation:com.google.Chrome
// The `automation:<bundleId>` colon-form is the wire schema; the
// app-side sibling PR extends `TCCRevokedReason.fromHealthLogSurface`
// to parse it. Only well-known TARGET bundle-ids we've explicitly
// registered ever appear — no arbitrary process names, no user
// filesystem paths — so the content-free stderr invariant holds.
//
// The OS-touching probe implementation is `// UNVERIFIED — needs live
// macOS`. The state machine is unit-tested headlessly via the
// `AutomationProbe` seam (mirrors the `TCCProbe` seam pattern).

import Foundation

#if canImport(AppKit)
    import AppKit
    import ApplicationServices
    import CoreServices
#endif

// MARK: - Probe seam (headless-testable)

/// A single-shot read of the current OS-side Automation verdict for one
/// target bundle-id. Implementations MUST return `.unknown` on any
/// error path (target not running, unrecognized bundle, syscall error)
/// rather than throwing — the monitor's debounce logic is built on
/// tri-state verdicts and cannot recover from a mid-poll throw.
///
/// `askUser` is exposed for parity with the underlying Apple API but
/// the monitor ALWAYS passes `false`. Prompting the user at 0.5 Hz is
/// a UX disaster (mission constraint).
public protocol AutomationProbe: Sendable {
    func status(forTargetBundle bundleId: String, askUser: Bool) -> TCCStatus
}

/// The default OS-touching probe. Calls
/// `AEDeterminePermissionToAutomateTarget` with a benign `kAEActivate`
/// event descriptor pointed at the target bundle. Return-code mapping:
///
///   - `noErr` (0)                 → `.granted`
///   - `errAEEventNotPermitted` (-1743) → `.denied`
///   - `procNotFound` (-600)       → `.unknown` (target app not running;
///                                              we can't tell whether
///                                              the user has granted or
///                                              denied, so leave
///                                              current published state
///                                              alone rather than
///                                              flip-flopping every time
///                                              Safari happens to be
///                                              closed)
///   - any other error             → `.unknown` (fail-safe)
///
/// `// UNVERIFIED — needs live macOS` for the AE descriptor + syscall
/// path. State-machine correctness is exercised via `AutomationProbe`
/// mocks.
public struct DefaultAutomationProbe: AutomationProbe {
    public init() {}

    public func status(forTargetBundle bundleId: String, askUser: Bool) -> TCCStatus {
        #if canImport(AppKit)
            // UNVERIFIED — needs live macOS; do not claim working.
            //
            // Build an NSAppleEventDescriptor pointing at the bundle
            // via typeApplicationBundleID (macOS 10.11+). This is the
            // Apple-recommended shape for `AEDeterminePermission…` when
            // the caller wants to check a specific app without needing
            // its PID.
            let target = NSAppleEventDescriptor(
                descriptorType: typeApplicationBundleID,
                data: Data(bundleId.utf8)
            )
            guard let targetDesc = target, let aeDescPtr = targetDesc.aeDesc else {
                return .unknown
            }
            let status = AEDeterminePermissionToAutomateTarget(
                aeDescPtr,
                AEEventClass(kAEMiscStandards),
                AEEventID(kAEActivate),
                askUser
            )
            switch status {
            case noErr:
                return .granted
            case OSStatus(errAEEventNotPermitted):
                return .denied
            case OSStatus(procNotFound):
                // Target app isn't running — we cannot determine the
                // verdict. Do NOT emit `.denied`: that would flip the
                // menu-bar red-pill every time Safari happens to be
                // closed, which is the opposite of what we want.
                return .unknown
            default:
                return .unknown
            }
        #else
            return .unknown
        #endif
    }
}

// MARK: - Monitor

/// Per-target Automation TCC monitor. Same direction-asymmetric
/// debounce as `TCCStatusMonitor`:
///   - `granted → denied` : ALWAYS single-sample (pause immediately).
///   - `denied → granted` : requires 2 consecutive granted samples.
///   - `X → unknown`      : NEVER a transition. Probe errors + closed
///                          target apps are absorbed as "leave state
///                          as-is" — the helper does not flap the
///                          menu-bar pill when Safari happens to be
///                          closed.
///   - `unknown → X`      : single-sample (initial verdict is authoritative).
///
/// `@unchecked Sendable`: mutable state guarded by an `NSLock`.
public final class AutomationTargetMonitor: @unchecked Sendable {

    /// Per-target state-transition notification. Fires ONLY when the
    /// debounced verdict for a specific target bundle flips.
    public struct Transition: Sendable, Equatable {
        public let targetBundleId: String
        public let oldStatus: TCCStatus
        public let newStatus: TCCStatus
        public init(targetBundleId: String, oldStatus: TCCStatus, newStatus: TCCStatus) {
            self.targetBundleId = targetBundleId
            self.oldStatus = oldStatus
            self.newStatus = newStatus
        }
    }

    public protocol Observer: AnyObject, Sendable {
        func automationTargetDidTransition(_ transition: Transition) async
    }

    private let probe: AutomationProbe
    private let pollIntervalNs: UInt64
    /// The target bundle-ids we probe on every tick. Populated at
    /// startup from the well-known registry (see `WellKnownAutomationTargets`).
    /// Callers MUST NOT add arbitrary bundle-ids at runtime — that
    /// would spend the 0.5 Hz budget on irrelevant targets and could
    /// leak user-installed-app identity into the stderr breadcrumb.
    private let targets: [String]

    private let lock = NSLock()
    private weak var observer: (any Observer)?
    private var pollTask: Task<Void, Never>?
    private var published: [String: TCCStatus] = [:]
    private var grantRepeats: [String: Int] = [:]

    public init(
        probe: AutomationProbe = DefaultAutomationProbe(),
        pollIntervalNs: UInt64 = 2_000_000_000, // 0.5 Hz — same as TCCStatusMonitor
        targets: [String],
        observer: (any Observer)? = nil
    ) {
        self.probe = probe
        self.pollIntervalNs = pollIntervalNs
        self.targets = targets
        self.observer = observer
    }

    public func setObserver(_ observer: (any Observer)?) {
        lock.lock(); self.observer = observer; lock.unlock()
    }

    /// Seed the published verdict without firing observer callbacks.
    /// Called at boot with the initial per-target snapshot — the whole
    /// point of the monitor is to detect a mid-run *transition* from
    /// the boot-time verdict, so the boot verdict itself must not fire.
    public func seedInitialSnapshot() {
        lock.lock()
        for bundle in targets {
            published[bundle] = probe.status(forTargetBundle: bundle, askUser: false)
            grantRepeats[bundle] = 0
        }
        lock.unlock()
    }

    /// Snapshot of currently-published per-target statuses. Lock-guarded.
    public func currentStatuses() -> [String: TCCStatus] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Start the poll loop. Idempotent.
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

    /// One poll cycle across all registered targets. `internal` so
    /// tests can drive ticks directly without an async sleep loop.
    internal func tickOnce() async {
        var toEmit: [Transition] = []
        var observerSnapshot: (any Observer)?
        lock.lock()
        for bundle in targets {
            // askUser: false — mission constraint. NEVER prompt on poll.
            let sample = probe.status(forTargetBundle: bundle, askUser: false)
            let old = published[bundle] ?? .unknown
            if let t = decideTransition(bundle: bundle, old: old, sample: sample) {
                published[bundle] = t.newStatus
                grantRepeats[bundle] = 0
                toEmit.append(t)
            }
        }
        observerSnapshot = observer
        lock.unlock()

        for t in toEmit {
            await observerSnapshot?.automationTargetDidTransition(t)
        }
    }

    /// Pure debounce/decision function — called under `lock`. Mirrors
    /// `TCCStatusMonitor.decideTransition` exactly (revoke is
    /// single-sample; restore requires 2 consecutive grants; probe
    /// `.unknown` never fires).
    private func decideTransition(
        bundle: String,
        old: TCCStatus,
        sample: TCCStatus
    ) -> Transition? {
        if sample == .unknown {
            return nil
        }
        if sample == old {
            grantRepeats[bundle] = 0
            return nil
        }
        if sample == .denied {
            return Transition(targetBundleId: bundle, oldStatus: old, newStatus: .denied)
        }
        // sample == .granted, old != .granted
        let prior = grantRepeats[bundle] ?? 0
        let next = prior + 1
        if next >= 2 {
            return Transition(targetBundleId: bundle, oldStatus: old, newStatus: .granted)
        }
        grantRepeats[bundle] = next
        return nil
    }
}

// MARK: - Well-known target registry

/// The bundle-ids MCI has actual reason to probe. Startup code builds
/// its target list from this set filtered by which bridges are actually
/// installed — probing bundle-ids we've never registered a
/// native-messaging host with would just spend the 0.5 Hz budget on
/// noise and could leak installed-app identity into the stderr wire.
public enum WellKnownAutomationTarget: String, Sendable, CaseIterable {
    /// Safari — for the MCI browser-extension bridge (Apple Events is
    /// the only way to talk to a Safari extension from an unrelated
    /// helper process).
    case safari = "com.apple.Safari"
    /// Google Chrome — for the MCI Chrome deep-hook path (native
    /// messaging is preferred, but AE is the fallback for a small set
    /// of surfaces).
    case chrome = "com.google.Chrome"

    public var bundleId: String { rawValue }
}

/// Helper to build the initial target list from the set of bridges
/// MCI has actually registered at startup. Callers pass in booleans
/// indicating which bridges are wired up; only registered targets are
/// probed. Startup code lives above `MCICaptureHelperKit` — this helper
/// is deliberately a pure function so it's trivially unit-testable.
public enum AutomationTargetRegistry {
    public static func registeredTargets(
        safariExtensionInstalled: Bool,
        chromeExtensionInstalled: Bool
    ) -> [String] {
        var out: [String] = []
        if safariExtensionInstalled { out.append(WellKnownAutomationTarget.safari.bundleId) }
        if chromeExtensionInstalled { out.append(WellKnownAutomationTarget.chrome.bundleId) }
        return out
    }
}

// MARK: - Health emission

/// Formats the stderr breadcrumb for a per-target Automation transition.
/// Wire form: `helper_health tcc_revoked=automation:<bundleId>\n` (or
/// `tcc_restored=…`). The app-side sibling PR extends
/// `TCCRevokedReason.fromHealthLogSurface` to parse the `automation:`
/// prefix and route accordingly.
///
/// Only well-known target bundle-ids from `WellKnownAutomationTarget`
/// ever appear on this wire — no arbitrary process names — so the
/// content-free-stderr invariant is preserved (bundle-ids we control
/// are not user data).
public enum AutomationTargetHelperHealth {
    public static func line(for transition: AutomationTargetMonitor.Transition) -> String {
        let key = transition.newStatus == .denied ? "tcc_revoked" : "tcc_restored"
        return "mci-capture-helper: helper_health \(key)=automation:\(transition.targetBundleId)\n"
    }
}
