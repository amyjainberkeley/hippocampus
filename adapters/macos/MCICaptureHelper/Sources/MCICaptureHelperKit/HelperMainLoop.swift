// SPDX-License-Identifier: TBD-private
//
// HelperMainLoop — the helper-process top-level event loop.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. This is what the production
// `mci-capture-helper` binary calls into from main.swift. The loop
// holds the per-process state the cascade + IPC writer share:
//
//   - the ADR-0013 SuppressionCascade orchestrator (with whichever
//     probes the caller injected — concrete in production, mocked
//     in tests)
//   - the running helper-health counters
//   - the outbound `FrameSink` that receives encoded IPC frames
//   - a `Clock`-driven heartbeat that emits HelperHealth every 30 s
//
// Phase-1 cycle 3 wires the inbound `FrameReader`-equivalent that
// drives the cascade from real SCStream callbacks; this iteration is
// the scaffold that produces a runnable binary + lets tests drive the
// cascade end-to-end via synthetic inputs.

import Foundation

/// Outbound byte-sink the helper writes encoded IPC frames into.
///
/// In production this is a `FileHandle` wrapping the `AF_UNIX` socket
/// the Rust core supplied at launch. In tests it's a `Pipe`-backed
/// adapter so the test can inspect the bytes.
public protocol FrameSink: Sendable {
    /// Append `data` to the sink. Returns when the bytes are flushed
    /// to the underlying transport (or buffered, if the transport is
    /// non-blocking — the helper does NOT impose flush semantics).
    func write(_ data: Data) async throws
}

