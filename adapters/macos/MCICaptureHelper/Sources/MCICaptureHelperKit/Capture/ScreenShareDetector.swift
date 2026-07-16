// SPDX-License-Identifier: TBD-private
//
// ScreenShareDetector — cycle 8.44 audit risk #1 (Zoom/Meet/Teams
// screen-share leak class). PROTECTED-SET per AGENT_PROTOCOL §5.
// Privacy invariant: while the user is actively screen-sharing OR
// mirroring/AirPlaying, MCI capture must NOT record — the recall UI,
// menu-bar cursor hover, or a stray frame could reveal captured
// frames to the meeting audience.
//
// Signals: primary = `CGDisplayIsCaptured` + `CGDisplayIsInMirrorSet`
// across active displays. Attribution = `SCShareableContent.current`
// filtered against known screen-share bundle-ids. Fallback
// attribution = `NSWorkspace.runningApplications` (used only on
// primary throw, so we don't routinely probe running apps).
//
// Debounce: two consecutive samples must agree before the aggregated
// state flips. Prevents Zoom's momentary de-list/re-list at session
// start from causing capture-pause flapping. Fail-safe: primary throw
// → treat as active (over-pause, not under-pause). No bypass flag.
// Cost: 0.5 Hz poll, off the SCStream callback thread.
//
// OS-touching methods are `// UNVERIFIED — needs live macOS`. The
// debounce state machine is unit-tested headlessly.

import CoreGraphics
import Foundation
import ScreenCaptureKit

#if canImport(AppKit)
    import AppKit
#endif

/// Debounced verdict. `Sendable` — crosses the poll-task boundary.
public struct ScreenShareSample: Sendable, Equatable {
    public let isSharingActive: Bool
    /// Bundle-id (or `"CGDisplay"` / `"MirrorSet"`) of the firing
    /// signal. Surfaced to the menu-bar pause-reason pill.
    public let sharingActor: String?

    public init(isSharingActive: Bool, sharingActor: String?) {
        self.isSharingActive = isSharingActive
        self.sharingActor = sharingActor
    }

    public static let inactive = ScreenShareSample(
        isSharingActive: false, sharingActor: nil
    )
}

// MARK: - Probe seams (headless-testable)

public protocol DisplayCaptureProbe: Sendable {
    func capturedDisplays() throws -> [(displayId: UInt32, reason: String)]
}

public protocol SharedContentProbe: Sendable {
    func capturingApplications() async throws -> [String]
}

public protocol RunningAppProbe: Sendable {
    func runningScreenShareApps() -> [String]
}

public enum ScreenShareProbeError: Error {
    case osAPIUnavailable(String)
}

// MARK: - Default OS-touching implementations

/// `// UNVERIFIED — needs live macOS`.
public struct CoreGraphicsDisplayCaptureProbe: DisplayCaptureProbe {
    public init() {}

    public func capturedDisplays() throws -> [(displayId: UInt32, reason: String)] {
        // UNVERIFIED — needs live macOS; do not claim working.
        var count: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &count)
        guard result == .success else {
            throw ScreenShareProbeError.osAPIUnavailable(
                "CGGetActiveDisplayList(count) = \(result.rawValue)"
            )
        }
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        result = CGGetActiveDisplayList(count, &displays, &count)
        guard result == .success else {
            throw ScreenShareProbeError.osAPIUnavailable(
                "CGGetActiveDisplayList(list) = \(result.rawValue)"
            )
        }
        var out: [(displayId: UInt32, reason: String)] = []
        for id in displays.prefix(Int(count)) {
            // macOS-15 SDK migration (2026-07-15): `CGDisplayIsCaptured` was
            // REMOVED ("No longer supported") with no drop-in replacement.
            // Exclusive-capture / screen-recording detection now relies on
            // the app-level probes (`SCShareableContentProbe` +
            // `NSWorkspaceRunningAppProbe`) the detector fuses into its
            // verdict. This probe keeps the mirror-set signal (AirPlay /
            // Sidecar / hardware mirror), which is unaffected.
            //
            // *** CSO-REVIEW + LIVE-MAC-VALIDATE (screen-share is the top
            // privacy invariant): confirm Zoom / Meet / Teams / AirPlay
            // still trip auto-pause via the combined verdict on a real Mac
            // BEFORE shipping. See docs/research/2026-07-15-app-build-
            // blockers.md §C. ***
            if CGDisplayIsInMirrorSet(id) != 0 {
                // Sidecar / AirPlay / hardware-mirror all fold in here.
                out.append((UInt32(id), "MirrorSet"))
            }
        }
        return out
    }
}

/// `// UNVERIFIED — needs live macOS`.
public struct SCShareableContentProbe: SharedContentProbe {
    public init() {}

    public func capturingApplications() async throws -> [String] {
        // UNVERIFIED — needs live macOS; do not claim working.
        let content = try await SCShareableContent.current
        let known = knownScreenShareBundleIds
        return content.applications
            .map(\.bundleIdentifier)
            .filter { known.contains($0) }
    }
}

/// `// UNVERIFIED — needs live macOS`.
public struct NSWorkspaceRunningAppProbe: RunningAppProbe {
    public init() {}

    public func runningScreenShareApps() -> [String] {
        // UNVERIFIED — needs live macOS; do not claim working.
        #if canImport(AppKit)
            let known = knownScreenShareBundleIds
            return NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { known.contains($0) }
        #else
            return []
        #endif
    }
}

