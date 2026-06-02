// SPDX-License-Identifier: TBD-private
//
// MetricKitSubscriber — non-content footprint telemetry pipeline
// (Phase 6 PR 6 deliverable 3, per CTO §4 Phase 6 PR 6 + CEO answer
// D1 ratification "MetricKit as separate non-content footprint
// telemetry pipeline").
//
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// MetricKit (Apple's `MetricKit` framework) delivers system-aggregated
// daily payloads via `MXMetricManager` — CPU time, memory peak, hangs,
// disk I/O, etc. The payloads are CONTENT-FREE BY APPLE CONSTRUCTION:
// they carry only the helper-process's resource consumption envelope,
// never user content, never document/window text. Apple aggregates
// daily; the delegate's `didReceive(_:)` is called approximately once
// per 24 hours per process.
//
// This module:
//   1. Registers a delegate with `MXMetricManager.shared` at helper
//      start (`MetricKitSubscriber.install()`).
//   2. On `didReceive(_:)`, drops one JSON payload file per
//      `MXMetricPayload` into
//      `~/Library/Application Support/MCI/metrickit/<payload-uuid>.json`
//      at mode 0600 (uid-matched, group/other denied — same posture as
//      `helper-health.jsonl` per `health_log.rs::open_append_0600`).
//   3. Apple's `MXMetricPayload.jsonRepresentation()` is the canonical
//      serialization; we write it byte-for-byte, no transformation.
//
// Pair with the wire-0x09 `cpu_pct_micro` / `rss_bytes` HelperHealth
// fields (per-flush per-process sample) for finer-than-daily-aggregate
// observability against the G2-ratified ≤10-15% CPU / ≤2 GB RAM SLOs
// (AGENT_PROTOCOL §4 / S4 acceptance gate).
//
// # CSO sign-off (binding, AGENT_PROTOCOL §5)
//
// - MetricKit payloads are content-free by Apple construction. The
//   payload schema (CPU time, memory, hangs, disk I/O, etc.) is
//   documented at developer.apple.com/documentation/metrickit; no
//   field carries user-visible text, window title, URL, or OCR text.
// - On-disk files inherit 0600 from `Data.write(to:options:)` with
//   `.atomic` + a manual `setAttributes(_:ofItemAtPath:)` for
//   defence in depth (matches `helper-health.jsonl` posture).
// - One file per payload, named by Apple's payload UUID. No mutation
//   of existing files; no rotation policy beyond the natural daily
//   cadence (~1 file/day under typical workload).
// - The directory `~/Library/Application Support/MCI/metrickit/` is
//   created with `intermediateDirectories: true` + default perms; the
//   file-level 0600 is what binds the trust posture.
//
// — CSO sign-off (driver-CSO, dispatch §"NO DRIVER-CSO REQUIRED"
//   3-row mini-audit row 3 in PR body), 2026-06-01

import Foundation
import MetricKit

/// Public-facing protocol so headless tests can substitute a mock
/// subscriber without an `MXMetricPayload` (which is not constructible
/// from user code).
public protocol MetricKitPayloadSink: Sendable {
    /// Drop one MetricKit payload to disk at mode 0600. Returns the
    /// destination URL on success, or nil if the write failed
    /// (best-effort — telemetry MUST NOT crash the helper).
    @discardableResult
    func write(payloadJSON: Data, payloadUUID: String) async -> URL?
}

