import ApplicationServices
import XCTest
@testable import MCICaptureHelperKit

final class AXTraversalDiagnosticsTests: XCTestCase {
    private typealias Response = (AXError, CFTypeRef?)
    private struct Result {
        let outcome: AXBackstopOutcome
        let failures: [AXTraversalFailure]
        let reads: [String]
    }

    // AX references are local identity tokens. All reads use fabricated responses.
    private func nodes(_ count: Int) -> [AXUIElement] {
        (0..<count).map { AXUIElementCreateApplication(pid_t(43_000 + $0)) }
    }

    private func probe(
        _ nodes: [AXUIElement], _ responses: [Int: [String: Response]], diagnostics: Bool = true
    ) -> Result {
        var reads: [String] = []
        var failures: [AXTraversalFailure] = []
        let reader: AXSubroleProbe.AttributeReader = { element, attribute in
            guard let index = nodes.firstIndex(where: { CFEqual($0, element) }) else {
                XCTFail("unexpected synthetic node")
                return (.invalidUIElement, nil)
            }
            let name = attribute as String
            reads.append("\(index):\(name)")
            return responses[index]?[name] ?? (.noValue, nil)
        }
        let result = AXSubroleProbe.descendantSecureSubroleSignal(
            of: nodes[0],
            readString: { let (status, value) = reader($0, $1); return (status, value as? String) },
            readChildren: { AXSubroleProbe.readElementArrayAttribute($0, $1, readAttribute: reader) },
            readFocusedChild: { try AXSubroleProbe.readElementAttribute($0, $1, readAttribute: reader) },
            onFailure: diagnostics ? { failures.append($0) } : nil
        )
        return Result(outcome: result, failures: failures, reads: reads)
    }

