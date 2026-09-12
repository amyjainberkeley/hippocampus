import ApplicationServices
import XCTest
@testable import MCICaptureHelperKit

final class AXProbeHealthTests: XCTestCase {
    private final class ObservationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [AXProbeHealthSnapshot] = []
        private var reads = 0
        func record(_ snapshot: AXProbeHealthSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            snapshots.append(snapshot)
        }
        func values() -> [AXProbeHealthSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
        }
        func recordRead() {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
        }
        func readCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    private func snapshot(
        classification: Bool? = nil,
        focusResult: Int32 = 0,
        focused: Bool = true,
        subrole: Int32? = -25205,
        value: AXBackstopOutcome? = .negative,
        identifier: AXBackstopOutcome? = .errored,
        descendant: AXBackstopOutcome? = .negative
    ) -> AXProbeHealthSnapshot {
        AXProbeHealthSnapshot(
            focusResult: focusResult, focusedElementMatched: focused,
            subroleResult: subrole, valueHidden: value,
            identifierMatch: identifier, descendantSecure: descendant,
            classification: classification
        )
    }

    func testUnknownEmitsOnlyCodesAndOutcomes() {
        let line = AXProbeHealthReporter().line(for: snapshot(), at: 100)
        XCTAssertEqual(line, "mci-capture-helper: helper_health ax_unclassified "
            + "focus_result=0 focused=present subrole_result=-25205 "
            + "value_hidden=negative identifier=error descendant=negative\n")
    }

    func testUnobservedBackstopsAreNotReportedAsNegative() {
        let line = AXProbeHealthReporter().line(for: snapshot(
            focusResult: -25211, focused: false, subrole: nil,
            value: nil, identifier: nil, descendant: nil
        ), at: 0)
        XCTAssertEqual(line, "mci-capture-helper: helper_health ax_unclassified "
            + "focus_result=-25211 focused=absent subrole_result=unobserved "
            + "value_hidden=unobserved identifier=unobserved descendant=unobserved\n")
    }

    func testKnownClassificationsDoNotEmitOrConsumeTheBudget() {
        let reporter = AXProbeHealthReporter()
        XCTAssertNil(reporter.line(for: snapshot(classification: false), at: 99))
        XCTAssertNil(reporter.line(for: snapshot(classification: true), at: 99))
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 100))
    }

    func testRepeatedAndChangedFailuresShareOneThirtySecondBudget() {
        let reporter = AXProbeHealthReporter()
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 100))
        XCTAssertNil(reporter.line(for: snapshot(), at: 100))
        XCTAssertNil(reporter.line(for: snapshot(identifier: .negative, descendant: .errored), at: 129.99))
        XCTAssertNotNil(reporter.line(for: snapshot(identifier: .negative, descendant: .errored), at: 130))
        XCTAssertNil(reporter.line(for: snapshot(), at: 159.99))
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 160))
    }

    func testInvalidClockDoesNotPoisonTheBudget() {
        let reporter = AXProbeHealthReporter()
        for time in [Double.nan, Double.infinity, -Double.infinity, -1] {
            XCTAssertNil(reporter.line(for: snapshot(), at: time))
        }
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 0))
        XCTAssertNil(reporter.line(for: snapshot(), at: 20))
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 30))
    }

    func testRegressingClockDoesNotResetTheLimit() {
        let reporter = AXProbeHealthReporter()
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 100))
        XCTAssertNil(reporter.line(for: snapshot(), at: 90))
        XCTAssertNil(reporter.line(for: snapshot(), at: 120))
        XCTAssertNotNil(reporter.line(for: snapshot(), at: 130))
    }

    func testConcurrentCallsCannotExceedOneEmission() {
        let reporter = AXProbeHealthReporter()
        let observation = snapshot()
        let log = ObservationLog()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if reporter.line(for: observation, at: 100) != nil {
                log.record(observation)
            }
        }
        XCTAssertEqual(log.values().count, 1)
    }

    func testProductionProbeHealthSinkObservesReturnedClassificationOnce() {
        let cases: [(AXError, String?, Bool?)] = [
            (.apiDisabled, nil, nil), (.noValue, nil, false),
            (.success, "not-an-element", nil),
        ]
        for (status, payload, expected) in cases {
            let log = ObservationLog()
            let probe = AXSubroleProbe(healthLog: { log.record($0) }, readFocus: {
                log.recordRead()
                return (status, payload.map { $0 as CFString })
            })
            let returned = probe.focusedHasSecureSubrole()
            let observations = log.values()
            XCTAssertEqual(log.readCount(), 1)
            XCTAssertEqual(observations.count, 1)
            XCTAssertEqual(returned, expected)
            guard let observed = observations.first else { continue }
            XCTAssertEqual(observed.classification, returned)
            XCTAssertEqual(observed.focusResult, status.rawValue)
            XCTAssertFalse(observed.focusedElementMatched)
            XCTAssertNil(observed.subroleResult)
            XCTAssertNil(observed.valueHidden)
            XCTAssertNil(observed.identifierMatch)
            XCTAssertNil(observed.descendantSecure)
        }
    }
}
