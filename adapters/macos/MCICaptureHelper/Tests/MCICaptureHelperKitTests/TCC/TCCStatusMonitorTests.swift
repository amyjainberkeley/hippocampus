// SPDX-License-Identifier: TBD-private
//
// TCCStatusMonitorTests — headless XCTest coverage for the cycle 8.45
// audit risk #2 monitor. PROTECTED-SET per AGENT_PROTOCOL §5. Pins the
// debounce + transition contract so a future refactor cannot regress
// it silently:
//   (a) seedInitialSnapshot does NOT fire observer callbacks;
//   (b) granted → denied fires IMMEDIATELY (single-sample);
//   (c) denied → granted requires TWO consecutive granted samples;
//   (d) probe `.unknown` NEVER fires a transition (leave state as-is);
//   (e) multiple surfaces track independently — a revoke of Screen
//       Recording does not affect Accessibility;
//   (f) currentStatuses() reflects debounced state, not raw probes.

import XCTest

@testable import MCICaptureHelperKit

/// Programmable mock probe. Feeds a queue of per-surface verdicts;
/// exhausted queue defaults to `.unknown` (safe no-op).
private final class ScriptedProbe: TCCProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [TCCSurface: [TCCStatus]] = [:]

    func enqueue(_ surface: TCCSurface, _ statuses: [TCCStatus]) {
        lock.lock(); queue[surface, default: []].append(contentsOf: statuses); lock.unlock()
    }

    func status(for surface: TCCSurface) -> TCCStatus {
        lock.lock(); defer { lock.unlock() }
        guard var q = queue[surface], !q.isEmpty else { return .unknown }
        let first = q.removeFirst()
        queue[surface] = q
        return first
    }
}

/// Fixed-verdict probe — every read returns the same result. Used to
/// seed a stable initial snapshot before scripting transitions.
private struct FixedProbe: TCCProbe {
    let statuses: [TCCSurface: TCCStatus]
    func status(for surface: TCCSurface) -> TCCStatus {
        statuses[surface] ?? .unknown
    }
}

private final class RecordingObserver: TCCStatusMonitor.Observer, @unchecked Sendable {
    private let lock = NSLock()
    private var _transitions: [TCCStatusMonitor.Transition] = []

    func tccStatusDidTransition(_ transition: TCCStatusMonitor.Transition) async {
        lock.withLock { _transitions.append(transition) }
    }

    var transitions: [TCCStatusMonitor.Transition] {
        lock.lock(); defer { lock.unlock() }
        return _transitions
    }
}

final class TCCStatusMonitorTests: XCTestCase {
    private let allButAutomation: [TCCSurface] = [
        .screenRecording, .accessibility, .fullDiskAccess
    ]

    // (a)
    func testSeedInitialSnapshotDoesNotFireObserver() async {
        let observer = RecordingObserver()
        let probe = FixedProbe(statuses: [
            .screenRecording: .granted,
            .accessibility: .granted,
            .fullDiskAccess: .granted,
        ])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()
        XCTAssertEqual(observer.transitions.count, 0)
        XCTAssertEqual(
            monitor.currentStatuses()[.screenRecording],
            .granted
        )
    }

    // (b)
    func testRevokeFiresImmediatelySingleSample() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        // The probe queue is FIFO and seedInitialSnapshot() consumes
        // exactly one entry per surface, so seed exactly one. Queuing
        // three left two stale .granted ahead of the .denied below, and
        // the tick popped a stale .granted instead — no transition, and
        // the test then indexed an empty array and crashed the process.
        probe.enqueue(.screenRecording, [.granted])
        // Accessibility + FDA get a second .granted so their tick pop is
        // a same-state repeat (no fire) rather than an exhausted-queue
        // .unknown.
        probe.enqueue(.accessibility, [.granted, .granted])
        probe.enqueue(.fullDiskAccess, [.granted, .granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot() // consumes 1 per surface
        // Now enqueue a single .denied for screenRecording
        probe.enqueue(.screenRecording, [.denied])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        // Guard rather than index blindly: a count mismatch should fail
        // this one test, not abort the whole suite with a fatal error.
        guard let t = observer.transitions.first else {
            return XCTFail("expected one transition, got none")
        }
        XCTAssertEqual(t.surface, .screenRecording)
        XCTAssertEqual(t.oldStatus, .granted)
        XCTAssertEqual(t.newStatus, .denied)
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .denied)
    }

