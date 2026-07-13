// SPDX-License-Identifier: TBD-private
//
// AutomationTargetMonitorTests — headless XCTest coverage for the
// cycle 8.47 follow-up. PROTECTED-SET per AGENT_PROTOCOL §5. Pins the
// per-target debounce + wire contract so a future refactor cannot
// regress it silently:
//   (a) seedInitialSnapshot does NOT fire observer callbacks;
//   (b) granted → denied fires IMMEDIATELY (single-sample);
//   (c) denied → granted requires TWO consecutive granted samples;
//   (d) probe `.unknown` (target-not-running / error) NEVER fires;
//   (e) multiple targets track independently — a revoke of Safari does
//       not affect Chrome;
//   (f) monitor ALWAYS passes askUser=false to the probe (mission
//       constraint — no user prompt on the 0.5 Hz path);
//   (g) wire format matches sibling-PR parser: `automation:<bundleId>`;
//   (h) registry helper honours the "only registered bridges" rule.

import XCTest

@testable import MCICaptureHelperKit

/// Programmable mock probe. Feeds a queue of per-target verdicts;
/// exhausted queue defaults to `.unknown` (safe no-op). Also records
/// every `askUser` argument the monitor passes — the mission constraint
/// is that the monitor MUST always pass false.
private final class ScriptedAutomationProbe: AutomationProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String: [TCCStatus]] = [:]
    private var _askUserCalls: [Bool] = []

    func enqueue(_ bundle: String, _ statuses: [TCCStatus]) {
        lock.lock(); queue[bundle, default: []].append(contentsOf: statuses); lock.unlock()
    }

    func status(forTargetBundle bundleId: String, askUser: Bool) -> TCCStatus {
        lock.lock(); defer { lock.unlock() }
        _askUserCalls.append(askUser)
        guard var q = queue[bundleId], !q.isEmpty else { return .unknown }
        let first = q.removeFirst()
        queue[bundleId] = q
        return first
    }

    var askUserCalls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _askUserCalls
    }
}

private final class RecordingAutomationObserver: AutomationTargetMonitor.Observer, @unchecked Sendable {
    private let lock = NSLock()
    private var _transitions: [AutomationTargetMonitor.Transition] = []

    func automationTargetDidTransition(_ transition: AutomationTargetMonitor.Transition) async {
        lock.lock(); _transitions.append(transition); lock.unlock()
    }

    var transitions: [AutomationTargetMonitor.Transition] {
        lock.lock(); defer { lock.unlock() }
        return _transitions
    }
}