/// Mutable counters the helper reports periodically via `HelperHealth`.
///
/// `actor` because every `decide()` + `tick()` call mutates it from
/// potentially different tasks (cascade callback thread, heartbeat
/// timer task, control-channel task). Swift Concurrency keeps the
/// mutation sequenced; tests assert via `snapshot()`.
public actor HelperHealthCounters {
    private var startedAt: Date
    private var framesDelivered: UInt64 = 0
    private var framesSuppressed: UInt64 = 0
    private var framesRedactedByFailsafe: UInt64 = 0
    private var framesDroppedBackpressure: UInt64 = 0
    private var framesDroppedLateAck: UInt64 = 0
    /// Cascade evaluations that ran because the `SmartCaptureFilter`
    /// returned `.forward` / `.forwardTieBreak` (the natural path).
    /// In-process observability for the floor-vs-filter ratio; NOT
    /// surfaced on the wire (only its disjoint counterpart
    /// `cascadeForced` was promoted to the wire by the 0x02 → 0x03
    /// bump — the floor counter is the privacy-relevant signal for
    /// the Telemetry-Gap analyst on static secure surfaces).
    private var cascadeFromFilter: UInt64 = 0
    /// Cascade evaluations forced by the cascade floor — the filter
    /// returned a `.drop*` decision but the wall-clock since the last
    /// cascade run reached `cascadeFloorIntervalMs`, so the pipeline
    /// ran the cascade anyway. The whole point of the STEP-2-FINDING-004
    /// fix: under a static secure surface (FairPlay, sudo password
    /// entry, secure-field focus) the filter eats every frame; this
    /// counter is how the wire observer notices that the floor is
    /// doing what the filter cannot. Surfaced on the wire as
    /// `HelperHealth.cascade_forced_count` after the 0x02 → 0x03 bump.
    private var cascadeForced: UInt64 = 0
    /// Cascade-allowed frames on which the VideoToolbox HEVC encoder
    /// threw on `encodeAllowedFrame(...)`. Promoted to the wire by the
    /// 0x06 → 0x07 bump (ocr-emit-silence regression fix —
    /// `docs/research/ocr-emit-silence-2026-05-28.md`). Content-free
    /// counter (same discipline as `framesRedactedByFailsafe`); the
    /// signal is observability-only and never gates `.allow` /
    /// `.suppress`. Incremented by `SCStreamPipeline.process(...)` in
    /// the `.allow` branch's catch arm; OCR emission still fires after
    /// the catch because the cascade — not encode-success — is what
    /// gates emission per ADR-0016 §4.2.
    private var framesEncoderFailed: UInt64 = 0
    /// ADR-0031 §5.3 race-consistency gate counter — frames where the
    /// `FocusedWindowStore.generation` observed at callback time did
    /// NOT match the `installedFocusGeneration` the live SCStream's
    /// `SCContentFilter` was rebound under. Such frames are dropped
    /// with a `PrivacyTombstone(reason=focusRaceDropped)` instead of
    /// running the cascade-twice OCR emitter — fail-closed per
    /// ADR-0013 §3 + Amendment 1 §3(b). Promoted to the wire by the
    /// 0x07 → 0x08 bump (V2-P1 / ADR-0031). Content-free counter (same
    /// discipline as `framesRedactedByFailsafe` /
    /// `framesEncoderFailed`); never widens `.allow`.
    private var framesFocusRaceDropped: UInt64 = 0
    /// Per-app `.failsafeUnknown` tombstone counter map (PR #226 §5.1
    /// (1) + Phase 6 PR 6). Stored as an ordered array, most-recently-
    /// bumped entry first; cap at [`maxFailsafeByAppEntries`] = 8 via
    /// least-recent-bump eviction. The order is the LRU state — when
    /// `recordFailsafeByApp(bundleId:)` increments an existing entry,
    /// that entry moves to the front; when a new entry is added and the
    /// array is at cap, the tail entry is evicted. Content-free —
    /// bundle ids only; never OCR text / window title / URL.
    /// Resets on helper restart (cumulative-within-process). Promoted
    /// to the wire by the 0x08 → 0x09 bump.
    private var failsafeByApp: [FailsafeAppCounter] = []
    /// Footprint sampler — produces (cpuPctMicro, rssBytes) on each
    /// `snapshot()` call. Lazily initialized at first snapshot so a
    /// test that does not call snapshot() never pays the sampler cost.
    /// Optional so test constructions can substitute a stub. Pairs with
    /// the MetricKit subscriber (separate dispatch deliverable) for
    /// finer-than-daily-aggregate per-flush CPU + RSS observability
    /// against the G2-ratified ≤10-15% / ≤2 GB SLOs.
    private var footprintSampler: FootprintSampler?

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    public func recordDelivered() { framesDelivered &+= 1 }
    public func recordSuppressed() { framesSuppressed &+= 1 }
    /// The §7 fail-safe subcount. Incremented IN ADDITION TO
    /// `recordSuppressed()` when (and only when) the cascade
    /// suppressed via `.failsafeUnknown` — it is a subset of
    /// `framesSuppressed`, never an alternative to it.
    public func recordRedactedByFailsafe() { framesRedactedByFailsafe &+= 1 }
    public func recordBackpressureDrop() { framesDroppedBackpressure &+= 1 }
    public func recordLateAckDrop() { framesDroppedLateAck &+= 1 }
    /// Record one filter-passed cascade evaluation. Called by
    /// `SCStreamPipeline.process(...)` when the filter returned
    /// `.forward` / `.forwardTieBreak` and the cascade was therefore
    /// consulted.
    public func recordCascadeFromFilter() { cascadeFromFilter &+= 1 }
    /// Record one floor-forced cascade evaluation. Called by
    /// `SCStreamPipeline.process(...)` when the filter returned a
    /// `.drop*` decision but the cascade-floor interval had elapsed,
    /// so the cascade was consulted anyway. Strictly disjoint from
    /// `cascadeFromFilter` — a single `process()` call increments
    /// exactly one of the two counters whenever the cascade runs.
    public func recordCascadeForced() { cascadeForced &+= 1 }
    /// Record one VideoToolbox HEVC encode failure on the `.allow`
    /// branch. Called by `SCStreamPipeline.process(...)` when the
    /// injected `FrameEncoder.encodeAllowedFrame(...)` throws.
    /// Observability-only — the cascade decision is what gates OCR
    /// emission per ADR-0016 §4.2; this counter records the encoder
    /// outcome on the content-free wire so a regression here cannot
    /// silently mute the brain again.
    public func recordEncodeFailed() { framesEncoderFailed &+= 1 }
    /// Record one ADR-0031 §5.3 race-consistency-gate drop. Called by
    /// `SCStreamCaptureSession` when the focus generation observed at
    /// callback time did NOT match the generation the live SCStream's
    /// filter was rebound under. The frame is dropped with a
    /// `focusRaceDropped` tombstone instead of running the cascade-
    /// twice OCR emitter — fail-closed per ADR-0013 §3 + Amendment 1
    /// §3(b). Observability-only — never widens `.allow`. Surfaced on
    /// the wire by the 0x07 → 0x08 bump.
    public func recordFocusRaceDropped() { framesFocusRaceDropped &+= 1 }

    /// Record one `.failsafeUnknown` tombstone emission attributed to
    /// `bundleId`. Promoted to the wire by the 0x08 → 0x09 bump (PR
    /// #226 §5.1 (1) + Phase 6 PR 6) — the per-app cascade-silence
    /// attribution counter map. Bumps an existing entry (and moves it
    /// to the front of the LRU array) OR adds a new entry at the
    /// front, evicting the tail entry if the array is at
    /// [`maxFailsafeByAppEntries`] = 8. Empty `bundleId` is recorded
    /// as the literal empty string "" — context with no bundle id
    /// (e.g. a stub context from a smoke test) still surfaces as one
    /// cap entry, never silently dropped.
    public func recordFailsafeByApp(bundleId: String) {
        // Search for existing entry. Linear scan is fine at cap 8.
        if let idx = failsafeByApp.firstIndex(where: { $0.bundleId == bundleId }) {
            let existing = failsafeByApp.remove(at: idx)
            failsafeByApp.insert(
                FailsafeAppCounter(
                    bundleId: existing.bundleId,
                    counter: existing.counter &+ 1
                ),
                at: 0
            )
        } else {
            failsafeByApp.insert(FailsafeAppCounter(bundleId: bundleId, counter: 1), at: 0)
            if failsafeByApp.count > maxFailsafeByAppEntries {
                // Least-recent-bump eviction — drop the tail (the
                // entry that has gone the longest without a bump).
                failsafeByApp.removeLast(failsafeByApp.count - maxFailsafeByAppEntries)
            }
        }
    }

    /// Inject a footprint sampler (CPU% + RSS) for the wire-0x09
    /// `cpu_pct_micro` / `rss_bytes` fields. Optional — production
    /// `main.swift` installs `MachFootprintSampler`; headless tests
    /// can install a `StubFootprintSampler` to drive deterministic
    /// counter values. When unset, `snapshot()` reports both as 0
    /// (sentinel = "sampler unavailable", same convention as the wire
    /// decoder default).
    public func installFootprintSampler(_ sampler: FootprintSampler) {
        self.footprintSampler = sampler
    }

    /// Snapshot in the shape `Wire.encodeHelperHealth` consumes.
    ///
    /// `cascadeForced` is surfaced on the wire by the 0x02 → 0x03 bump
    /// (STEP-2-FINDING-004). `framesEncoderFailed` is surfaced on the
    /// wire by the 0x06 → 0x07 bump (ocr-emit-silence fix).
    /// `framesFocusRaceDropped` is surfaced on the wire by the
    /// 0x07 → 0x08 bump (ADR-0031 V2-P1). `failsafeByApp`,
    /// `cpuPctMicro`, `rssBytes`, `trackerAliveAtUs` are surfaced on
    /// the wire by the 0x08 → 0x09 bump (Phase 6 PR 6, PR #226 §5.1).
    /// `cascadeFromFilter` stays in-process only — see its field docs.
    public func snapshot(now: Date = Date()) -> HelperHealthSnapshot {
        let uptimeMs = UInt64(max(0, now.timeIntervalSince(startedAt) * 1000))
        // Take a footprint sample if a sampler is installed. The
        // sampler implementation owns sampling cadence + delta
        // accumulation; we just ask for the current reading.
        let footprint: FootprintReading
        if let sampler = footprintSampler {
            footprint = sampler.sample(now: now)
        } else {
            // Sentinel: 0 / 0 — same default as the wire decoder
            // applies on a 0x08-era legacy frame.
            footprint = FootprintReading(cpuPctMicro: 0, rssBytes: 0)
        }
        return HelperHealthSnapshot(
            uptimeMs: uptimeMs,
            framesDelivered: framesDelivered,
            framesSuppressed: framesSuppressed,
            framesRedactedByFailsafe: framesRedactedByFailsafe,
            framesDroppedBackpressure: framesDroppedBackpressure,
            framesDroppedLateAck: framesDroppedLateAck,
            cascadeFromFilter: cascadeFromFilter,
            cascadeForced: cascadeForced,
            framesEncoderFailed: framesEncoderFailed,
            framesFocusRaceDropped: framesFocusRaceDropped,
            failsafeByApp: failsafeByApp,
            cpuPctMicro: footprint.cpuPctMicro,
            rssBytes: footprint.rssBytes,
            // V2-P1 PR 13 will install a real tracker and replace the
            // sentinel 0 with the AX-focus-tracker heartbeat ts. This
            // PR ships the slot at 0.
            trackerAliveAtUs: 0
        )
    }
}

