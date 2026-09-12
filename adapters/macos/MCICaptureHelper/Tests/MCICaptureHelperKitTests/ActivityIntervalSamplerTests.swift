import XCTest
@testable import MCICaptureHelperKit

final class ActivityIntervalSamplerTests: XCTestCase {
    private func observation(_ seconds: UInt64, uptimeSeconds: UInt64? = nil,
                             state: UserActivityState = .active,
                             admitted: Bool = true, generation: UInt64 = 1,
                             app: String? = "com.example.Editor") -> ActivityObservation {
        ActivityObservation(tsUs: (seconds + 100) * 1_000_000,
                            uptimeNs: (uptimeSeconds ?? seconds) * 1_000_000_000,
                            focusGeneration: generation, appBundleId: app,
                            state: state, admitted: admitted)
    }

    func testRequiresTwoBoundedObservationsAndNeverCountsStartup() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        XCTAssertNil(sampler.sample(observation(1)))
        let interval = sampler.sample(observation(5))
        XCTAssertEqual(interval?.startUs, 101_000_000)
        XCTAssertEqual(interval?.endUs, 105_000_000)
        XCTAssertEqual(interval?.state, .inputActive)
        XCTAssertEqual(interval?.appBundleId, "com.example.Editor")
    }

    func testDeniedUnknownAndChangedFocusCarryNoIdentity() {
        for next in [observation(5, admitted: false), observation(5, state: .unknown),
                     observation(5, generation: 2), observation(5, app: "com.example.Other")] {
            var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
            _ = sampler.sample(observation(1))
            let interval = sampler.sample(next)
            XCTAssertEqual(interval?.state, .unknown)
            XCTAssertNil(interval?.appBundleId)
        }
    }

    func testDeniedStartCannotBeReclassifiedAsLaterAllowedApp() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(1, admitted: false))
        XCTAssertNil(sampler.sample(observation(5))?.appBundleId)
    }

    func testIdleIsMeasuredSeparatelyAndTransitionsAreUnknown() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(1, state: .idle))
        XCTAssertEqual(sampler.sample(observation(5, state: .idle))?.state, .inputIdle)
        XCTAssertEqual(sampler.sample(observation(9))?.state, .unknown)
    }

    func testSuspendDelayClockJumpAndBackwardsTimeAreNotBridged() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(1))
        XCTAssertNil(sampler.sample(observation(10)))
        XCTAssertNil(sampler.sample(observation(2)))
        XCTAssertNil(sampler.sample(ActivityObservation(tsUs: 107_000_000, uptimeNs: 6_000_000_000,
                                                       focusGeneration: 1, appBundleId: "com.example.Editor",
                                                       state: .active, admitted: true)))
    }

    func testBackwardClockRecoveryNeverOverlapsEmittedInterval() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        XCTAssertNil(sampler.sample(observation(0, uptimeSeconds: 0)))
        XCTAssertEqual(sampler.sample(observation(4, uptimeSeconds: 4)),
                       MeasuredActivityInterval(startUs: 100_000_000, endUs: 104_000_000,
                                                state: .inputActive, appBundleId: "com.example.Editor",
                                                captureGeneration: "test-run"))
        XCTAssertNil(sampler.sample(observation(2, uptimeSeconds: 8)))
        XCTAssertNil(sampler.sample(observation(6, uptimeSeconds: 12)),
                     "Drop the whole [102,106) pair, not an overlap or a clipped interval")
        XCTAssertEqual(sampler.sample(observation(10, uptimeSeconds: 16)),
                       MeasuredActivityInterval(startUs: 106_000_000, endUs: 110_000_000,
                                                state: .inputActive, appBundleId: "com.example.Editor",
                                                captureGeneration: "test-run"))
    }

    func testBackwardClockHighWaterSurvivesMultipleRejectedPairs() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(20, uptimeSeconds: 0))
        XCTAssertEqual(sampler.sample(observation(24, uptimeSeconds: 4))?.endUs, 124_000_000)
        for (step, wall) in [4, 8, 12, 16, 20, 24].enumerated() {
            XCTAssertNil(sampler.sample(observation(UInt64(wall), uptimeSeconds: UInt64(step + 2) * 4)),
                         "Clock recovery must not forget the emitted [120,124) interval")
        }
        XCTAssertEqual(sampler.sample(observation(28, uptimeSeconds: 32)),
                       MeasuredActivityInterval(startUs: 124_000_000, endUs: 128_000_000,
                                                state: .inputActive, appBundleId: "com.example.Editor",
                                                captureGeneration: "test-run"))
    }

    func testBackwardClockAcrossAttributedAndUnknownIntervalsNeverLeaksIdentity() {
        for initiallyAdmitted in [true, false] {
            var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
            _ = sampler.sample(observation(0, uptimeSeconds: 0, admitted: initiallyAdmitted))
            let first = sampler.sample(observation(4, uptimeSeconds: 4, admitted: initiallyAdmitted))
            XCTAssertEqual(first?.state, initiallyAdmitted ? .inputActive : .unknown)
            XCTAssertEqual(first?.appBundleId, initiallyAdmitted ? "com.example.Editor" : nil)
            XCTAssertNil(sampler.sample(observation(2, uptimeSeconds: 8, admitted: !initiallyAdmitted,
                                                    generation: 2, app: "com.example.Private")))
            XCTAssertNil(sampler.sample(observation(6, uptimeSeconds: 12, admitted: !initiallyAdmitted,
                                                    generation: 2, app: "com.example.Private")))
            let recovered = sampler.sample(observation(10, uptimeSeconds: 16,
                                                        generation: 3, app: "com.example.Other"))
            XCTAssertEqual(recovered, MeasuredActivityInterval(startUs: 106_000_000, endUs: 110_000_000,
                                                                state: .unknown, appBundleId: nil,
                                                                captureGeneration: "test-run"))
            if let recovered {
                XCTAssertFalse(String(decoding: encodeActivityInterval(seq: 1, interval: recovered),
                                      as: UTF8.self).contains("com.example"))
            }
            XCTAssertEqual(sampler.sample(observation(14, uptimeSeconds: 20,
                                                      generation: 3, app: "com.example.Other"))?.appBundleId,
                           "com.example.Other")
        }
    }

    func testForwardClockJumpSkipsGapAndRecoversWithoutPoisoningHighWater() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(0, uptimeSeconds: 0))
        XCTAssertEqual(sampler.sample(observation(4, uptimeSeconds: 4))?.endUs, 104_000_000)
        XCTAssertNil(sampler.sample(observation(40, uptimeSeconds: 8)))
        XCTAssertNil(sampler.sample(observation(8, uptimeSeconds: 12)))
        XCTAssertEqual(sampler.sample(observation(12, uptimeSeconds: 16))?.startUs, 108_000_000,
                       "An un-emitted forward spike must not move the emitted high-water mark")
        XCTAssertNil(sampler.sample(observation(50, uptimeSeconds: 20)))
        XCTAssertEqual(sampler.sample(observation(54, uptimeSeconds: 24)),
                       MeasuredActivityInterval(startUs: 150_000_000, endUs: 154_000_000,
                                                state: .inputActive, appBundleId: "com.example.Editor",
                                                captureGeneration: "test-run"))
    }

    func testMonotonicClockDiscontinuityNeedsFreshPairWithoutWallOverlap() {
        var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
        _ = sampler.sample(observation(0, uptimeSeconds: 20))
        XCTAssertEqual(sampler.sample(observation(4, uptimeSeconds: 24))?.endUs, 104_000_000)
        XCTAssertNil(sampler.sample(observation(8, uptimeSeconds: 1)))
        XCTAssertEqual(sampler.sample(observation(12, uptimeSeconds: 5))?.startUs, 108_000_000)
    }

    func testNewCaptureGenerationRequiresFreshObservationsWithoutBridgingDowntime() {
        var sampler = ActivityIntervalSampler(captureGeneration: "old-run")
        _ = sampler.sample(observation(0, uptimeSeconds: 0))
        XCTAssertEqual(sampler.sample(observation(4, uptimeSeconds: 4))?.endUs, 104_000_000)
        sampler = ActivityIntervalSampler(captureGeneration: "new-run")
        XCTAssertNil(sampler.sample(observation(20, uptimeSeconds: 20)))
        XCTAssertEqual(sampler.sample(observation(24, uptimeSeconds: 24)),
                       MeasuredActivityInterval(startUs: 120_000_000, endUs: 124_000_000,
                                                state: .inputActive, appBundleId: "com.example.Editor",
                                                captureGeneration: "new-run"))
    }

    func testUnknownWireContainsNoAppIdentity() throws {
        let interval = MeasuredActivityInterval(startUs: 1, endUs: 4_000_001,
                                               state: .unknown, appBundleId: nil,
                                               captureGeneration: "test-run")
        let frame = encodeActivityInterval(seq: 9, interval: interval)
        XCTAssertEqual(Array(frame.prefix(4)), [0x4D, 0x09, 0x60, 0x00])
        // Two timestamps, unknown state, empty app, then the length-prefixed generation.
        XCTAssertEqual(Array(frame.dropFirst(minFrameHeaderBytes + 16).prefix(3)), [0, 0, 0])
        XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("com.example"))
    }

    func testInvalidBundleComponentsAreUnknownBeforeWireEncoding() {
        for app in ["com.-", "com.-foo", "com.foo-", "com..foo", "com.foo/secret"] {
            var sampler = ActivityIntervalSampler(captureGeneration: "test-run")
            _ = sampler.sample(observation(1, app: app))
            let interval = sampler.sample(observation(5, app: app))
            XCTAssertEqual(interval?.state, .unknown)
            XCTAssertNil(interval?.appBundleId)
        }
    }
}
