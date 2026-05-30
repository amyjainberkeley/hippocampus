// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

/// Sendable mutable box for capture-in-closure state. The hooks the
/// unlocker exposes are typed `@Sendable`; without a box the Swift 6
/// strict-concurrency checker rejects `inout` captures.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class QuarantineUnlockerTests: XCTestCase {

    private var sandboxBundle: URL!

    override func setUpWithError() throws {
        sandboxBundle = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "QuarantineUnlockerTests-\(UUID().uuidString).app",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sandboxBundle, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandboxBundle)
    }

    // MARK: - Probe short-circuit

    /// When the bundle has no quarantine attr, `runIfNeeded()` MUST
    /// return `.notQuarantined` without calling the strip invoker.
    func testNotQuarantinedShortCircuits() {
        let stripCallCount = Box(0)
        let unlocker = QuarantineUnlocker(
            bundlePath: sandboxBundle,
            probe: { _ in false },
            invoke: { _, _ in
                stripCallCount.value += 1
                return 0
            }
        )

        let outcome = unlocker.runIfNeeded()
        XCTAssertEqual(outcome, .notQuarantined)
        XCTAssertEqual(stripCallCount.value, 0,
            "Probe returned false; strip invoker MUST NOT run")
    }

    // MARK: - Strip success

    /// When the bundle is quarantined and strip exits 0, the outcome
    /// MUST be `.stripped` and the invoker MUST receive the bundle path
    /// + the configured xattr binary path.
    func testStripSucceeds() {
        let capturedBin = Box<String?>(nil)
        let capturedURL = Box<URL?>(nil)
        let unlocker = QuarantineUnlocker(
            bundlePath: sandboxBundle,
            xattrPath: "/path/to/xattr",
            probe: { _ in true },
            invoke: { bin, url in
                capturedBin.value = bin
                capturedURL.value = url
                return 0
            }
        )

        let outcome = unlocker.runIfNeeded()
        XCTAssertEqual(outcome, .stripped)
        XCTAssertEqual(capturedBin.value, "/path/to/xattr")
        XCTAssertEqual(capturedURL.value, sandboxBundle)
    }

    // MARK: - Strip failure surfaces exit code

    /// A non-zero exit on a non-mounted-volume path surfaces as
    /// `.stripFailed(exit)` so the caller can log + telemetry.
    func testStripFailureSurfacesExitCode() {
        let unlocker = QuarantineUnlocker(
            bundlePath: sandboxBundle,
            probe: { _ in true },
            invoke: { _, _ in 1 }
        )

        let outcome = unlocker.runIfNeeded()
        XCTAssertEqual(outcome, .stripFailed(1))
    }

    // MARK: - Read-only mount detection

    /// When the bundle is inside `/Volumes/` (typical DMG-launch case)
    /// and strip fails, the outcome MUST be `.readOnlyMount` so the
    /// caller can log it less loudly — the user will land on
    /// `/Applications` on the next launch and the strip will succeed
    /// there.
    func testReadOnlyMountSurfacesAsDistinctOutcome() {
        let mounted = URL(fileURLWithPath: "/Volumes/Hippocampus/Hippocampus.app")
        let unlocker = QuarantineUnlocker(
            bundlePath: mounted,
            probe: { _ in true },
            invoke: { _, _ in 1 }
        )

        let outcome = unlocker.runIfNeeded()
        XCTAssertEqual(outcome, .readOnlyMount)
    }

    /// A successful strip on a mounted-volume path (vanishingly rare,
    /// but legal — DMG mounted RW) still reports `.stripped`. The
    /// `readOnlyMount` branch fires ONLY on strip failure.
    func testMountedVolumeSuccessStillReportsStripped() {
        let mounted = URL(fileURLWithPath: "/Volumes/Hippocampus/Hippocampus.app")
        let unlocker = QuarantineUnlocker(
            bundlePath: mounted,
            probe: { _ in true },
            invoke: { _, _ in 0 }
        )

        let outcome = unlocker.runIfNeeded()
        XCTAssertEqual(outcome, .stripped)
    }

    // MARK: - Idempotency

    /// `runIfNeeded()` is safe to call repeatedly. After a successful
    /// strip, the next call (with the probe now returning false to
    /// simulate the attr being gone) MUST short-circuit.
    func testIdempotentAfterSuccessfulStrip() {
        let probeShouldReturn = Box(true)
        let stripCallCount = Box(0)
        let unlocker = QuarantineUnlocker(
            bundlePath: sandboxBundle,
            probe: { _ in probeShouldReturn.value },
            invoke: { _, _ in
                stripCallCount.value += 1
                return 0
            }
        )

        XCTAssertEqual(unlocker.runIfNeeded(), .stripped)
        XCTAssertEqual(stripCallCount.value, 1)

        // Simulate the OS having cleared the attr.
        probeShouldReturn.value = false

        XCTAssertEqual(unlocker.runIfNeeded(), .notQuarantined)
        XCTAssertEqual(stripCallCount.value, 1,
            "Second runIfNeeded with attr absent MUST NOT invoke strip again")
    }

    // MARK: - Real-probe smoke test

    /// On a fresh tmpdir-created bundle, `realProbe` MUST return false
    /// (no xattr ever set). This is a smoke test of the probe wiring;
    /// it does NOT exercise the strip path.
    func testRealProbeOnUnattributedBundleReturnsFalse() {
        XCTAssertFalse(QuarantineUnlocker.realProbe(sandboxBundle))
    }
}
