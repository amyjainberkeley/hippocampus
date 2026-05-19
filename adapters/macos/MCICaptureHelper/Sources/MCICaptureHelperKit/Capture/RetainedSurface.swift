// SPDX-License-Identifier: TBD-private
//
// RetainedSurface — the IOSurface retain → owned-lease release
// discipline (enabler PR-2). PROTECTED-SET per AGENT_PROTOCOL §5.
// §4 footprint-critical (the IOSurface-pool-stall failure mode).
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ THE §4 FAILURE MODE THIS FILE EXISTS TO PREVENT                  │
// │                                                                  │
// │ ScreenCaptureKit hands frames out of a fixed `queueDepth` pool.  │
// │ A captured surface MUST be relinquished back to the pool within  │
// │ ~`minimumFrameInterval × (queueDepth − 1)` or the stream         │
// │ silently STALLS (DESIGN.md §5.1, R8). PR-1 retained nothing      │
// │ (`BorrowedNoRetainReleaser`), so a stall was structurally        │
// │ impossible. PR-3's encoder will need the pixels to outlive the   │
// │ callback — i.e. a real retain. PR-2 introduces that retain       │
// │ NOW, ahead of the encoder, with the exactly-once release         │
// │ discipline in place and unit-tested, so PR-3 plugs into a        │
// │ lifecycle that is already proven not to stall.                  │
// │                                                                  │
// │ The exactly-once guarantee is layered:                           │
// │   • `SurfaceLease.release()` is exactly-once-guarded (asserts on │
// │     a double release).                                           │
// │   • `SCStreamPipeline.process(...)` releases the lease via ONE   │
// │     top-level `defer` that runs on EVERY exit — filter-drop,     │
// │     suppress, allow, a throwing sink, a throwing encoder.        │
// │   • This file makes the underlying releaser actually free the    │
// │     retained `CVPixelBuffer` (⇒ the IOSurface) when that fires.  │
// │                                                                  │
// │ The live `CVPixelBuffer` retain itself is                        │
// │ `// UNVERIFIED — needs live macOS`. The reference LIFECYCLE      │
// │ (retain-once, relinquish-once, idempotent) is OS-free via the    │
// │ `PixelSurfaceRetaining` seam and IS unit-tested.                 │
// └──────────────────────────────────────────────────────────────────┘

import CoreVideo
import Foundation

/// A retained capture surface that must be relinquished back to the OS
/// pool exactly once. The seam that makes the release discipline
/// OS-free testable: production is a retained `CVPixelBuffer`; tests
/// use a counting double.
public protocol PixelSurfaceRetaining: Sendable {
    /// Relinquish the underlying OS retain. MUST be idempotent — the
    /// `SurfaceLease` exactly-once guard should make a second call
    /// impossible, but a defensive no-op on re-entry is required so a
    /// double release degrades to a logged invariant breach, never a
    /// crash or a double-free.
    func relinquish()
}

/// Adapts a `PixelSurfaceRetaining` to the existing `SurfaceReleasing`
/// contract the pipeline drives. One line, on purpose: the policy
/// (exactly-once, on every path) lives in `SurfaceLease` +
/// `SCStreamPipeline`; this only forwards the single release.
public struct PixelSurfaceReleaser: SurfaceReleasing {
    private let surface: any PixelSurfaceRetaining

    public init(surface: any PixelSurfaceRetaining) {
        self.surface = surface
    }

    public func releaseSurface() {
        surface.relinquish()
    }
}

/// Production retain holder. `// UNVERIFIED — needs live macOS; do not
/// claim working`.
///
/// Holding a Swift strong reference to a `CVPixelBuffer` retains its
/// backing `IOSurface`; dropping that reference relinquishes it back to
/// the ScreenCaptureKit pool. `relinquish()` drops the reference under
/// a lock and is idempotent. The lock-guarded set-once/drop-once
/// behaviour is exercised by `RetainedSurfaceTests` through a
/// reference-box double; the fact that an `Optional<CVPixelBuffer>`
/// going `nil` actually frees the IOSurface is the `// UNVERIFIED`
/// part (needs a live pool).
public final class CVPixelBufferRetainedSurface: PixelSurfaceRetaining, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    /// Retain `buffer` for as long as this object is alive (until
    /// `relinquish()`). The caller (the `// UNVERIFIED` callback)
    /// constructs this synchronously from the borrowed sample so the
    /// retain is explicit and bounded.
    public init(retaining buffer: CVPixelBuffer) {
        // UNVERIFIED — needs live macOS; do not claim working.
        self.buffer = buffer
    }

    public func relinquish() {
        // UNVERIFIED — needs live macOS; do not claim working.
        lock.lock()
        defer { lock.unlock() }
        // Dropping the only strong ref relinquishes the IOSurface to
        // the pool. Idempotent: a second call finds `nil` and no-ops.
        buffer = nil
    }

    /// Test/observability hook: whether the retain has been dropped.
    public var isRelinquished: Bool {
        lock.lock(); defer { lock.unlock() }
        return buffer == nil
    }
}