final class AutomationTargetMonitorTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let chrome = "com.google.Chrome"

    // (a)
    func testSeedInitialSnapshotDoesNotFireObserver() async {
        let observer = RecordingAutomationObserver()
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.granted])
        probe.enqueue(chrome, [.granted])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari, chrome], observer: observer
        )
        monitor.seedInitialSnapshot()
        XCTAssertEqual(observer.transitions.count, 0)
        XCTAssertEqual(monitor.currentStatuses()[safari], .granted)
        XCTAssertEqual(monitor.currentStatuses()[chrome], .granted)
    }

    // (b) revoke fires immediately, single-sample
    func testRevokeFiresImmediatelySingleSample() async {
        let observer = RecordingAutomationObserver()
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.granted])
        probe.enqueue(chrome, [.granted])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari, chrome], observer: observer
        )
        monitor.seedInitialSnapshot()

        probe.enqueue(safari, [.denied])
        probe.enqueue(chrome, [.granted])
        await monitor.tickOnce()

        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].targetBundleId, safari)
        XCTAssertEqual(observer.transitions[0].oldStatus, .granted)
        XCTAssertEqual(observer.transitions[0].newStatus, .denied)
        XCTAssertEqual(monitor.currentStatuses()[safari], .denied)
    }

    // (c) restore requires two consecutive granted samples
    func testRestoreRequiresTwoConsecutiveGrantedSamples() async {
        let observer = RecordingAutomationObserver()
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.denied])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari], observer: observer
        )
        monitor.seedInitialSnapshot()

        // First granted sample → no transition yet
        probe.enqueue(safari, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 0)
        XCTAssertEqual(monitor.currentStatuses()[safari], .denied)

        // Second granted sample → transition fires
        probe.enqueue(safari, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].newStatus, .granted)
        XCTAssertEqual(monitor.currentStatuses()[safari], .granted)
    }

    // (d) probe .unknown (target-not-running) never fires a transition,
    // even repeatedly — critical because Safari being closed is common.
    func testProbeUnknownNeverFiresTransition() async {
        let observer = RecordingAutomationObserver()
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.granted])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari], observer: observer
        )
        monitor.seedInitialSnapshot()

        for _ in 0..<10 {
            probe.enqueue(safari, [.unknown])
            await monitor.tickOnce()
        }
        XCTAssertEqual(observer.transitions.count, 0)
        XCTAssertEqual(monitor.currentStatuses()[safari], .granted)
    }

    // (e) multiple targets track independently
    func testMultipleTargetsTrackIndependently() async {
        let observer = RecordingAutomationObserver()
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.granted])
        probe.enqueue(chrome, [.granted])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari, chrome], observer: observer
        )
        monitor.seedInitialSnapshot()

        probe.enqueue(safari, [.denied])
        probe.enqueue(chrome, [.granted])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 1)
        XCTAssertEqual(observer.transitions[0].targetBundleId, safari)
        XCTAssertEqual(monitor.currentStatuses()[chrome], .granted)

        // Now revoke chrome while safari still denied
        probe.enqueue(safari, [.denied])
        probe.enqueue(chrome, [.denied])
        await monitor.tickOnce()
        XCTAssertEqual(observer.transitions.count, 2)
        XCTAssertEqual(observer.transitions[1].targetBundleId, chrome)
        XCTAssertEqual(observer.transitions[1].newStatus, .denied)
    }

    // (f) mission constraint: monitor MUST always pass askUser=false
    func testMonitorAlwaysPassesAskUserFalse() async {
        let probe = ScriptedAutomationProbe()
        probe.enqueue(safari, [.granted, .denied, .granted, .granted])
        let monitor = AutomationTargetMonitor(
            probe: probe, targets: [safari]
        )
        monitor.seedInitialSnapshot()
        await monitor.tickOnce()
        await monitor.tickOnce()
        await monitor.tickOnce()
        XCTAssertFalse(probe.askUserCalls.isEmpty)
        XCTAssertTrue(probe.askUserCalls.allSatisfy { $0 == false },
                      "Monitor must never provoke a user prompt on the poll path")
    }

    // (g) wire format matches sibling-PR expectations
    func testHelperHealthLineFormatRevoke() {
        let line = AutomationTargetHelperHealth.line(
            for: AutomationTargetMonitor.Transition(
                targetBundleId: "com.apple.Safari",
                oldStatus: .granted,
                newStatus: .denied
            )
        )
        XCTAssertEqual(
            line,
            "mci-capture-helper: helper_health tcc_revoked=automation:com.apple.Safari\n"
        )
    }

    func testHelperHealthLineFormatRestore() {
        let line = AutomationTargetHelperHealth.line(
            for: AutomationTargetMonitor.Transition(
                targetBundleId: "com.google.Chrome",
                oldStatus: .denied,
                newStatus: .granted
            )
        )
        XCTAssertEqual(
            line,
            "mci-capture-helper: helper_health tcc_restored=automation:com.google.Chrome\n"
        )
    }

    // (h) registry helper — only registered bridges are probed
    func testRegistryHelperOnlyRegisteredBridges() {
        XCTAssertEqual(
            AutomationTargetRegistry.registeredTargets(
                safariExtensionInstalled: true,
                chromeExtensionInstalled: false
            ),
            ["com.apple.Safari"]
        )
        XCTAssertEqual(
            AutomationTargetRegistry.registeredTargets(
                safariExtensionInstalled: false,
                chromeExtensionInstalled: true
            ),
            ["com.google.Chrome"]
        )
        XCTAssertEqual(
            AutomationTargetRegistry.registeredTargets(
                safariExtensionInstalled: true,
                chromeExtensionInstalled: true
            ),
            ["com.apple.Safari", "com.google.Chrome"]
        )
        XCTAssertEqual(
            AutomationTargetRegistry.registeredTargets(
                safariExtensionInstalled: false,
                chromeExtensionInstalled: false
            ),
            []
        )
    }

    // Well-known target enum pins the exact bundle-id strings we ever
    // emit on the stderr wire. If a future PR renames these, the parser
    // side (sibling PR) MUST be updated in lockstep — this is the canary.
    func testWellKnownTargetBundleIds() {
        XCTAssertEqual(WellKnownAutomationTarget.safari.bundleId, "com.apple.Safari")
        XCTAssertEqual(WellKnownAutomationTarget.chrome.bundleId, "com.google.Chrome")
    }
}
