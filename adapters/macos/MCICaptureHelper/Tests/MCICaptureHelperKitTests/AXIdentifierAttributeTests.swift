import ApplicationServices
import XCTest

@testable import MCICaptureHelperKit

final class AXIdentifierAttributeTests: XCTestCase {
    private func probe(
        labels: [String: (AXError, String?)] = [:],
        role: (AXError, String?) = (.success, "AXTextArea"),
        childLabels: [String: (AXError, String?)]? = nil,
        childrenFail: Bool = false,
        focusedOnly: Bool = false
    ) -> AXBackstopOutcome {
        // These local AX references are identity tokens only. Every read is injected.
        let root = AXUIElementCreateApplication(31_415)
        let child = AXUIElementCreateApplication(31_416)
        return AXSubroleProbe.identifierRegexSignal(
            of: root,
            readString: { element, attribute in
                if attribute as String == kAXRoleAttribute { return role }
                let values = CFEqual(element, root) ? labels : (childLabels ?? [:])
                return values[attribute as String] ?? (.attributeUnsupported, nil)
            },
            readChildren: { element, _ in
                if childrenFail { return .errored }
                return CFEqual(element, root) && childLabels != nil && !focusedOnly ? .success([child]) : .empty
            },
            readFocusedChild: { element, _ in
                CFEqual(element, root) && childLabels != nil && focusedOnly ? child : nil
            }
        )
    }

    func testProductionKeywordPathAcceptsAbsentLabelsOnAnOrdinaryTextView() {
        XCTAssertEqual(probe(), .negative)
    }

    func testProductionKeywordPathDoesNotHideRoleReadErrors() {
        for role: (AXError, String?) in [
            (.cannotComplete, nil), (.success, nil), (.noValue, nil),
            (.attributeUnsupported, nil), (.success, ""),
        ] {
            XCTAssertEqual(probe(labels: [kAXTitleAttribute: (.success, "Editor")], role: role), .errored)
        }
    }

    func testProductionKeywordPathPreservesChildErrorsAfterReadableRoot() {
        XCTAssertEqual(probe(
            labels: [kAXTitleAttribute: (.success, "Editor")], role: (.success, "AXGroup"),
            childLabels: [kAXTitleAttribute: (.cannotComplete, nil)]
        ), .errored)
        XCTAssertEqual(probe(
            labels: [kAXTitleAttribute: (.success, "Editor")], role: (.success, "AXGroup"),
            childrenFail: true
        ), .errored)
    }

    func testProductionKeywordPathPreservesRootErrorAfterOrdinaryChild() {
        XCTAssertEqual(probe(
            labels: [kAXTitleAttribute: (.cannotComplete, nil)], role: (.success, "AXGroup"),
            childLabels: [kAXTitleAttribute: (.success, "Editor")]
        ), .errored)
    }

    func testProductionKeywordPathKeepsPositiveChildDespiteRootError() {
        XCTAssertEqual(probe(
            labels: [kAXTitleAttribute: (.cannotComplete, nil)], role: (.success, "AXGroup"),
            childLabels: [kAXTitleAttribute: (.success, "PasswordEntry")]
        ), .positive)
    }

    func testFocusedChildOnlyPathStillFindsSecureLabels() {
        XCTAssertEqual(probe(
            role: (.success, "AXGroup"),
            childLabels: [kAXIdentifierAttribute: (.success, "PasswordEntry")], focusedOnly: true
        ), .positive)
    }

    func testPositiveKeywordStopsBeforeAdditionalAXReads() {
        let root = AXUIElementCreateApplication(31_415)
        var reads = 0
        let result = AXSubroleProbe.identifierRegexSignal(of: root, readString: { _, _ in
            reads += 1
            return (.success, "PasswordEntry")
        })
        XCTAssertEqual(result, .positive)
        XCTAssertEqual(reads, 1, "A positive secure label must short-circuit further AX calls")
    }

    func testSuccessfulEmptyLabelIsKnownEmptyMetadata() {
        XCTAssertEqual(probe(labels: [kAXTitleAttribute: (.success, "")]), .negative)
    }

    func testAbsentOptionalLabelsAreNotAnAXReadFailure() {
        XCTAssertEqual(AXSubroleProbe.identifierAttributesOutcome([
            (.attributeUnsupported, nil), (.noValue, nil), (.attributeUnsupported, nil),
        ]), .negative)
    }

    func testKnownOrdinaryLabelAndAbsentOptionalLabelsAreNegative() {
        XCTAssertEqual(AXSubroleProbe.identifierAttributesOutcome([
            (.success, "document-editor"), (.noValue, nil), (.attributeUnsupported, nil),
        ]), .negative)
    }

    func testRealReadFailuresStayUnknownEvenWithAnOrdinaryLabel() {
        for status in [AXError.apiDisabled, .cannotComplete, .failure, .invalidUIElement] {
            XCTAssertEqual(AXSubroleProbe.identifierAttributesOutcome([
                (.success, "document-editor"), (status, nil), (.noValue, nil),
            ]), .errored, "A readable sibling must not hide \(status)")
        }
    }

    func testSuccessfulReadWithoutAStringIsMalformedNotAbsent() {
        XCTAssertEqual(AXSubroleProbe.identifierAttributesOutcome([
            (.success, "document-editor"), (.success, nil), (.noValue, nil),
        ]), .errored)
    }

    func testPositiveSecureLabelWinsRegardlessOfOtherErrors() {
        for reads: [(AXError, String?)] in [
            [(.cannotComplete, nil), (.success, "PasswordEntry"), (.noValue, nil)],
            [(.success, "PasswordEntry"), (.cannotComplete, nil), (.noValue, nil)],
        ] {
            XCTAssertEqual(AXSubroleProbe.identifierAttributesOutcome(reads), .positive)
        }
    }

    func testAbsenceOfLabelsCannotOverrideSecureSubroleOrMissingFocus() {
        let absent = AXSubroleProbe.identifierAttributesOutcome([
            (.attributeUnsupported, nil), (.noValue, nil), (.attributeUnsupported, nil),
        ])
        XCTAssertEqual(AXSubroleProbe.classify(
            focusResult: .success, focusedRefMatched: true, subroleResult: .success,
            subroleValue: kAXSecureTextFieldSubrole as String, identifierRegexMatch: absent
        ), true)
        XCTAssertNil(AXSubroleProbe.classify(
            focusResult: .apiDisabled, focusedRefMatched: false, subroleResult: .success,
            subroleValue: nil, identifierRegexMatch: absent
        ))
    }
}
