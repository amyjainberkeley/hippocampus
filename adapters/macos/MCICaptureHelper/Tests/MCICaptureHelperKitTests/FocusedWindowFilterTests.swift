// SPDX-License-Identifier: TBD-private
//
// FocusedWindowFilterTests — headless coverage for the ADR-0031 V2-P1
// focused-window filter machinery:
//   - `SCContentFilterFactory.selectFocusedWindow(...)` selection matrix
//   - `SCStreamPipeline.emitFocusRaceDropped(...)` tombstone shape +
//     counter discipline
//   - `SCStreamCaptureSession.buildWorkflowContext(...)` attribution
//     source-of-truth swap to the focused-window bundle id
//
// Production OS calls (`SCShareableContent.current`, `SCContentFilter`
// init from a live `SCWindow`, `SCStream.updateContentFilter`) are
// `// UNVERIFIED — needs live macOS`. These tests cover the OS-free
// decision surface — the audit-able part.

import CoreGraphics
import Foundation
import XCTest

@testable import MCICaptureHelperKit

private struct DenyApps: DenylistProbe {
    let apps: Set<String>
    init(_ apps: Set<String> = []) { self.apps = apps }
    func appIsDenied(bundleId: String) -> Bool { apps.contains(bundleId) }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private func denylist(_ deny: Set<String> = []) -> Denylist {
    Denylist(entries: deny.map { DenylistEntry(kind: .appBundle, pattern: $0) })
}

final class SelectFocusedWindowTests: XCTestCase {
    func test_returns_matched_descriptor_when_windowid_present_and_allowed() {
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.apple.Safari"),
            SCContentFilterFactory.WindowDescriptor(windowId: 2, bundleId: "com.apple.Terminal"),
        ]
        let result = SCContentFilterFactory.selectFocusedWindow(
            from: descriptors,
            windowId: 2,
            denylist: denylist()
        )
        XCTAssertEqual(result?.windowId, 2)
        XCTAssertEqual(result?.bundleId, "com.apple.Terminal")
    }

    func test_returns_nil_when_windowid_missing() {
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.apple.Safari"),
        ]
        let result = SCContentFilterFactory.selectFocusedWindow(
            from: descriptors,
            windowId: 99,
            denylist: denylist()
        )
        XCTAssertNil(result)
    }

    func test_returns_nil_when_owning_app_is_denylisted() {
        // ADR-0013 §1 composition: a denylisted app's window never
        // becomes the SCStream's bound window. The selection helper
        // refuses to return it; the live factory refuses to bind it.
        let descriptors = [
            SCContentFilterFactory.WindowDescriptor(windowId: 1, bundleId: "com.1password.1password"),
        ]
        let result = SCContentFilterFactory.selectFocusedWindow(
            from: descriptors,
            windowId: 1,
            denylist: denylist(["com.1password.1password"])
        )
        XCTAssertNil(result)
    }

    func test_returns_nil_when_descriptors_empty() {
        let result = SCContentFilterFactory.selectFocusedWindow(
            from: [],
            windowId: 1,
            denylist: denylist()
        )
        XCTAssertNil(result)
    }

    func test_excludedBundleIDs_helper_remains_intact() {
        // Sanity: the V2-P1 changes to the factory must not regress
        // the legacy display-filter primitive (used by sessions without
        // a focused-window store).
        let excluded = SCContentFilterFactory.excludedBundleIDs(
            runningBundleIDs: ["com.apple.Safari", "com.1password.1password"],
            denylist: denylist(["com.1password.1password"])
        )
        XCTAssertEqual(excluded, ["com.1password.1password"])
    }
}

// MARK: - Pipeline focusRaceDropped emit path

private actor RecordingSink: FrameSink {
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func writeCount() -> Int { writes.count }
    func writeBytes() -> [Data] { writes }
}

private struct NoSEI: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct AXNonSecure: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoBlack: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private final class SpyReleaser: SurfaceReleasing, @unchecked Sendable {
    private let l = NSLock()
    private var n = 0
    func releaseSurface() { l.lock(); n += 1; l.unlock() }
    var releaseCount: Int { l.lock(); defer { l.unlock() }; return n }
}

private struct NoopEncoder: FrameEncoder {
    func encodeAllowedFrame(input _: EncoderInput?, seq _: UInt64, context _: WorkflowContext) async throws {}
}

