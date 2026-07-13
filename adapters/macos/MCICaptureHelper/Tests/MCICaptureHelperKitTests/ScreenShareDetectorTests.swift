// SPDX-License-Identifier: TBD-private
//
// ScreenShareDetectorTests — headless XCTest coverage for the
// cycle 8.44 audit risk #1 detector. PROTECTED-SET per
// AGENT_PROTOCOL §5. Pins the debounce + aggregation contract so a
// future refactor cannot regress it silently:
//   (a) 2-sample debounce: single active poll does NOT flip;
//   (b) 2 consecutive active samples DO flip to active;
//   (c) 2 consecutive inactive samples flip back;
//   (d) alternating verdicts NEVER flip (mission-critical flap
//       resistance);
//   (e) fail-safe: primary probe throw → active + fallback
//       attribution;
//   (f) SCShareableContent attribution → surfaces bundle-id;
//   (g) mirror-set (AirPlay) treated as active;
//   (h) actor change while active refreshes without state flip.

import XCTest

@testable import MCICaptureHelperKit

private struct MockDisplayProbe: DisplayCaptureProbe {
    let verdicts: [(displayId: UInt32, reason: String)]
    let throws_: Bool
    init(_ verdicts: [(UInt32, String)] = [], throws_: Bool = false) {
        self.verdicts = verdicts.map { (displayId: $0.0, reason: $0.1) }
        self.throws_ = throws_
    }

    func capturedDisplays() throws -> [(displayId: UInt32, reason: String)] {
        if throws_ { throw ScreenShareProbeError.osAPIUnavailable("mock-throw") }
        return verdicts
    }
}

private struct MockSharedContent: SharedContentProbe {
    let apps: [String]
    init(_ apps: [String] = []) { self.apps = apps }
    func capturingApplications() async throws -> [String] { apps }
}

private struct MockRunningApps: RunningAppProbe {
    let apps: [String]
    init(_ apps: [String] = []) { self.apps = apps }
    func runningScreenShareApps() -> [String] { apps }
}

private final class RecordingObserver: ScreenShareDetector.Observer, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [ScreenShareSample] = []

    func screenShareDetectorDidTransition(to sample: ScreenShareSample) async {
        lock.lock(); _samples.append(sample); lock.unlock()
    }

    var samples: [ScreenShareSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }
}

final class ScreenShareDetectorTests: XCTestCase {
    // (a)
    func testSingleActivePollDoesNotFlipPublishedState() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe([(1, "CGDisplay")]),
            sharedContentProbe: MockSharedContent(["us.zoom.xos"]),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        let v = await detector.pollOnce()
        XCTAssertTrue(v.isSharingActive)
        await detector.applyDebounced(verdict: v)
        XCTAssertEqual(observer.samples.count, 0)
        XCTAssertFalse(detector.currentPublishedSample().isSharingActive)
    }

    // (b)
    func testTwoConsecutiveActiveSamplesFlipToActive() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe([(1, "CGDisplay")]),
            sharedContentProbe: MockSharedContent(["us.zoom.xos"]),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        for _ in 0 ..< 2 {
            let v = await detector.pollOnce()
            await detector.applyDebounced(verdict: v)
        }
        XCTAssertEqual(observer.samples.count, 1)
        XCTAssertTrue(observer.samples[0].isSharingActive)
        XCTAssertEqual(observer.samples[0].sharingActor, "us.zoom.xos")
    }

    // (c)
    func testTwoConsecutiveInactiveSamplesFlipBackToInactive() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe([(1, "CGDisplay")]),
            sharedContentProbe: MockSharedContent(["us.zoom.xos"]),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        await detector.applyDebounced(
            verdict: .init(isSharingActive: true, sharingActor: "us.zoom.xos")
        )
        await detector.applyDebounced(
            verdict: .init(isSharingActive: true, sharingActor: "us.zoom.xos")
        )
        XCTAssertEqual(observer.samples.count, 1)
        await detector.applyDebounced(
            verdict: .init(isSharingActive: false, sharingActor: nil)
        )
        XCTAssertEqual(observer.samples.count, 1) // debounce holds
        await detector.applyDebounced(
            verdict: .init(isSharingActive: false, sharingActor: nil)
        )
        XCTAssertEqual(observer.samples.count, 2)
        XCTAssertFalse(observer.samples[1].isSharingActive)
    }

    // (d) — CORE FLAP-RESISTANCE.
    func testAlternatingVerdictsNeverFlipPublishedState() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe(),
            sharedContentProbe: MockSharedContent(),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        for i in 0 ..< 10 {
            let active = i.isMultiple(of: 2)
            await detector.applyDebounced(
                verdict: .init(
                    isSharingActive: active,
                    sharingActor: active ? "us.zoom.xos" : nil
                )
            )
        }
        XCTAssertEqual(observer.samples.count, 0)
        XCTAssertFalse(detector.currentPublishedSample().isSharingActive)
    }

    // (e)
    func testPrimaryProbeThrowFailsSafeToActive() async {
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe(throws_: true),
            sharedContentProbe: MockSharedContent(),
            runningAppProbe: MockRunningApps(["us.zoom.xos"])
        )
        let v = await detector.pollOnce()
        XCTAssertTrue(v.isSharingActive)
        XCTAssertEqual(v.sharingActor, "us.zoom.xos")
    }

    // (f)
    func testSharedContentProbeAttributesToKnownBundleId() async {
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe([(1, "CGDisplay")]),
            sharedContentProbe: MockSharedContent(["com.microsoft.teams2"]),
            runningAppProbe: MockRunningApps()
        )
        let v = await detector.pollOnce()
        XCTAssertTrue(v.isSharingActive)
        XCTAssertEqual(v.sharingActor, "com.microsoft.teams2")
    }

    // (g)
    func testMirrorSetTreatedAsActiveShare() async {
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe([(2, "MirrorSet")]),
            sharedContentProbe: MockSharedContent(),
            runningAppProbe: MockRunningApps()
        )
        let v = await detector.pollOnce()
        XCTAssertTrue(v.isSharingActive)
        XCTAssertEqual(v.sharingActor, "MirrorSet")
    }

    // (h)
    func testActorChangeWhileActiveRefreshesWithoutStateFlip() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe(),
            sharedContentProbe: MockSharedContent(),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        await detector.applyDebounced(
            verdict: .init(isSharingActive: true, sharingActor: "us.zoom.xos")
        )
        await detector.applyDebounced(
            verdict: .init(isSharingActive: true, sharingActor: "us.zoom.xos")
        )
        XCTAssertEqual(observer.samples.count, 1)
        await detector.applyDebounced(
            verdict: .init(isSharingActive: true, sharingActor: "com.google.Chrome")
        )
        // Actor changed → refresh publishes on the first matching
        // sample; the pill can update mid-share.
        XCTAssertEqual(observer.samples.count, 2)
        XCTAssertTrue(observer.samples[1].isSharingActive)
        XCTAssertEqual(observer.samples[1].sharingActor, "com.google.Chrome")
    }

    // Fresh-inactive baseline: never fires observer on start.
    func testCleanDisplaysDoesNotFireObserverOnStart() async {
        let observer = RecordingObserver()
        let detector = ScreenShareDetector(
            displayProbe: MockDisplayProbe(),
            sharedContentProbe: MockSharedContent(),
            runningAppProbe: MockRunningApps(),
            observer: observer
        )
        for _ in 0 ..< 5 {
            let v = await detector.pollOnce()
            await detector.applyDebounced(verdict: v)
        }
        XCTAssertEqual(observer.samples.count, 0)
    }
}