/// One entry in the wire-0x09 `failsafe_by_app` counter map.
/// Dedicated struct (rather than a `(String, UInt64)` tuple) so the
/// `HelperHealthSnapshot` can `Equatable`-synthesize without manual
/// `==`. Sendable + Equatable trivially derive.
public struct FailsafeAppCounter: Sendable, Equatable {
    /// App bundle id the `.failsafeUnknown` tombstone(s) were
    /// attributed to. Content-free under the cap-8 LRU discipline.
    public let bundleId: String
    /// Cumulative `.failsafeUnknown` tombstone count for `bundleId`
    /// since helper start.
    public let counter: UInt64
    public init(bundleId: String, counter: UInt64) {
        self.bundleId = bundleId
        self.counter = counter
    }
}

/// Plain-data snapshot of the counters. `Sendable` so it can cross
/// task boundaries cheaply.
public struct HelperHealthSnapshot: Sendable, Equatable {
    public let uptimeMs: UInt64
    public let framesDelivered: UInt64
    public let framesSuppressed: UInt64
    public let framesRedactedByFailsafe: UInt64
    public let framesDroppedBackpressure: UInt64
    public let framesDroppedLateAck: UInt64
    /// Filter-passed cascade evaluations. In-process only — see
    /// `HelperHealthCounters.cascadeFromFilter`.
    public let cascadeFromFilter: UInt64
    /// Floor-forced cascade evaluations. Surfaced on the wire as
    /// `HelperHealth.cascade_forced_count` after the 0x02 → 0x03 bump
    /// (STEP-2-FINDING-004). See `HelperHealthCounters.cascadeForced`.
    public let cascadeForced: UInt64
    /// VideoToolbox HEVC encode failures on the `.allow` branch.
    /// Surfaced on the wire as `HelperHealth.frames_encode_failed` after
    /// the 0x06 → 0x07 bump (ocr-emit-silence fix —
    /// `docs/research/ocr-emit-silence-2026-05-28.md`). See
    /// `HelperHealthCounters.framesEncoderFailed`.
    public let framesEncoderFailed: UInt64
    /// ADR-0031 §5.3 race-consistency-gate drops. Surfaced on the wire
    /// as `HelperHealth.frames_focus_race_dropped` after the 0x07 → 0x08
    /// bump (V2-P1 / ADR-0031). See
    /// `HelperHealthCounters.framesFocusRaceDropped`.
    public let framesFocusRaceDropped: UInt64
    /// Per-app `.failsafeUnknown` tombstone counter map, ordered most-
    /// recently-bumped first, cap [`maxFailsafeByAppEntries`] = 8.
    /// Surfaced on the wire as `HelperHealth.failsafe_by_app` after
    /// the 0x08 → 0x09 bump (Phase 6 PR 6 / PR #226 §5.1 (1)).
    /// Content-free — bundle ids only.
    public let failsafeByApp: [FailsafeAppCounter]
    /// Instantaneous CPU sample microfraction (1_000_000 = 100% of
    /// one core). 0 = sampler unavailable. Surfaced on the wire as
    /// `HelperHealth.cpu_pct_micro` after the 0x08 → 0x09 bump.
    public let cpuPctMicro: UInt32
    /// Instantaneous resident set size in bytes. 0 = sampler failed.
    /// Surfaced on the wire as `HelperHealth.rss_bytes` after the
    /// 0x08 → 0x09 bump.
    public let rssBytes: UInt64
    /// Reserved slot for V2-P1 PR 13 AX-focus-tracker heartbeat.
    /// 0 = sentinel until PR 13. Surfaced on the wire as
    /// `HelperHealth.tracker_alive_at_us` after the 0x08 → 0x09 bump.
    public let trackerAliveAtUs: UInt64