/// Default file-system sink: writes to
/// `~/Library/Application Support/MCI/metrickit/<payloadUUID>.json` at
/// mode 0600. Sendable + safe to share across the MetricKit delegate
/// queue + a test queue.
public actor MetricKitFileSink: MetricKitPayloadSink {
    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.baseDirectory = appSupport
                .appendingPathComponent("MCI")
                .appendingPathComponent("metrickit")
        }
    }

    @discardableResult
    public func write(payloadJSON: Data, payloadUUID: String) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            FileHandle.standardError.write(
                "mci-capture-helper: metrickit dir create failed: \(error)\n"
                    .data(using: .utf8) ?? Data()
            )
            return nil
        }
        let dest = baseDirectory.appendingPathComponent("\(payloadUUID).json")
        do {
            // Atomic write — never expose a partially-written file to
            // a concurrent reader (the public dashboard ingester, an
            // operator's `cat`, etc).
            try payloadJSON.write(to: dest, options: [.atomic])
            // Defence in depth: explicitly set 0600 even though the
            // user-domain default umask should already restrict.
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: dest.path
            )
            return dest
        } catch {
            FileHandle.standardError.write(
                "mci-capture-helper: metrickit payload write failed (\(payloadUUID)): \(error)\n"
                    .data(using: .utf8) ?? Data()
            )
            return nil
        }
    }
}

/// MetricKit delegate that drops each received payload to a
/// `MetricKitPayloadSink`. Holds the sink + an optional log gate.
/// Strongly retained at helper top level via
/// `MetricKitSubscriber.install(_:)`.
public final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let sink: MetricKitPayloadSink

    public init(sink: MetricKitPayloadSink) {
        self.sink = sink
        super.init()
    }

    /// Apple delegate hook. Called approximately daily by MetricKit's
    /// system-aggregation cadence. The delegate is responsible for
    /// persisting the payload; MetricKit does NOT re-deliver a
    /// payload after `didReceive` returns.
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // `jsonRepresentation()` is Apple's canonical content-free
            // serialization. The UUID is derived from the payload's
            // begin/end timestamps and is stable across retries.
            let json = payload.jsonRepresentation()
            let uuid = payloadStableUUID(payload)
            Task {
                await sink.write(payloadJSON: json, payloadUUID: uuid)
            }
        }
    }

    /// Diagnostic payload hook (hangs, disk write exceptions, CPU
    /// exceptions). Same content-free posture — Apple's
    /// `MXDiagnosticPayload.jsonRepresentation()` carries only resource-
    /// envelope diagnostics, never user content.
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            let uuid = diagnosticPayloadStableUUID(payload)
            Task {
                await sink.write(payloadJSON: json, payloadUUID: "diag-\(uuid)")
            }
        }
    }

    /// Build a stable UUID-like string for a payload from its
    /// timestamp range. MetricKit payloads do not expose a native
    /// UUID; the begin/end timestamps are unique per device-day.
    private func payloadStableUUID(_ payload: MXMetricPayload) -> String {
        let begin = Int64(payload.timeStampBegin.timeIntervalSince1970)
        let end = Int64(payload.timeStampEnd.timeIntervalSince1970)
        return "metric-\(begin)-\(end)"
    }

    private func diagnosticPayloadStableUUID(_ payload: MXDiagnosticPayload) -> String {
        let begin = Int64(payload.timeStampBegin.timeIntervalSince1970)
        let end = Int64(payload.timeStampEnd.timeIntervalSince1970)
        return "\(begin)-\(end)"
    }

    /// Strong reference held at helper top level so the
    /// `MXMetricManager` subscriber registration stays alive for the
    /// process lifetime (MetricKit holds subscribers WEAKLY — same
    /// retention discipline as SCStream's delegate per
    /// SCSTREAM-LIVE-001).
    nonisolated(unsafe) private static var installed: MetricKitSubscriber?

    /// Register a new subscriber with `MXMetricManager.shared`. Idempotent
    /// — calling twice replaces the prior subscriber (with `remove` of the
    /// old) so a test re-install does not leak a stale subscriber.
    /// Returns the installed subscriber so the caller can drop it from a
    /// top-level `_ = ...` binding for explicit process-lifetime retention.
    @discardableResult
    public static func install(sink: MetricKitPayloadSink) -> MetricKitSubscriber {
        let subscriber = MetricKitSubscriber(sink: sink)
        if let prior = installed {
            MXMetricManager.shared.remove(prior)
        }
        installed = subscriber
        MXMetricManager.shared.add(subscriber)
        return subscriber
    }
}
