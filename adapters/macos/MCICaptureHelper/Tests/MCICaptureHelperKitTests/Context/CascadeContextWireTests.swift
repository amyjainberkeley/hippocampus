// SPDX-License-Identifier: TBD-private
//
// CascadeContextWireTests — ADR-0015 §6 P2.5 acceptance: this is the
// FIRST PR in the repo on which real `appBundleId` / `windowTitle` /
// `url` reach the ADR-0013 suppression cascade. Before P2.5 the
// `WorkflowContext` constructed inside the SCStream callback was all
// nil; the cascade §1 (source-level denylist) was structurally dead
// and the `PrivacyTombstone.appBundleId` field — already on the wire
// since PR #44 (0x03) — always carried `""`.
//
// These tests pin the new wiring on three load-bearing axes:
//
//   1. PURE CONTEXT-BUILD MATRIX — `SCStreamCaptureSession`'s callback
//      delegates context assembly to the static
//      `buildWorkflowContext(snapshot:urlProvider:fallbackAppBundleId:)`
//      helper. The callback itself is `// UNVERIFIED — needs live
//      macOS`; the helper is pure and IS tested here across the
//      decision matrix (snapshot present / absent; URL provider
//      present / absent; bundleId empty vs populated). Mirrors the
//      `CapturedSampleExtractor` pattern: live OS read in the
//      `// UNVERIFIED` zone; pure assembly tested in the kit.
//
//   2. CASCADE §1 DENYLIST-SOURCE FIRES FOR THE FIRST TIME — feed
//      the snapshot a denylisted bundleId, drive
//      `SCStreamPipeline.process(...)`, assert
//      `.suppress(reason: .denylistSource)`. Before P2.5 the only
//      way this leg of `SuppressionCascade.decide(context:)` could
//      fire was a SuppressionCascadeTests unit test that hand-built
//      a `WorkflowContext`; the SCStream live path could not reach
//      it because no bundleId ever crossed. This test pins the
//      P2.5 wiring end-to-end through the pipeline.
//
//   3. PRIVACY-TOMBSTONE PAYLOAD CARRIES REAL bundleId — encode the
//      `PrivacyTombstone` the pipeline emits on the `.suppress`
//      path and verify the `app_bundle` field bytes carry the
//      actual bundleId, not the empty string. Pins the
//      observability surface ADR-0013 §4 "recall UI privacy
//      moments" needs ("MCI redacted this because 1Password was
//      frontmost") instead of the pre-P2.5 generic ("an app fired
//      the cascade").
//
// ADR-0015 §4 invariants exercised by construction:
//   - context-as-content / cascade-before-storage — the cascade is
//     consulted on the constructed `WorkflowContext`; no field is
//     written to the sink ahead of the cascade decision. The tests
//     assert the `.allow` path is not reached on any
//     `.suppress(reason: 1/7)` flow exercised here.
//   - real `appBundleId` in tombstone — test 3 + 4 below.
//   - no auto-grant — vacuous in headless tests (no AppleScript).

import XCTest

@testable import MCICaptureHelperKit

// ── Headless test doubles ────────────────────────────────────────────

private struct NoSEI: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}
private struct AXNonSecure: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}
private struct AXSilent: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { nil }
}
private struct DenyApps: DenylistProbe {
    let apps: Set<String>
    let urls: [String]
    let titles: [String]
    init(apps: Set<String> = [], urls: [String] = [], titles: [String] = []) {
        self.apps = apps
        self.urls = urls
        self.titles = titles
    }
    func appIsDenied(bundleId: String) -> Bool { apps.contains(bundleId) }
    func urlIsDenied(_ url: String) -> Bool { urls.contains(where: { url.hasPrefix($0) }) }
    func windowTitleIsDenied(_ title: String) -> Bool {
        titles.contains(where: { title.contains($0) })
    }
}
private struct NoBlack: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private actor RecordingSink: FrameSink {
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func count() -> Int { writes.count }
    func lastWrite() -> Data? { writes.last }
}

private actor SpyEncoder: FrameEncoder {
    private(set) var calls: [UInt64] = []
    func encodeAllowedFrame(
        input _: EncoderInput?,
        seq: UInt64,
        context _: WorkflowContext
    ) async throws {
        calls.append(seq)
    }
    func callCount() -> Int { calls.count }
}

private final class SpyReleaser: SurfaceReleasing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func releaseSurface() {
        lock.lock(); n += 1; lock.unlock()
    }
    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }; return n
    }
}

/// Stub URL provider that returns `value` for `answersFor` and `nil`
/// for everything else. Mirrors the pattern in URLProviderStubTests
/// but kept local so this file is self-contained.
private struct StubURLProvider: URLProvider {
    let answersFor: String
    let value: String?
    func activeTabURL(forFrontmost bundleId: String) -> String? {
        bundleId == answersFor ? value : nil
    }
}