    public init(
        uptimeMs: UInt64,
        framesDelivered: UInt64,
        framesSuppressed: UInt64,
        framesRedactedByFailsafe: UInt64,
        framesDroppedBackpressure: UInt64,
        framesDroppedLateAck: UInt64,
        cascadeFromFilter: UInt64 = 0,
        cascadeForced: UInt64 = 0,
        framesEncoderFailed: UInt64 = 0,
        framesFocusRaceDropped: UInt64 = 0,
        failsafeByApp: [FailsafeAppCounter] = [],
        cpuPctMicro: UInt32 = 0,
        rssBytes: UInt64 = 0,
        trackerAliveAtUs: UInt64 = 0
    ) {
        self.uptimeMs = uptimeMs
        self.framesDelivered = framesDelivered
        self.framesSuppressed = framesSuppressed
        self.framesRedactedByFailsafe = framesRedactedByFailsafe
        self.framesDroppedBackpressure = framesDroppedBackpressure
        self.framesDroppedLateAck = framesDroppedLateAck
        self.cascadeFromFilter = cascadeFromFilter
        self.cascadeForced = cascadeForced
        self.framesEncoderFailed = framesEncoderFailed
        self.framesFocusRaceDropped = framesFocusRaceDropped
        self.failsafeByApp = failsafeByApp
        self.cpuPctMicro = cpuPctMicro
        self.rssBytes = rssBytes
        self.trackerAliveAtUs = trackerAliveAtUs
    }
}