final class EmitFocusRaceDroppedTests: XCTestCase {
    func test_emits_tombstone_with_focusRaceDropped_reason_and_increments_counters() async throws {
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(),
            blackedRegion: NoBlack()
        )
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: NoopEncoder(),
            counters: counters,
            sink: sink
        )
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)

        try await pipeline.emitFocusRaceDropped(
            tsUs: 1_234_567,
            appBundle: "com.apple.Safari",
            lease: lease
        )

        // Exactly one tombstone written.
        let count = await sink.writeCount()
        XCTAssertEqual(count, 1)

        // Surface lease released exactly once (defer fires on the
        // happy path).
        XCTAssertEqual(releaser.releaseCount, 1)

        // Counters: delivered, suppressed, focus_race_dropped all
        // bumped by one. recordRedactedByFailsafe NOT bumped — focus
        // race is its own subcount per ADR-0031 §3.
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, 1)
        XCTAssertEqual(snap.framesSuppressed, 1)
        XCTAssertEqual(snap.framesFocusRaceDropped, 1)
        XCTAssertEqual(snap.framesRedactedByFailsafe, 0)

        // Inspect the tombstone bytes — frame should contain the
        // RedactionReason.focusRaceDropped (= 8) discriminant.
        let bytes = await sink.writeBytes()
        guard let data = bytes.first else {
            XCTFail("no tombstone bytes")
            return
        }
        // The last byte of the wire-encoded PrivacyTombstone payload is
        // the reason discriminant. Header is 16 bytes; payload tail is
        // the reason byte after the variable-length app_bundle.
        let payloadLen = Int(data[12]) // u32 LE; only LSB needed here
        XCTAssertGreaterThan(payloadLen, 0)
        let reasonByte = data[data.count - 1]
        XCTAssertEqual(reasonByte, RedactionReason.focusRaceDropped.rawValue)
    }

    func test_idempotent_lease_release_on_sink_throw() async {
        struct ThrowingSink: FrameSink {
            struct Boom: Error {}
            func write(_: Data) async throws { throw Boom() }
        }
        let sink = ThrowingSink()
        let counters = HelperHealthCounters()
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(),
            blackedRegion: NoBlack()
        )
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: NoopEncoder(),
            counters: counters,
            sink: sink
        )
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)

        do {
            try await pipeline.emitFocusRaceDropped(
                tsUs: 0,
                appBundle: "x",
                lease: lease
            )
            XCTFail("expected sink to throw")
        } catch {
            // Expected.
        }
        // Amendment 1 §3(d) — lease still released exactly once.
        XCTAssertEqual(releaser.releaseCount, 1)
    }
}

// MARK: - buildWorkflowContext attribution source-of-truth

final class BuildWorkflowContextFocusedAttributionTests: XCTestCase {
    func test_focused_snapshot_bundle_id_supersedes_snapshot_actor() async {
        let snapshotActor = WorkflowContextSnapshot()
        // Frontmost-app poller stored an older bundle id.
        await snapshotActor.store(
            WorkflowContext(
                appBundleId: "com.apple.Safari",
                windowTitle: "old title",
                url: nil,
                pageText: nil
            )
        )
        let focusedSnap = FocusedWindowSnapshot(
            focused: FocusedWindow(
                bundleId: "com.apple.Terminal",
                windowId: 1
            ),
            generation: 5
        )
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snapshotActor,
            urlProvider: nil,
            fallbackAppBundleId: nil,
            focusedSnapshot: focusedSnap
        )
        // ADR-0031 V2-P1: focused-window bundle id wins.
        XCTAssertEqual(ctx.appBundleId, "com.apple.Terminal")
        // Title comes from the snapshot path (unchanged).
        XCTAssertEqual(ctx.windowTitle, "old title")
    }

    func test_no_focused_snapshot_falls_back_to_snapshot_bundle_id() async {
        let snapshotActor = WorkflowContextSnapshot()
        await snapshotActor.store(
            WorkflowContext(
                appBundleId: "com.apple.Safari",
                windowTitle: nil,
                url: nil,
                pageText: nil
            )
        )
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snapshotActor,
            urlProvider: nil,
            fallbackAppBundleId: "fallback",
            focusedSnapshot: nil
        )
        // No focused snapshot → snapshot's bundle id wins.
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
    }

    func test_focused_snapshot_with_nil_focused_falls_back_to_snapshot_actor() async {
        let snapshotActor = WorkflowContextSnapshot()
        await snapshotActor.store(
            WorkflowContext(
                appBundleId: "com.apple.Safari",
                windowTitle: nil,
                url: nil,
                pageText: nil
            )
        )
        let focusedSnap = FocusedWindowSnapshot(focused: nil, generation: 3)
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snapshotActor,
            urlProvider: nil,
            fallbackAppBundleId: nil,
            focusedSnapshot: focusedSnap
        )
        // Focused snapshot is present but `focused == nil` → fall
        // back to snapshot's bundle id.
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
    }

    func test_no_snapshot_actor_and_focused_snapshot_uses_focused_bundle() {
        let focusedSnap = FocusedWindowSnapshot(
            focused: FocusedWindow(bundleId: "com.apple.Terminal", windowId: 2),
            generation: 1
        )
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: nil,
            urlProvider: nil,
            fallbackAppBundleId: "fallback",
            focusedSnapshot: focusedSnap
        )
        XCTAssertEqual(ctx.appBundleId, "com.apple.Terminal")
    }
}