/// Known screen-share apps, for attribution. Adding entries widens
/// attribution names but does NOT change the pause decision (driven
/// by `CGDisplayIsCaptured`).
public let knownScreenShareBundleIds: Set<String> = [
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.apple.Safari",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
    "com.apple.QuickTimePlayerX",
]

// MARK: - The detector

/// Periodic detector — 0.5 Hz poll, 2-sample debounce, notifies
/// observer on state transitions. Never touches the frame-emit path.
public final class ScreenShareDetector: @unchecked Sendable {
    public protocol Observer: AnyObject, Sendable {
        func screenShareDetectorDidTransition(to sample: ScreenShareSample) async
    }

    public struct RawVerdict: Sendable, Equatable {
        public let isSharingActive: Bool
        public let sharingActor: String?
        public init(isSharingActive: Bool, sharingActor: String?) {
            self.isSharingActive = isSharingActive
            self.sharingActor = sharingActor
        }
    }

    private let displayProbe: DisplayCaptureProbe
    private let sharedContentProbe: SharedContentProbe
    private let runningAppProbe: RunningAppProbe
    private let pollIntervalNs: UInt64
    private weak var observer: (any Observer)?

    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var pendingSample: ScreenShareSample = .inactive
    private var pendingRepeatCount: Int = 0
    private var publishedSample: ScreenShareSample = .inactive

    public init(
        displayProbe: DisplayCaptureProbe = CoreGraphicsDisplayCaptureProbe(),
        sharedContentProbe: SharedContentProbe = SCShareableContentProbe(),
        runningAppProbe: RunningAppProbe = NSWorkspaceRunningAppProbe(),
        pollIntervalNs: UInt64 = 2_000_000_000, // 0.5 Hz
        observer: (any Observer)? = nil
    ) {
        self.displayProbe = displayProbe
        self.sharedContentProbe = sharedContentProbe
        self.runningAppProbe = runningAppProbe
        self.pollIntervalNs = pollIntervalNs
        self.observer = observer
    }

    public func setObserver(_ observer: (any Observer)?) {
        lock.lock(); self.observer = observer; lock.unlock()
    }

    public func currentPublishedSample() -> ScreenShareSample {
        lock.lock(); defer { lock.unlock() }
        return publishedSample
    }

    /// Start the background poll. Idempotent.
    public func start() {
        lock.lock()
        guard pollTask == nil else { lock.unlock(); return }
        let interval = pollIntervalNs
        let task = Task { [weak self] in
            while !Task.isCancelled {
                let verdict = await self?.pollOnce() ?? RawVerdict(
                    isSharingActive: true, sharingActor: nil // fail-safe
                )
                await self?.applyDebounced(verdict: verdict)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        pollTask = task
        lock.unlock()
    }

    /// Stop the background poll. Idempotent.
    public func stop() {
        lock.lock()
        let t = pollTask
        pollTask = nil
        lock.unlock()
        t?.cancel()
    }

    /// One poll cycle. `internal` so tests can drive ticks directly.
    internal func pollOnce() async -> RawVerdict {
        do {
            let displays = try displayProbe.capturedDisplays()
            if displays.isEmpty {
                return RawVerdict(isSharingActive: false, sharingActor: nil)
            }
            let actor: String?
            do {
                let apps = try await sharedContentProbe.capturingApplications()
                actor = apps.first ?? displays.first?.reason
            } catch {
                actor = displays.first?.reason
            }
            return RawVerdict(isSharingActive: true, sharingActor: actor)
        } catch {
            // Fail-safe: primary threw → assume sharing.
            return RawVerdict(
                isSharingActive: true,
                sharingActor: runningAppProbe.runningScreenShareApps().first
            )
        }
    }

    /// Debounce state machine. Observer fires ONLY on state flips
    /// (or actor refreshes within an ongoing active state).
    internal func applyDebounced(verdict: RawVerdict) async {
        let (sampleToPublish, observerSnapshot): (ScreenShareSample?, (any Observer)?) = lock.withLock {
            let candidate = ScreenShareSample(
                isSharingActive: verdict.isSharingActive,
                sharingActor: verdict.sharingActor
            )
            if candidate.isSharingActive == pendingSample.isSharingActive {
                pendingRepeatCount += 1
            } else {
                pendingSample = candidate
                pendingRepeatCount = 1
            }
            let sampleToPublish: ScreenShareSample?
            // First sample sets pendingSample; second (repeatCount == 2)
            // confirms — total 2 consecutive samples in agreement.
            if pendingRepeatCount >= 2,
               candidate.isSharingActive != publishedSample.isSharingActive
            {
                publishedSample = candidate
                sampleToPublish = candidate
            } else if pendingRepeatCount >= 2,
                      candidate.isSharingActive,
                      candidate.sharingActor != publishedSample.sharingActor
            {
                // Actor changed within an ongoing active state — refresh
                // the pill without counting as a state flip.
                publishedSample = candidate
                sampleToPublish = candidate
            } else {
                sampleToPublish = nil
            }
            return (sampleToPublish, observer)
        }

        if let sample = sampleToPublish {
            await observerSnapshot?.screenShareDetectorDidTransition(to: sample)
        }
    }
}