/// Monotonic sequence allocator for outbound frames. Mirrors the
/// Rust `core::ipc::writer::FrameWriter` counter.
public actor FrameSequence {
    private var next: UInt64

    public init(startingAt: UInt64 = 0) {
        self.next = startingAt
    }

    public func allocate() -> UInt64 {
        let seq = next
        next &+= 1
        return seq
    }

    public func current() -> UInt64 { next }
}

/// The helper's top-level event loop.
///
/// Production usage (from `main.swift`):
///
///     let cascade = SuppressionCascade(
///         secureEventInput: CarbonSecureEventInputProbe(),
///         axSecureSubrole: AXSubroleProbe(),
///         denylist: Denylist(entries: try loader.parse(tomlText)),
///         blackedRegion: ProductionBlackedRegionProbe(), // cycle 3
///         knownSafeAppBundles: []
///     )
///     let loop = HelperMainLoop(
///         cascade: cascade,
///         sink: FileHandleFrameSink(handle: socketFileHandle),
///         heartbeatInterval: .seconds(30)
///     )
///     try await loop.run()
public struct HelperMainLoop: Sendable {
    public let cascade: SuppressionCascade
    public let sink: any FrameSink
    public let counters: HelperHealthCounters
    public let sequence: FrameSequence
    public let heartbeatInterval: Duration

    public init(
        cascade: SuppressionCascade,
        sink: any FrameSink,
        counters: HelperHealthCounters = HelperHealthCounters(),
        sequence: FrameSequence = FrameSequence(),
        heartbeatInterval: Duration = .seconds(30)
    ) {
        self.cascade = cascade
        self.sink = sink
        self.counters = counters
        self.sequence = sequence
        self.heartbeatInterval = heartbeatInterval
    }

    /// Process one synthetic state transition through the cascade and
    /// emit either a `PrivacyTombstone` or — in production cycle 3+ —
    /// a `StateTransitionEvent` (this iteration only handles the
    /// suppression path; live frames land cycle 3).
    ///
    /// Returns the cascade decision so callers + tests can assert it.
    public func processSyntheticTransition(
        nowUs: UInt64,
        context: WorkflowContext
    ) async throws -> SuppressionDecision {
        await counters.recordDelivered()
        let decision = cascade.decide(context: context)
        switch decision {
        case .allow:
            // Cycle-3 work: encode + send the StateTransitionEvent
            // with the surface fd via SCM_RIGHTS. For now we just
            // count it.
            break
        case .suppress(let reason):
            await counters.recordSuppressed()
            if reason == .failsafeUnknown {
                // §7 fail-safe subcount — a strict subset of
                // framesSuppressed; the CRS Telemetry-Gap privacy-
                // regression sentinel.
                await counters.recordRedactedByFailsafe()
                // Phase 6 PR 6 — per-app cascade-silence attribution
                // (PR #226 §5.1 (1)). The cap-8 LRU is enforced
                // inside `recordFailsafeByApp`.
                await counters.recordFailsafeByApp(bundleId: context.appBundleId ?? "")
            }
            try await emitTombstone(
                tsUs: nowUs,
                appBundle: context.appBundleId ?? "",
                reason: reason
            )
        }
        return decision
    }

