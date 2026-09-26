import ApplicationServices
import XCTest

@testable import MCICaptureHelperKit

final class AXTraversalReadShapeTests: XCTestCase {
    private typealias Response = (AXError, CFTypeRef?)
    private enum Signal: CaseIterable { case subrole, keyword }
    private struct Read: Equatable {
        let node: Int
        let attribute: String
    }
    private let errors: [AXError] = [
        .failure, .illegalArgument, .invalidUIElement, .invalidUIElementObserver,
        .cannotComplete, .apiDisabled, .notImplemented, .actionUnsupported,
        .notificationUnsupported, .notificationAlreadyRegistered,
        .notificationNotRegistered, .parameterizedAttributeUnsupported, .notEnoughPrecision,
    ]

    // Local identity tokens only: every attribute query below uses an injected reader.
    private func nodes(_ count: Int) -> [AXUIElement] {
        (0..<count).map { AXUIElementCreateApplication(pid_t(41_500 + $0)) }
    }

    private func probe(
        _ signal: Signal, nodes: [AXUIElement], responses: [Int: [String: Response]]
    ) -> (outcome: AXBackstopOutcome, reads: [Read]) {
        var reads: [Read] = []
        let reader: AXSubroleProbe.AttributeReader = { element, attribute in
            guard let index = nodes.firstIndex(where: { CFEqual($0, element) }) else {
                XCTFail("unexpected synthetic element")
                return (.invalidUIElement, nil)
            }
            let name = attribute as String
            reads.append(Read(node: index, attribute: name))
            if let response = responses[index]?[name] { return response }
            if name == kAXRoleAttribute { return (.success, "AXGroup" as CFString) }
            return (.noValue, nil)
        }
        let strings: (AXUIElement, CFString) -> (AXError, String?) = {
            let (status, value) = reader($0, $1)
            return (status, value as? String)
        }
        let children: (AXUIElement, CFString) -> AXSubroleProbe.ArrayReadResult = {
            AXSubroleProbe.readElementArrayAttribute($0, $1, readAttribute: reader)
        }
        let focused: (AXUIElement, CFString) throws -> AXUIElement? = {
            try AXSubroleProbe.readElementAttribute($0, $1, readAttribute: reader)
        }
        let result: AXBackstopOutcome
        switch signal {
        case .subrole:
            result = AXSubroleProbe.descendantSecureSubroleSignal(
                of: nodes[0], readString: strings, readChildren: children, readFocusedChild: focused)
        case .keyword:
            result = AXSubroleProbe.identifierRegexSignal(
                of: nodes[0], readString: strings, readChildren: children, readFocusedChild: focused)
        }
        return (result, reads)
    }

    private var secureAttributes: [String: Response] {
        [kAXSubroleAttribute: (.success, kAXSecureTextFieldSubrole as CFString),
         kAXIdentifierAttribute: (.success, "PasswordEntry" as CFString)]
    }

    func testFocusedReaderPreservesAbsentAndValidChildren() throws {
        let elements = nodes(2)
        for status in [AXError.noValue, .attributeUnsupported] {
            XCTAssertNil(try AXSubroleProbe.readElementAttribute(
                elements[0], kAXFocusedUIElementAttribute as CFString,
                readAttribute: { _, _ in (status, nil) }))
        }
        let child = try XCTUnwrap(AXSubroleProbe.readElementAttribute(
            elements[0], kAXFocusedUIElementAttribute as CFString,
            readAttribute: { _, _ in (.success, elements[1]) }))
        XCTAssertTrue(CFEqual(child, elements[1]))
    }

    func testFocusedReaderPreservesEveryActualAXError() {
        for status in errors {
            XCTAssertThrowsError(try AXSubroleProbe.readElementAttribute(
                nodes(1)[0], kAXFocusedUIElementAttribute as CFString,
                readAttribute: { _, _ in (status, nil) }
            )) { error in
                XCTAssertEqual(error as? AXSubroleProbe.ElementReadError, .ax(status))
            }
        }
    }

    func testFocusedReaderRejectsMalformedSuccess() {
        let malformed: [CFTypeRef?] = [nil, "not-an-element" as CFString, NSNumber(value: 7), [] as CFArray]
        for value in malformed {
            XCTAssertThrowsError(try AXSubroleProbe.readElementAttribute(
                nodes(1)[0], kAXFocusedUIElementAttribute as CFString,
                readAttribute: { _, _ in (.success, value) }
            )) { error in
                XCTAssertEqual(error as? AXSubroleProbe.ElementReadError, .malformedValue)
            }
        }
    }

    func testArrayReaderAcceptsOnlyDocumentedEmptyShapes() {
        let responses: [Response] = [(.noValue, nil), (.attributeUnsupported, nil), (.success, [] as CFArray)]
        for response in responses {
            let result = AXSubroleProbe.readElementArrayAttribute(
                nodes(1)[0], kAXChildrenAttribute as CFString, readAttribute: { _, _ in response })
            guard case .empty = result else { return XCTFail("documented absence must remain empty") }
        }
    }