    // (c)
    func testRestoreRequiresTwoConsecutiveGrantedSamples() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .denied)

        // First granted sample → NO transition yet (repeat count = 1)
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 0)
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .denied)

        // Second granted sample → transition fires
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].newStatus, .granted)
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .granted)
    }

    // (c-flicker) A denied-interruption resets the repeat count
    func testRestoreDeniedFlickerResetsRepeatCount() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()

        // granted (count=1), then denied (count reset), then granted
        // (count=1 again), then granted (count=2 → transition)
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 0)

        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        // Denied is a same-state (published is still .denied), so no fire.
        XCTAssertEqual(observer.transitions.count, 0)

        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 0)

        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].newStatus, .granted)
    }

    // (d)
    func testProbeUnknownNeverFiresTransition() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()

        // Simulate probe error stream — many .unknown reads
        for _ in 0..<10 {
            probe.enqueue(.screenRecording, [.unknown])
            probe.enqueue(.accessibility, [.unknown])
            probe.enqueue(.fullDiskAccess, [.unknown])
            await monitor.tickOnce()
        }
        XCTAssertEqual(observer.transitions.count, 0)
        // Published state stays at the seeded value.
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .granted)
    }

    // (e)
    func testMultipleSurfacesTrackIndependently() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()

        // Revoke screen recording; leave accessibility + FDA alone.
        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].surface, .screenRecording)
        XCTAssertEqual(monitor.currentStatuses()[.accessibility], .granted)
        XCTAssertEqual(monitor.currentStatuses()[.fullDiskAccess], .granted)

        // Now revoke accessibility while SR still denied.
        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.denied])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 2)
        XCTAssertEqual(observer.transitions[1].surface, .accessibility)
        XCTAssertEqual(observer.transitions[1].newStatus, .denied)
    }

    // (f)
    func testCurrentStatusesReflectsDebouncedState() async {
        let observer = RecordingObserver()
        let probe = ScriptedProbe()
        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        let monitor = TCCStatusMonitor(
            probe: probe, surfaces: allButAutomation, observer: observer
        )
        monitor.seedInitialSnapshot()

        // Raw probe returns granted-once during restore-repeat window;
        // currentStatuses stays at .denied until the second granted.
        probe.enqueue(.screenRecording, [.denied])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce() // SR → denied
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .denied)

        probe.enqueue(.screenRecording, [.granted])
        probe.enqueue(.accessibility, [.granted])
        probe.enqueue(.fullDiskAccess, [.granted])
        await monitor.tickOnce() // 1st granted → still denied
        XCTAssertEqual(monitor.currentStatuses()[.screenRecording], .denied)
    }

    // Automation is stubbed to `.unknown` in DefaultTCCProbe — verify
    // the stubbed surface never fires.
    func testAutomationStubDoesNotFire() async {
        let observer = RecordingObserver()
        let probe = DefaultTCCProbe(fdaProbePath: URL(fileURLWithPath: "/nonexistent-file-xyz"))
        let monitor = TCCStatusMonitor(
            probe: probe,
            surfaces: [.automation],
            observer: observer
        )
        monitor.seedInitialSnapshot()
        // Repeated ticks with an all-.unknown probe: no observer fires.
        for _ in 0..<5 {
            await monitor.tickOnce()
        }
        XCTAssertEqual(observer.transitions.count, 0)
    }

    // DefaultTCCProbe FDA branch — a missing file is `.unknown`, not
    // a false-denied (mission constraint: no spurious pauses).
    func testDefaultFDAProbeMissingFileIsUnknown() {
        let probe = DefaultTCCProbe(
            fdaProbePath: URL(fileURLWithPath: "/definitely/does/not/exist/xyz")
        )
        XCTAssertEqual(probe.status(for: .fullDiskAccess), .unknown)
    }

    // DefaultTCCProbe FDA branch — a readable file is `.granted`.
    func testDefaultFDAProbeReadableFileIsGranted() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-tcc-fda-probe-\(UUID().uuidString)")
        try "ok".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = DefaultTCCProbe(fdaProbePath: tmp)
        XCTAssertEqual(probe.status(for: .fullDiskAccess), .granted)
    }

    // TCCHelperHealth line format — pinned so the app-side parser
    // and helper-side emitter stay in lockstep.
    func testHelperHealthLineFormatRevoke() {
        let line = TCCHelperHealth.line(
            for: TCCStatusMonitor.Transition(
                surface: .screenRecording,
                oldStatus: .granted,
                newStatus: .denied
            )
        )
        XCTAssertEqual(
            line,
            "mci-capture-helper: helper_health tcc_revoked=screenRecording\n"
        )
    }

    func testHelperHealthLineFormatRestore() {
        let line = TCCHelperHealth.line(
            for: TCCStatusMonitor.Transition(
                surface: .accessibility,
                oldStatus: .denied,
                newStatus: .granted
            )
        )
        XCTAssertEqual(
            line,
            "mci-capture-helper: helper_health tcc_restored=accessibility\n"
        )
    }
}
