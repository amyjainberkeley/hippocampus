// CopyStyleTests.swift — grep-lint that user-facing copy strings
// never contain raw error codes or engineer jargon.
//
// Cycle 8.54 product-readiness audit polish gap #2 fix — see
// `docs/design/copy-style-guide.md` §2 (no error codes) and §3
// (no jargon). Every `UserFacingCopy` constant is enumerated below
// and asserted against both rules + a "names a next action" check
// for failure copy.

import XCTest
@testable import RecallUIKit

final class CopyStyleTests: XCTestCase {

    /// Every static-string constant on `UserFacingCopy`.
    static let allUserFacingStrings: [(name: String, text: String)] = [
        ("memoryUnreachableTitle", UserFacingCopy.memoryUnreachableTitle),
        ("memoryUnreachableBody", UserFacingCopy.memoryUnreachableBody),
        ("openHippocampusAction", UserFacingCopy.openHippocampusAction),
        ("briefLoadFailedTitle", UserFacingCopy.briefLoadFailedTitle),
        ("timelineLoadFailedTitle", UserFacingCopy.timelineLoadFailedTitle),
        ("loadFailedBody", UserFacingCopy.loadFailedBody),
        ("eventDetailFailedTitle", UserFacingCopy.eventDetailFailedTitle),
        ("eventNoLongerAvailable", UserFacingCopy.eventNoLongerAvailable),
        ("deleteFailedBanner", UserFacingCopy.deleteFailedBanner),
        ("dashboardLoadFailedBanner", UserFacingCopy.dashboardLoadFailedBanner),
        ("exportFailedBanner", UserFacingCopy.exportFailedBanner),
        ("auditExportFailedBanner", UserFacingCopy.auditExportFailedBanner),
        ("customNamesWriteFailed", UserFacingCopy.customNamesWriteFailed),
        ("unexpectedErrorGeneric", UserFacingCopy.unexpectedErrorGeneric),
        ("tccRevokedNotificationTitle", UserFacingCopy.tccRevokedNotificationTitle),
        ("mcpAgentMissing", UserFacingCopy.mcpAgentMissing),
        ("mcpRegisterFailed", UserFacingCopy.mcpRegisterFailed),
        ("emptyPrivacyEventsFreshTitle", UserFacingCopy.emptyPrivacyEventsFreshTitle),
    ]

    /// Rule 1 — no raw error codes.
    func testUserFacingCopyDoesNotLeakErrorCodes() {
        for entry in Self.allUserFacingStrings {
            XCTAssertFalse(
                CopyStyleValidator.containsRawErrorCode(entry.text),
                "\(entry.name) leaks a raw error code: \(entry.text)"
            )
        }
    }

    /// The validator itself must catch the load-bearing "-3815"
    /// example the CEO called out.
    func testValidatorCatchesSCStreamStyleErrorCode() {
        XCTAssertTrue(
            CopyStyleValidator.containsRawErrorCode("SCStream failed with -3815")
        )
        XCTAssertTrue(
            CopyStyleValidator.containsRawErrorCode("open(dir) failed (errno=13)")
        )
        XCTAssertTrue(
            CopyStyleValidator.containsRawErrorCode("Mach error 0xDEADBEEF")
        )
        // Clean copy passes.
        XCTAssertFalse(
            CopyStyleValidator.containsRawErrorCode("Delete the last 24 hours?")
        )
    }

    /// Rule 2 — no engineer jargon.
    func testUserFacingCopyContainsNoJargon() {
        for entry in Self.allUserFacingStrings {
            if let word = CopyStyleValidator.containsJargon(entry.text) {
                XCTFail("\(entry.name) contains banned jargon \u{201C}\(word)\u{201D}: \(entry.text)")
            }
        }
    }

    /// Rule 3 — failure copy names a next action verb.
    func testFailureCopyNamesANextAction() {
        let verbs = ["try", "open", "reinstall", "retry", "check",
                     "relaunch", "reopen", "send feedback"]
        let failures = [
            UserFacingCopy.memoryUnreachableBody,
            UserFacingCopy.loadFailedBody,
            UserFacingCopy.deleteFailedBanner,
            UserFacingCopy.dashboardLoadFailedBanner,
            UserFacingCopy.exportFailedBanner,
            UserFacingCopy.auditExportFailedBanner,
            UserFacingCopy.customNamesWriteFailed,
            UserFacingCopy.unexpectedErrorGeneric,
            UserFacingCopy.mcpAgentMissing,
            UserFacingCopy.mcpRegisterFailed,
        ]
        for s in failures {
            let lower = s.lowercased()
            XCTAssertTrue(
                verbs.contains(where: { lower.contains($0) }),
                "failure copy names no next action: \(s)"
            )
        }
    }

    /// Regression fence — the load-bearing rewrites must not slide
    /// back into their old jargon.
    func testMemoryUnreachableTitleAvoidsBrainJargon() {
        XCTAssertFalse(
            UserFacingCopy.memoryUnreachableTitle.lowercased().contains("brain")
        )
        XCTAssertTrue(
            UserFacingCopy.memoryUnreachableTitle.contains("Hippocampus")
        )
        let stale = UserFacingCopy.eventNoLongerAvailable.lowercased()
        XCTAssertFalse(stale.contains("brain"))
        XCTAssertFalse(stale.contains("suppressed"))
    }
}