    func testArrayReaderPreservesValidChildren() {
        let elements = nodes(3)
        let result = AXSubroleProbe.readElementArrayAttribute(
            elements[0], kAXChildrenAttribute as CFString,
            readAttribute: { _, _ in (.success, [elements[1], elements[2]] as CFArray) })
        guard case .success(let children) = result else { return XCTFail("expected valid children") }
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(CFEqual(children[0], elements[1]))
        XCTAssertTrue(CFEqual(children[1], elements[2]))
    }

    func testArrayReaderRejectsErrorsAndMalformedSuccess() {
        let malformed: [CFTypeRef?] = [nil, "not-an-array" as CFString, NSNumber(value: 7),
                                       [NSNull(), "not-an-element" as NSString] as CFArray]
        let responses: [Response] = errors.map { ($0, nil) } + malformed.map { (.success, $0) }
        for response in responses {
            let result = AXSubroleProbe.readElementArrayAttribute(
                nodes(1)[0], kAXChildrenAttribute as CFString, readAttribute: { _, _ in response })
            guard case .errored = result else { XCTFail("malformed/failed read became empty or successful"); continue }
        }
    }

    func testMixedArrayRetainsValidChildrenWithoutErasingMalformedEntries() {
        let elements = nodes(3)
        let mixed: [AnyObject] = [elements[1], NSNull(), elements[2], "bad" as NSString]
        let result = AXSubroleProbe.readElementArrayAttribute(
            elements[0], kAXChildrenAttribute as CFString,
            readAttribute: { _, _ in (.success, mixed as CFArray) })
        guard case .partial(let children) = result else { return XCTFail("mixed array must retain its error") }
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(CFEqual(children[0], elements[1]))
        XCTAssertTrue(CFEqual(children[1], elements[2]))
    }

    func testOversizedArrayRetainsOnlyBoundedChildrenAndItsIncompleteStatus() {
        let elements = nodes(AXSubroleProbe.backstopMaxNodes + 3)
        let result = AXSubroleProbe.readElementArrayAttribute(
            elements[0], kAXChildrenAttribute as CFString,
            readAttribute: { _, _ in (.success, Array(elements.dropFirst()) as CFArray) })
        guard case .partial(let children) = result else { return XCTFail("oversized array must stay incomplete") }
        XCTAssertEqual(children.count, AXSubroleProbe.backstopMaxNodes)
    }

    func testFocusedErrorsSurviveReadableStructuralChildren() {
        let elements = nodes(2)
        for signal in Signal.allCases {
            for status in errors {
                let result = probe(signal, nodes: elements, responses: [0: [
                    kAXFocusedUIElementAttribute: (status, nil),
                    kAXChildrenAttribute: (.success, [elements[1]] as CFArray),
                ]])
                XCTAssertEqual(result.outcome, .errored, "\(signal): \(status)")
            }
        }
    }

    func testMalformedFocusedChildCannotBecomeAbsent() {
        let malformed: [CFTypeRef?] = [nil, NSNumber(value: 7), "bad" as CFString]
        for signal in Signal.allCases {
            for value in malformed {
                XCTAssertEqual(probe(signal, nodes: nodes(1), responses: [0: [
                    kAXFocusedUIElementAttribute: (.success, value),
                ]]).outcome, .errored)
            }
        }
    }

    func testStructuralErrorsSurviveReadableFocusedChild() {
        let elements = nodes(2)
        for signal in Signal.allCases {
            XCTAssertEqual(probe(signal, nodes: elements, responses: [0: [
                kAXFocusedUIElementAttribute: (.success, elements[1]),
                kAXChildrenAttribute: (.cannotComplete, nil),
            ]]).outcome, .errored)
        }
    }

    func testVisitedNodeErrorsSurviveBenignVisits() {
        let elements = nodes(3)
        for signal in Signal.allCases {
            for attribute in [kAXFocusedUIElementAttribute, kAXChildrenAttribute] {
                XCTAssertEqual(probe(signal, nodes: elements, responses: [
                    0: [kAXChildrenAttribute: (.success, [elements[1], elements[2]] as CFArray)],
                    2: [attribute: (.cannotComplete, nil)],
                ]).outcome, .errored)
            }
        }
    }

    func testMalformedStructuralResponsesStayUnknown() {
        let elements = nodes(2)
        let malformed: [CFTypeRef?] = [nil, "bad" as CFString,
                                       [elements[1], NSNull()] as CFArray]
        for signal in Signal.allCases {
            for value in malformed {
                XCTAssertEqual(probe(signal, nodes: elements, responses: [0: [
                    kAXChildrenAttribute: (.success, value),
                ]]).outcome, .errored)
            }
        }
    }