private func forwardingFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: false,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0),
        priorDhash: nil
    )
}

private func makePipeline(
    cascade: SuppressionCascade,
    encoder: any FrameEncoder,
    sink: any FrameSink
) -> SCStreamPipeline {
    SCStreamPipeline(cascade: cascade, encoder: encoder, sink: sink)
}

/// Helper: build a snapshot already populated with `ctx`. The actor
/// `store(_:)` is async; we await it here so the test driver has a
/// deterministic "snapshot is populated" precondition.
private func populatedSnapshot(_ ctx: WorkflowContext) async -> WorkflowContextSnapshot {
    let snap = WorkflowContextSnapshot()
    await snap.store(ctx)
    return snap
}

final class CascadeContextWireTests: XCTestCase {
    // MARK: - (1) Pure context-build matrix

    /// Snapshot present, populated with a non-empty bundleId, URL
    /// provider returns a value for that bundleId ⇒ assembled
    /// context carries all three populated fields.
    func test_buildWorkflowContext_populates_appBundleId_windowTitle_url_when_snapshot_and_provider_have_values() async {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: "Inbox — Mail"
        ))
        let url = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://example.com/page"
        )

        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: url,
            fallbackAppBundleId: nil
        )

        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertEqual(ctx.windowTitle, "Inbox — Mail")
        XCTAssertEqual(ctx.url, "https://example.com/page")
        XCTAssertNil(ctx.pageText, "Phase 3 (OCR) populates pageText, not this PR")
    }

    /// Snapshot absent (legacy / headless construction without P2.5
    /// wiring) ⇒ context falls back to the all-nil shape. Pre-P2.5
    /// behaviour byte-for-byte; the cascade treats it as "unknown
    /// app" → fail-closed under §7. Pins the back-compat path so a
    /// future construction that forgets to wire the snapshot does
    /// not silently regress to widening `.allow`.
    func test_buildWorkflowContext_falls_back_to_all_nil_when_snapshot_absent() {
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: nil,
            urlProvider: nil,
            fallbackAppBundleId: nil
        )
        XCTAssertNil(ctx.appBundleId)
        XCTAssertNil(ctx.windowTitle)
        XCTAssertNil(ctx.url)
        XCTAssertNil(ctx.pageText)
    }

    /// Snapshot present but bundleId nil (no frontmost app — login
    /// window / fast-user-switch transition) ⇒ URL provider is NOT
    /// invoked (would be a wasted call against an empty bundleId
    /// the composite cannot dispatch on); context carries
    /// `url == nil`. This pins the short-circuit: a brittle URL
    /// provider should never see an empty bundleId.
    func test_buildWorkflowContext_skips_url_provider_when_snapshot_bundleId_is_nil() async {
        let snap = await populatedSnapshot(WorkflowContext())
        // The stub would return its configured value only for the
        // exact bundleId; an empty/nil bundleId must never be
        // dispatched to it. We assert by giving the stub a value
        // for `""` to prove the production path never asks for it.
        let url = StubURLProvider(answersFor: "", value: "https://leak-canary/")

        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: url,
            fallbackAppBundleId: nil
        )

        XCTAssertNil(ctx.appBundleId)
        XCTAssertNil(ctx.windowTitle)
        XCTAssertNil(
            ctx.url,
            "URL provider MUST NOT be invoked with an empty bundleId"
        )
    }

    /// Snapshot present + populated bundleId, but URL provider is
    /// absent (a deployment that has not wired a composite) ⇒
    /// context still carries the bundleId + title from the snapshot;
    /// `url` is nil. Pins that the URL leg is independently failable
    /// — the snapshot is the source of truth for app+title.
    func test_buildWorkflowContext_returns_snapshot_fields_when_url_provider_absent() async {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.unknown.app",
            windowTitle: "Untitled"
        ))
        let ctx = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: nil,
            fallbackAppBundleId: nil
        )
        XCTAssertEqual(ctx.appBundleId, "com.unknown.app")
        XCTAssertEqual(ctx.windowTitle, "Untitled")
        XCTAssertNil(ctx.url)
    }

    // MARK: - (2) Cascade §1 source-level denylist fires for the first
    //         time on a populated bundleId

    /// **THE PR'S HEADLINE INVARIANT.** Before P2.5, ADR-0013 cascade
    /// §1 was structurally dead: `appBundleId == nil` at every
    /// callback. This test feeds a denylisted bundleId through the
    /// new context-build helper and asserts the pipeline returns
    /// `.suppress(reason: .denylistSource)` — `reason=1`.
    ///
    /// The test is built so the *only* reason the cascade can resolve
    /// to `.suppress(reason: .denylistSource)` is via the new wiring:
    ///   - SmartCaptureFilter forwards the frame (forwardingFrame()).
    ///   - SuppressionCascade decision is driven purely by `context`.
    ///   - The context's `appBundleId` comes from the
    ///     `WorkflowContextSnapshot` we just populated — i.e. the
    ///     P2.5 source.
    /// On regression (someone reverts the new helper to all-nil) the
    /// cascade would fall through to §7 (`.failsafeUnknown`,
    /// `reason=7`) and this assertion would fail loudly.
    func test_p25_cascade_section1_denylist_source_fires_on_populated_bundleId() async throws {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.secret.app"
        ))
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: nil,
            fallbackAppBundleId: nil
        )

        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(apps: ["com.secret.app"]),
            blackedRegion: NoBlack()
        )
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let pipe = makePipeline(cascade: cascade, encoder: encoder, sink: sink)

        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )

        XCTAssertEqual(
            outcome,
            .suppressed(reason: .denylistSource, forcedByFloor: false),
            """
            ADR-0013 cascade §1 (source-level denylist) MUST fire when \
            the populated bundleId from the WorkflowContextSnapshot \
            matches a denylist app entry. This is the cascade leg \
            P2.5 makes operationally meaningful for the first time. \
            If this fails, the new SCStreamCaptureSession context \
            wiring has regressed.
            """
        )
        let enc = await encoder.callCount()
        XCTAssertEqual(enc, 0, "encoder MUST NOT run on a §1-suppressed frame")
        let writes = await sink.count()
        XCTAssertEqual(writes, 1, "exactly one PrivacyTombstone written on .suppress")
    }

    /// Snapshot still nil ⇒ cascade falls through to §7 fail-safe
    /// (`reason=7`). Documents the WHY of the regression-test above:
    /// the §1 leg only fires because P2.5 made bundleIds reachable.
    /// Removing the new helper would surface here.
    func test_p25_cascade_falls_to_section7_when_snapshot_is_empty() async throws {
        let snap = await populatedSnapshot(WorkflowContext())
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: nil,
            fallbackAppBundleId: nil
        )

        // Even if the denylist contains the bundleId we *wish* were
        // frontmost, §1 cannot fire on a nil bundleId.
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXSilent(),
            denylist: DenyApps(apps: ["com.secret.app"]),
            blackedRegion: NoBlack()
        )
        let pipe = makePipeline(
            cascade: cascade, encoder: SpyEncoder(), sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        XCTAssertEqual(
            outcome,
            .suppressed(reason: .failsafeUnknown, forcedByFloor: false),
            "nil bundleId ⇒ §1 cannot match ⇒ cascade falls to §7 fail-safe"
        )
    }

    /// §1 URL leg: a denylisted URL prefix returned by the URL
    /// provider for the frontmost bundleId fires `reason=1`. Pins
    /// the URL→cascade path the composite URL provider feeds.
    func test_p25_cascade_section1_denylist_source_fires_on_populated_url() async throws {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.apple.Safari"
        ))
        let url = StubURLProvider(
            answersFor: "com.apple.Safari",
            value: "https://accounts.google.com/signin"
        )
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: url,
            fallbackAppBundleId: nil
        )
        XCTAssertEqual(cascadeContext.url, "https://accounts.google.com/signin")

        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(
                urls: ["https://accounts.google.com/"]
            ),
            blackedRegion: NoBlack()
        )
        let pipe = makePipeline(
            cascade: cascade, encoder: SpyEncoder(), sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        XCTAssertEqual(
            outcome,
            .suppressed(reason: .denylistSource, forcedByFloor: false),
            "URL-leg of §1 must fire when a populated URL matches a denylist prefix"
        )
    }

    /// §1 window-title leg: a denylisted window-title substring from
    /// the snapshot fires `reason=1`. Pins the windowTitle→cascade
    /// path the AXWindowTitleProvider feeds.
    func test_p25_cascade_section1_denylist_source_fires_on_populated_windowTitle() async throws {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.apple.Notes",
            windowTitle: "Untitled — confidential draft Q3"
        ))
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap,
            urlProvider: nil,
            fallbackAppBundleId: nil
        )
        XCTAssertEqual(cascadeContext.windowTitle, "Untitled — confidential draft Q3")

        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(titles: ["confidential"]),
            blackedRegion: NoBlack()
        )
        let pipe = makePipeline(
            cascade: cascade, encoder: SpyEncoder(), sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        XCTAssertEqual(
            outcome,
            .suppressed(reason: .denylistSource, forcedByFloor: false),
            "windowTitle leg of §1 must fire when a populated title matches a denylist substring"
        )
    }

    // MARK: - (3) PrivacyTombstone payload carries real appBundleId

    /// End-to-end: drive the pipeline with a populated bundleId on
    /// the suppress path; decode the bytes the sink received; assert
    /// the `app_bundle` field carries the bundleId STRING, not the
    /// pre-P2.5 empty string. This is what makes recall-UI privacy
    /// moments (ADR-0013 §4) specific — "MCI redacted this because
    /// 1Password was frontmost" — instead of generic.
    ///
    /// The wire format is `magic(1) ver(1) msg_type(2) seq(8)
    /// len(4) | ts_us(8) app_bundle_len(2) app_bundle(N) reason(1)`.
    /// We pull `app_bundle` out by length-prefix and assert it
    /// equals the bundleId we fed in.
    func test_p25_privacyTombstone_payload_carries_real_appBundleId() async throws {
        let snap = await populatedSnapshot(WorkflowContext(
            appBundleId: "com.1password.7"
        ))
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap, urlProvider: nil, fallbackAppBundleId: nil
        )

        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: DenyApps(apps: ["com.1password.7"]),
            blackedRegion: NoBlack()
        )
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let pipe = makePipeline(cascade: cascade, encoder: encoder, sink: sink)

        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 0xDEAD_BEEF,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        XCTAssertEqual(outcome, .suppressed(reason: .denylistSource, forcedByFloor: false))

        guard let frame = await sink.lastWrite() else {
            return XCTFail("sink received no tombstone bytes")
        }
        // Header is `minFrameHeaderBytes` (16). Payload starts there.
        XCTAssertGreaterThan(frame.count, minFrameHeaderBytes + 8 + 2,
                             "frame must include at least the ts + bundleId-length prefix")
        let payloadStart = minFrameHeaderBytes
        // Skip ts_us (8 bytes).
        let bundleLenOff = payloadStart + 8
        let bundleLen = UInt16(frame[bundleLenOff])
            | (UInt16(frame[bundleLenOff + 1]) << 8)
        XCTAssertEqual(
            Int(bundleLen), "com.1password.7".utf8.count,
            "app_bundle length prefix MUST equal the bundleId byte length"
        )
        let bundleBytes = frame[(bundleLenOff + 2)..<(bundleLenOff + 2 + Int(bundleLen))]
        let bundleString = String(data: Data(bundleBytes), encoding: .utf8)
        XCTAssertEqual(
            bundleString, "com.1password.7",
            """
            PrivacyTombstone.appBundle MUST carry the real bundleId, \
            not the empty string. ADR-0015 §4 invariant 3 + ADR-0013 §4 \
            recall-UI privacy-moment specificity. Before P2.5 this \
            field always carried '' because the cascade input had nil; \
            P2.5 is the moment it starts carrying real values.
            """
        )
        // Reason byte is the very last byte of the frame.
        XCTAssertEqual(frame.last, RedactionReason.denylistSource.rawValue)
    }

    /// Regression-pin the pre-P2.5 wire shape: when the snapshot is
    /// empty (no frontmost app), the tombstone still encodes with a
    /// 0-length `app_bundle`. Documents that the wire format
    /// degrades cleanly when context is unknown — no crash, no
    /// negative length, no UTF-8 corruption. Important because the
    /// snapshot's all-nil initial state is reachable on every helper
    /// startup before the 1 Hz poller has ticked.
    func test_p25_privacyTombstone_payload_handles_nil_appBundleId_cleanly() async throws {
        let snap = await populatedSnapshot(WorkflowContext())
        let cascadeContext = SCStreamCaptureSession.buildWorkflowContext(
            snapshot: snap, urlProvider: nil, fallbackAppBundleId: nil
        )
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXSilent(), // forces §7 fail-safe
            denylist: DenyApps(),
            blackedRegion: NoBlack()
        )
        let sink = RecordingSink()
        let pipe = makePipeline(cascade: cascade, encoder: SpyEncoder(), sink: sink)
        _ = try await pipe.process(
            frame: forwardingFrame(),
            context: cascadeContext,
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        guard let frame = await sink.lastWrite() else {
            return XCTFail("sink received no tombstone bytes")
        }
        let bundleLenOff = minFrameHeaderBytes + 8
        let bundleLen = UInt16(frame[bundleLenOff])
            | (UInt16(frame[bundleLenOff + 1]) << 8)
        XCTAssertEqual(
            bundleLen, 0,
            "nil bundleId encodes as an empty string (length-prefix 0), not as garbage"
        )
        XCTAssertEqual(frame.last, RedactionReason.failsafeUnknown.rawValue)
    }
}
