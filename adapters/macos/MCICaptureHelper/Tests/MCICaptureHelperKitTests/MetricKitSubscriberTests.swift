// SPDX-License-Identifier: TBD-private
//
// MetricKitSubscriberTests — coverage for the Phase 6 PR 6 MetricKit
// non-content footprint telemetry pipeline.
//
// MetricKit's `MXMetricPayload` is not constructible from user code
// (Apple-private init); the test exercises the disk-write path via
// `MetricKitFileSink.write(payloadJSON:payloadUUID:)` directly with
// a synthetic JSON payload. The integration with `MXMetricManager`
// (subscriber registration) is exercised by the
// `MetricKitSubscriber.install(...)` static method, but the actual
// daily payload delivery is Apple's responsibility; we cover the
// shape contract (one file per payload + mode 0600 + UUID-derived
// filename) which is what the dispatch §"3-row mini-audit row 3"
// pins.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class MetricKitSubscriberTests: XCTestCase {
    /// Writing a synthetic JSON payload via `MetricKitFileSink`
    /// produces a file at `<baseDir>/<payloadUUID>.json` at mode 0600.
    /// Mirrors the production write path the `didReceive(_:)` delegate
    /// hook invokes per Apple's daily callback.
    func testWriteSyntheticPayloadProducesFileAtMode0600() async throws {
        let tmpDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sink = MetricKitFileSink(baseDirectory: tmpDir)
        let payload = Data(#"{"applicationTimeMetrics":{}}"#.utf8)
        let uuid = "metric-1700000000-1700086400"
        let dest = await sink.write(payloadJSON: payload, payloadUUID: uuid)
        let unwrapped = try XCTUnwrap(dest, "sink MUST return the written URL")
        XCTAssertEqual(unwrapped.lastPathComponent, "\(uuid).json")
        let written = try Data(contentsOf: unwrapped)
        XCTAssertEqual(written, payload, "written bytes must equal source payload")

        // Mode is 0600 — uid-matched, group/other denied (same posture
        // as helper-health.jsonl per CSO sign-off block in
        // MetricKitSubscriber.swift).
        let attrs = try FileManager.default.attributesOfItem(atPath: unwrapped.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(
            mode & 0o777,
            0o600,
            "metrickit payload file MUST be 0600 (CSO sign-off + 3-row mini-audit row 3)"
        )
    }

    /// `MetricKitFileSink` creates the base directory if missing
    /// (matches `MetricKitSubscriber.install(...)` precondition that
    /// the production path is `~/Library/Application Support/MCI/metrickit/`
    /// which may not exist on first run).
    func testWriteCreatesMissingDirectory() async throws {
        let tmpRoot = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        // Use a nested path that does NOT exist yet.
        let nestedDir = tmpRoot
            .appendingPathComponent("nested")
            .appendingPathComponent("metrickit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedDir.path))
        let sink = MetricKitFileSink(baseDirectory: nestedDir)
        let payload = Data(#"{"x":1}"#.utf8)
        let dest = await sink.write(payloadJSON: payload, payloadUUID: "abc")
        XCTAssertNotNil(dest, "write must succeed when baseDirectory does not exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedDir.path))
    }

    /// Re-writing the same payloadUUID overwrites — Apple may re-
    /// deliver a payload across helper restarts in rare cases, and
    /// the atomic write means a re-delivery produces a single file,
    /// not two.
    func testReWriteOverwritesExisting() async throws {
        let tmpDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sink = MetricKitFileSink(baseDirectory: tmpDir)
        let uuid = "metric-1-2"

        let firstPayload = Data(#"{"v":1}"#.utf8)
        let secondPayload = Data(#"{"v":2}"#.utf8)
        _ = await sink.write(payloadJSON: firstPayload, payloadUUID: uuid)
        let secondDest = await sink.write(payloadJSON: secondPayload, payloadUUID: uuid)
        let unwrapped = try XCTUnwrap(secondDest)
        let written = try Data(contentsOf: unwrapped)
        XCTAssertEqual(written, secondPayload, "second write overwrites first")
        // Mode 0600 preserved across overwrites.
        let attrs = try FileManager.default.attributesOfItem(atPath: unwrapped.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    /// `MetricKitSubscriber.install(...)` registers a subscriber and
    /// holds the strong reference at top-level (MetricKit holds
    /// subscribers WEAKLY per Apple's API; the static `installed`
    /// binding is what keeps it alive — same retention discipline as
    /// SCSTREAM-LIVE-001).
    func testInstallReturnsSubscriberAndRetainsAtTopLevel() async throws {
        let tmpDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sink = MetricKitFileSink(baseDirectory: tmpDir)
        let subscriber1 = MetricKitSubscriber.install(sink: sink)
        XCTAssertNotNil(subscriber1)
        // Re-install replaces (idempotent).
        let subscriber2 = MetricKitSubscriber.install(sink: sink)
        XCTAssertNotNil(subscriber2)
        // Object identity differs because install() always constructs
        // a fresh subscriber.
        XCTAssertFalse(subscriber1 === subscriber2)
    }

    // MARK: - Helpers

    private func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-metrickit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
