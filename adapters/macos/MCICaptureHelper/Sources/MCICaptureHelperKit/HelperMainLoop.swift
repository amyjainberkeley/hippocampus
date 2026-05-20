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

    /// Snapshot in the shape `Wire.encodeHelperHealth` consumes.
    ///
    /// `cascadeForced` is surfaced on the wire by the 0x02 → 0x03 bump
    /// (STEP-2-FINDING-004). `cascadeFromFilter` stays in-process only
    /// — see its field docs.
    public func snapshot(now: Date = Date()) -> HelperHealthSnapshot {
        let uptimeMs = UInt64(max(0, now.timeIntervalSince(startedAt) * 1000))
        return HelperHealthSnapshot(
            uptimeMs: uptimeMs,
            framesDelivered: framesDelivered,
            framesSuppressed: framesSuppressed,
            framesRedactedByFailsafe: framesRedactedByFailsafe,
            framesDroppedBackpressure: framesDroppedBackpressure,
            framesDroppedLateAck: framesDroppedLateAck,
            cascadeFromFilter: cascadeFromFilter,
            cascadeForced: cascadeForced
        )
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

    public init(
        uptimeMs: UInt64,
        framesDelivered: UInt64,
        framesSuppressed: UInt64,
        framesRedactedByFailsafe: UInt64,
        framesDroppedBackpressure: UInt64,
        framesDroppedLateAck: UInt64,
        cascadeFromFilter: UInt64 = 0,
        cascadeForced: UInt64 = 0
    ) {
        self.uptimeMs = uptimeMs
        self.framesDelivered = framesDelivered
        self.framesSuppressed = framesSuppressed
        self.framesRedactedByFailsafe = framesRedactedByFailsafe
        self.framesDroppedBackpressure = framesDroppedBackpressure
        self.framesDroppedLateAck = framesDroppedLateAck
        self.cascadeFromFilter = cascadeFromFilter
        self.cascadeForced = cascadeForced
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
            framesDroppedLateAck: snap.framesDroppedLateAck
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