    func testFirstFocusedFailureKeepsStatusWithoutLaterErrorsOverwritingIt() throws {
        let result = probe(nodes(1), [0: [
            kAXFocusedUIElementAttribute: (.cannotComplete, nil),
            kAXChildrenAttribute: (.apiDisabled, nil),
        ]])
        XCTAssertEqual(result.outcome, .errored)
        XCTAssertEqual(result.failures.count, 1)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.reason, .focusedRead)
        XCTAssertEqual(failure.status, -25204)
        XCTAssertEqual(failure.depth, 0)
        XCTAssertEqual(failure.visitedDescendants, 0)
        XCTAssertFalse(failure.ancestorLinkObserved)
    }

    func testMalformedFocusedPayloadIsDistinguishedWithoutExposingItsValue() throws {
        let result = probe(nodes(1), [0: [
            kAXFocusedUIElementAttribute: (.success, "SYNTHETIC_PRIVATE_LABEL" as CFString),
        ]])
        XCTAssertEqual(result.outcome, .errored)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.reason, .focusedMalformed)
        XCTAssertEqual(failure.status, 0)
        XCTAssertFalse(String(describing: failure).contains("SYNTHETIC_PRIVATE_LABEL"))
    }

    func testChildrenFailuresDistinguishAPIStatusMalformedAndIncompleteReads() throws {
        let elements = nodes(2)
        let cases: [(Response, AXTraversalFailureReason, Int32?)] = [
            ((.apiDisabled, nil), .childrenRead, -25211),
            ((.success, "SYNTHETIC_PRIVATE_LABEL" as CFString), .childrenMalformed, 0),
            ((.success, [NSNull()] as CFArray), .childrenMalformed, 0),
            ((.success, [elements[1], NSNull()] as CFArray), .childrenMalformed, 0),
            // A malformed entry still fails closed when the array is also over-long.
            ((.success, ([NSNull()] + Array(repeating: elements[1], count: 33)) as CFArray), .childrenMalformed, 0),
        ]
        for (response, reason, status) in cases {
            let result = probe(elements, [0: [kAXChildrenAttribute: response]])
            XCTAssertEqual(result.outcome, .errored)
            let failure = try XCTUnwrap(result.failures.first)
            XCTAssertEqual(failure.reason, reason)
            XCTAssertEqual(failure.status, status)
            XCTAssertEqual(failure.depth, 0)
        }
    }

    func testChildrenPastThePerNodeLimitAreOutsideTheSearch() {
        let elements = nodes(2)
        let result = probe(elements, [0: [
            kAXChildrenAttribute: (.success, Array(repeating: elements[1], count: 33) as CFArray),
        ]])
        XCTAssertEqual(result.outcome, .negative)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testDescendantSubroleFailureRecordsTheVisitedChild() throws {
        let elements = nodes(2)
        for (response, reason): (Response, AXTraversalFailureReason) in [
            ((.cannotComplete, nil), .subroleRead), ((.success, nil), .subroleMalformed),
        ] {
            let result = probe(elements, [
                0: [kAXChildrenAttribute: (.success, [elements[1]] as CFArray)],
                1: [kAXSubroleAttribute: response],
            ])
            XCTAssertEqual(result.outcome, .errored)
            let failure = try XCTUnwrap(result.failures.first)
            XCTAssertEqual(failure.reason, reason)
            XCTAssertEqual(failure.status, response.0.rawValue)
            XCTAssertEqual(failure.depth, 1)
            XCTAssertEqual(failure.visitedDescendants, 1)
        }
    }

    /// The live failure behind 2026-09-14 onward: the focused element names
    /// itself as its own focused descendant. Walking that link re-read the same
    /// subrole to the depth bound and reported unknown, so every frame was
    /// suppressed. The link is now skipped and the element's children read.
    func testSelfReferenceIsSkippedWithoutExtraReads() {
        let elements = nodes(1)
        let responses: [Int: [String: Response]] = [0: [
            kAXFocusedUIElementAttribute: (.success, elements[0]),
        ]]
        let result = probe(elements, responses)
        let without = probe(elements, responses, diagnostics: false)
        XCTAssertEqual(result.outcome, .negative)
        XCTAssertEqual(result.outcome, without.outcome)
        XCTAssertEqual(result.reads, without.reads)
        XCTAssertEqual(result.reads, ["0:\(kAXFocusedUIElementAttribute)", "0:\(kAXChildrenAttribute)"])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testExhaustingTheNodeBudgetIsTheEndOfTheSearchNotAFailure() {
        let elements = nodes(34)
        let result = probe(elements, [0: [
            kAXFocusedUIElementAttribute: (.success, elements[1]),
            kAXChildrenAttribute: (.success, Array(elements[2...33]) as CFArray),
        ]])
        XCTAssertEqual(result.outcome, .negative)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.reads.contains { $0.hasPrefix("33:") }, "the 33rd descendant is past the budget")
    }

    func testSecurePositiveStillWinsAnEarlierErrorAndKnownLeavesHaveNoFailure() {
        let elements = nodes(3)
        let result = probe(elements, [
            0: [kAXFocusedUIElementAttribute: (.cannotComplete, nil),
                kAXChildrenAttribute: (.success, [elements[1], elements[2]] as CFArray)],
            1: [kAXSubroleAttribute: (.success, kAXSecureTextFieldSubrole as CFString)],
        ])
        XCTAssertEqual(result.outcome, .positive)
        XCTAssertEqual(result.failures.first?.reason, .focusedRead)
        XCTAssertFalse(result.reads.contains { $0.hasPrefix("2:") })
        let negative = probe(elements, [0: [kAXChildrenAttribute: (.success, [elements[1]] as CFArray)]])
        XCTAssertEqual(negative.outcome, .negative)
        XCTAssertTrue(negative.failures.isEmpty)
    }

    func testTraversalFailureReachesContentFreeHealthLineWithinExistingRateLimit() throws {
        let result = probe(nodes(1), [0: [kAXChildrenAttribute: (.apiDisabled, nil)]])
        let failure = try XCTUnwrap(result.failures.first)
        let snapshot = AXProbeHealthSnapshot(
            focusResult: 0, focusedElementMatched: true, subroleResult: -25205,
            valueHidden: .negative, identifierMatch: .negative,
            descendantSecure: result.outcome, classification: nil, descendantFailure: failure
        )
        let reporter = AXProbeHealthReporter()
        let line = try XCTUnwrap(reporter.line(for: snapshot, at: 100))
        XCTAssertTrue(line.contains("descendant_reason=children-read"))
        XCTAssertTrue(line.contains("descendant_status=-25211"))
        XCTAssertTrue(line.contains("descendant_depth=0"))
        XCTAssertTrue(line.contains("descendant_visited=0"))
        XCTAssertTrue(line.contains("descendant_ancestor_link=false"))
        XCTAssertNil(reporter.line(for: snapshot, at: 129.99))
        XCTAssertNotNil(reporter.line(for: snapshot, at: 130))
    }
}