    /// Encode + send one `HelperHealth` frame.
    public func tickHealth() async throws {
        let snap = await counters.snapshot()
        let seq = await sequence.allocate()
        let bytes = encodeHelperHealth(
            seq: seq,
            uptimeMs: snap.uptimeMs,
            framesDelivered: snap.framesDelivered,
            framesSuppressed: snap.framesSuppressed,
            framesRedactedByFailsafe: snap.framesRedactedByFailsafe,
            // STEP-2-FINDING-004 floor-forced cascade counter — wire
            // 0x03. Sourced from the in-process counter incremented
            // by `SCStreamPipeline.process(...)` when the cascade ran
            // because the floor heartbeat elapsed (not because the
            // filter passed). Strictly disjoint from `cascadeFromFilter`.
            cascadeForcedCount: snap.cascadeForced,
            framesDroppedBackpressure: snap.framesDroppedBackpressure,
            framesDroppedLateAck: snap.framesDroppedLateAck,
            // ocr-emit-silence fix — wire 0x07. Sourced from the
            // in-process counter incremented by
            // `SCStreamPipeline.process(...)` on every VideoToolbox
            // HEVC encode throw on the `.allow` branch.
            framesEncodeFailed: snap.framesEncoderFailed,
            // ADR-0031 V2-P1 — wire 0x08. Sourced from the in-process
            // counter incremented by `SCStreamCaptureSession`'s race-
            // consistency gate when `FocusedWindowStore.generation`
            // mismatched `installedFocusGeneration` at SCStream callback
            // time. Content-free observability counter.
            framesFocusRaceDropped: snap.framesFocusRaceDropped,
            // Phase 6 PR 6 — wire 0x09 (PR #226 §5.1 + CTO §4 Phase 6
            // PR 6). Four trailing content-free fields. The cap-8 LRU
            // on `failsafeByApp` is enforced by
            // `HelperHealthCounters.recordFailsafeByApp(bundleId:)`;
            // `cpuPctMicro` + `rssBytes` come from the installed
            // `FootprintSampler` (or 0 sentinel if none installed);
            // `trackerAliveAtUs` ships at 0 (V2-P1 PR 13 populates
            // per the §6.2 = A + §8 coordination contract).
            failsafeByApp: snap.failsafeByApp,
            cpuPctMicro: snap.cpuPctMicro,
            rssBytes: snap.rssBytes,
            trackerAliveAtUs: snap.trackerAliveAtUs
        )
        try await sink.write(bytes)
    }

    /// Run the main loop until `Task.isCancelled` becomes true. Driven
    /// by the heartbeat clock — every `heartbeatInterval` it ticks a
    /// `HelperHealth` frame.
    ///
    /// Cycle 3 will add a second concurrent task that reads inbound
    /// `CaptureStart` / `CaptureStop` control + drives the cascade
    /// from the real `SCStream` callback. For now `run()` is just
    /// the heartbeat — the cascade is exercised via
    /// `processSyntheticTransition(...)` from external code.
    public func run() async throws {
        try await tickHealth() // emit one immediately at start
        while !Task.isCancelled {
            try await Task.sleep(for: heartbeatInterval)
            if Task.isCancelled { return }
            try await tickHealth()
        }
    }

    private func emitTombstone(
        tsUs: UInt64,
        appBundle: String,
        reason: RedactionReason
    ) async throws {
        let seq = await sequence.allocate()
        let bytes = encodePrivacyTombstone(
            seq: seq,
            tombstone: PrivacyTombstone(
                tsUs: tsUs,
                appBundle: appBundle,
                reason: reason
            )
        )
        try await sink.write(bytes)
    }
}