    func testDescendantSubroleFailuresAndMalformedSuccessStayUnknown() {
        let elements = nodes(3)
        let responses: [Response] = errors.map { ($0, nil) } + [(.success, nil), (.success, NSNumber(value: 7))]
        for response in responses {
            XCTAssertEqual(probe(.subrole, nodes: elements, responses: [
                0: [kAXChildrenAttribute: (.success, [elements[1], elements[2]] as CFArray)],
                2: [kAXSubroleAttribute: response],
            ]).outcome, .errored)
        }
    }

    func testAbsentDescendantSubrolesRemainNegative() {
        let elements = nodes(2)
        for status in [AXError.noValue, .attributeUnsupported] {
            XCTAssertEqual(probe(.subrole, nodes: elements, responses: [
                0: [kAXChildrenAttribute: (.success, [elements[1]] as CFArray)],
                1: [kAXSubroleAttribute: (status, nil)],
            ]).outcome, .negative)
        }
    }

    func testSecureChildWinsEarlierErrorsAndStopsFurtherTraversal() {
        let elements = nodes(3)
        for signal in Signal.allCases {
            let result = probe(signal, nodes: elements, responses: [
                0: [kAXFocusedUIElementAttribute: (.cannotComplete, nil),
                    kAXChildrenAttribute: (.success, [NSNull(), elements[1], elements[2]] as CFArray)],
                1: secureAttributes,
            ])
            XCTAssertEqual(result.outcome, .positive)
            XCTAssertFalse(result.reads.contains { $0.node == 2 })
            XCTAssertFalse(result.reads.contains { $0.node == 1 && $0.attribute == kAXChildrenAttribute })
        }
    }

    func testSecureFocusedChildOnlyPathStillWorks() {
        let elements = nodes(2)
        for signal in Signal.allCases {
            XCTAssertEqual(probe(signal, nodes: elements, responses: [
                0: [kAXFocusedUIElementAttribute: (.success, elements[1])],
                1: secureAttributes,
            ]).outcome, .positive)
        }
    }

    func testNodeBudgetStillBoundsAttributeReads() {
        let limit = AXSubroleProbe.backstopMaxNodes
        let elements = nodes(limit + 3)
        for signal in Signal.allCases {
            let result = probe(signal, nodes: elements, responses: [
                0: [kAXChildrenAttribute: (.success, Array(elements.dropFirst()) as CFArray)],
                limit + 1: secureAttributes,
            ])
            XCTAssertEqual(result.outcome, .errored)
            XCTAssertEqual(Set(result.reads.map(\.node)), Set(0...limit))
        }
    }

    func testDepthBudgetIncludesBoundaryButDoesNotReadBeyondIt() {
        let limit = AXSubroleProbe.backstopMaxDepth
        let elements = nodes(limit + 2)
        for signal in Signal.allCases {
            for secureDepth in [limit, limit + 1] {
                var responses: [Int: [String: Response]] = [:]
                for index in 0..<(elements.count - 1) {
                    responses[index] = [kAXChildrenAttribute: (.success, [elements[index + 1]] as CFArray)]
                }
                responses[secureDepth, default: [:]].merge(secureAttributes) { _, new in new }
                let result = probe(signal, nodes: elements, responses: responses)
                XCTAssertEqual(result.outcome, secureDepth == limit ? .positive : .errored)
                XCTAssertTrue(result.reads.allSatisfy { $0.node <= limit })
            }
        }
    }

    func testCycleRemainsBounded() {
        let elements = nodes(1)
        for signal in Signal.allCases {
            let result = probe(signal, nodes: elements, responses: [0: [
                kAXFocusedUIElementAttribute: (.success, elements[0]),
            ]])
            XCTAssertEqual(result.outcome, .errored)
            XCTAssertLessThanOrEqual(result.reads.count, (AXSubroleProbe.backstopMaxDepth + 1) * 5 + 1)
        }
    }

    func testExactNodeBudgetWithKnownLeavesRemainsNegative() {
        let elements = nodes(AXSubroleProbe.backstopMaxNodes + 1)
        for signal in Signal.allCases {
            XCTAssertEqual(probe(signal, nodes: elements, responses: [
                0: [kAXChildrenAttribute: (.success, Array(elements.dropFirst()) as CFArray)],
            ]).outcome, .negative)
        }
    }

    func testExactDepthBudgetWithKnownLeafRemainsNegative() {
        let elements = nodes(AXSubroleProbe.backstopMaxDepth + 1)
        var responses: [Int: [String: Response]] = [:]
        for index in 0..<(elements.count - 1) {
            responses[index] = [kAXChildrenAttribute: (.success, [elements[index + 1]] as CFArray)]
        }
        for signal in Signal.allCases {
            XCTAssertEqual(probe(signal, nodes: elements, responses: responses).outcome, .negative)
        }
    }
}
