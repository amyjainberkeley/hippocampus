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
        ("deleteBlockedBanner", UserFacingCopy.deleteBlockedBanner),
        ("dashboardLoadFailedBanner", UserFacingCopy.dashboardLoadFailedBanner),
        ("exportFailedBanner", UserFacingCopy.exportFailedBanner),
        ("auditExportFailedBanner", UserFacingCopy.auditExportFailedBanner),
        ("customNamesWriteFailed", UserFacingCopy.customNamesWriteFailed),
        ("unexpectedErrorGeneric", UserFacingCopy.unexpectedErrorGeneric),
        ("tccRevokedNotificationTitle", UserFacingCopy.tccRevokedNotificationTitle),
        ("mcpAgentMissing", UserFacingCopy.mcpAgentMissing),
        ("mcpRegisterFailed", UserFacingCopy.mcpRegisterFailed),
        ("emptyPrivacyEventsFreshTitle", UserFacingCopy.emptyPrivacyEventsFreshTitle),
        ("askKeyPhrase", UserFacingCopy.askKeyPhrase("⌃⇧Space")),
        ("writtenOnThisMac", UserFacingCopy.writtenOnThisMac(by: "apple-foundation-models") ?? ""),
        ("verdictNotSaved", UserFacingCopy.verdictNotSaved),
        ("momentTextHeading.screen", UserFacingCopy.momentTextHeading(sourceKind: "screen_ocr")),
        ("momentTextHeading.page", UserFacingCopy.momentTextHeading(sourceKind: "browser_page")),
        ("momentTextHeading.other", UserFacingCopy.momentTextHeading(sourceKind: nil)),
        ("momentTextLoading", UserFacingCopy.momentTextLoading),
        ("momentTextEmpty", UserFacingCopy.momentTextEmpty),
        ("momentTextFirstPart", UserFacingCopy.momentTextFirstPart),
        ("momentTextExcerpt", UserFacingCopy.momentTextExcerpt),
        ("copyTextAction", UserFacingCopy.copyTextAction),
        ("alsoInThisWindow", UserFacingCopy.alsoInThisWindow),
        ("lineCount", UserFacingCopy.lineCount(12)),
        ("windowTitle", UserFacingCopy.windowTitle),
        ("footerRemembering", UserFacingCopy.footerRemembering),
        ("footerNotRemembering", UserFacingCopy.footerNotRemembering),
        ("footerNoStatus", UserFacingCopy.footerNoStatus),
        ("footerHelp", UserFacingCopy.footerHelp),
        ("askPlaceholder", UserFacingCopy.askPlaceholder),
        ("searchOnlyPlaceholder", UserFacingCopy.searchOnlyPlaceholder),
        ("askKeyHintReturn", UserFacingCopy.askKeyHintReturn),
        ("askKeyHintCommandReturn", UserFacingCopy.askKeyHintCommandReturn),
        ("askThinking", UserFacingCopy.askThinking),
        ("askFailed", UserFacingCopy.askFailed),
        ("tryAgainAction", UserFacingCopy.tryAgainAction),
        ("stopAction", UserFacingCopy.stopAction),
        ("sourcesHeading", UserFacingCopy.sourcesHeading),
        ("moreFromYourMemory", UserFacingCopy.moreFromYourMemory),
        ("filtersAction", UserFacingCopy.filtersAction),
        ("clearAction", UserFacingCopy.clearAction),
        ("nothingMatched", UserFacingCopy.nothingMatched),
        ("matchModeLabel", UserFacingCopy.matchModeLabel),
        ("matchModeExact", UserFacingCopy.matchModeExact),
        ("matchModeMeaning", UserFacingCopy.matchModeMeaning),
        ("matchModeHelp", UserFacingCopy.matchModeHelp),
        ("meaningFiltersUnavailable", UserFacingCopy.meaningFiltersUnavailable),
        ("copyForYourAI", UserFacingCopy.copyForYourAI),
        ("copyForYourAIHelp", UserFacingCopy.copyForYourAIHelp),
        ("copiedToast", UserFacingCopy.copiedToast),
        ("copyFailedTitle", UserFacingCopy.copyFailedTitle),
        ("copyFailedBody", UserFacingCopy.copyFailedBody),
        ("historyEmptyToday", UserFacingCopy.historyEmptyToday),
        ("historyEmptyPastDay", UserFacingCopy.historyEmptyPastDay),
        ("historyLoadFailed", UserFacingCopy.historyLoadFailed),
        ("historyLoadFailedBody", UserFacingCopy.historyLoadFailedBody),
        ("previousDay", UserFacingCopy.previousDay),
        ("nextDay", UserFacingCopy.nextDay),
        ("todayAction", UserFacingCopy.todayAction),
        ("backToResults", UserFacingCopy.backToResults),
        ("backToHistory", UserFacingCopy.backToHistory),
        ("wholeDayAction", UserFacingCopy.wholeDayAction),
        ("showEarlier", UserFacingCopy.showEarlier),
        ("commandNewQuestion", UserFacingCopy.commandNewQuestion),
        ("commandNewQuestionDetail", UserFacingCopy.commandNewQuestionDetail),
        ("commandHistory", UserFacingCopy.commandHistory),
        ("commandHistoryDetail", UserFacingCopy.commandHistoryDetail),
        ("commandPreferences", UserFacingCopy.commandPreferences),
        ("commandNames", UserFacingCopy.commandNames),
        ("commandNamesDetail", UserFacingCopy.commandNamesDetail),
        ("commandRefresh", UserFacingCopy.commandRefresh),
        ("commandRefreshDetail", UserFacingCopy.commandRefreshDetail),
        ("refreshingToast", UserFacingCopy.refreshingToast),
        ("commandSupportReport", UserFacingCopy.commandSupportReport),
        ("commandSupportReportDetail", UserFacingCopy.commandSupportReportDetail),
        ("commandShortcuts", UserFacingCopy.commandShortcuts),
        ("commandWhatsNew", UserFacingCopy.commandWhatsNew),
        ("commandWhatsNewDetail", UserFacingCopy.commandWhatsNewDetail),
        ("commandCloseWindow", UserFacingCopy.commandCloseWindow),
        ("commandFolderContext", UserFacingCopy.commandFolderContext),
        ("goMenu", UserFacingCopy.goMenu),
        ("commandFind", UserFacingCopy.commandFind),
        ("noScreenshot", UserFacingCopy.noScreenshot),
        ("screenshotMissing", UserFacingCopy.screenshotMissing),
        ("openInApp", UserFacingCopy.openInApp),
        ("openLink", UserFacingCopy.openLink),
        ("showRelated", UserFacingCopy.showRelated),
        ("showRelatedHelp", UserFacingCopy.showRelatedHelp),
        ("previousAction", UserFacingCopy.previousAction),
        ("nextAction", UserFacingCopy.nextAction),
        ("closeAction", UserFacingCopy.closeAction),
        ("screenshotLoadFailed", UserFacingCopy.screenshotLoadFailed),
        ("saveContextAction", UserFacingCopy.saveContextAction),
        ("readAgainAction", UserFacingCopy.readAgainAction),
        ("readingAgain", UserFacingCopy.readingAgain),
        ("readAgainCaption", UserFacingCopy.readAgainCaption),
        ("readAgainUnreadable", UserFacingCopy.readAgainUnreadable),
        ("readAgainTimedOut", UserFacingCopy.readAgainTimedOut),
        ("readAgainBlocked", UserFacingCopy.readAgainBlocked),
        ("readAgainUnavailable", UserFacingCopy.readAgainUnavailable),
        ("noAnswer.off", UserFacingCopy.noAnswer("apple_intelligence_off")),
        ("noAnswer.device", UserFacingCopy.noAnswer("device_not_eligible")),
        ("noAnswer.other", UserFacingCopy.noAnswer(nil)),
        ("momentSource.screen", UserFacingCopy.momentSource(sourceKind: "screen_ocr")),
        ("momentSource.page", UserFacingCopy.momentSource(sourceKind: "browser_page")),
        ("sourceLine", UserFacingCopy.sourceLine(app: "Safari", time: "2:14 PM")),
        ("askKeyHelp", UserFacingCopy.askKeyHelp("Press Shift twice")),
        ("askKeyHelp.none", UserFacingCopy.askKeyHelp("")),
        ("showRelatedCount", UserFacingCopy.showRelatedCount(3)),
        ("mentions", UserFacingCopy.mentions("Jordan Lee")),
        ("moreNames", UserFacingCopy.moreNames(2)),
        ("names", UserFacingCopy.names(["Jordan Lee", "JL"])),
    ] + UserFacingCopy.askKeyNames.sorted { $0.key < $1.key }.flatMap { entry -> [(name: String, text: String)] in
        [(name: "askKeyNames.\(entry.key).label", text: entry.value.label),
         (name: "askKeyNames.\(entry.key).phrase", text: entry.value.phrase)]
    }

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
            UserFacingCopy.deleteBlockedBanner,
            UserFacingCopy.dashboardLoadFailedBanner,
            UserFacingCopy.exportFailedBanner,
            UserFacingCopy.auditExportFailedBanner,
            UserFacingCopy.customNamesWriteFailed,
            UserFacingCopy.unexpectedErrorGeneric,
            UserFacingCopy.mcpAgentMissing,
            UserFacingCopy.mcpRegisterFailed,
            UserFacingCopy.verdictNotSaved,
            UserFacingCopy.askFailed,
            UserFacingCopy.copyFailedBody,
            UserFacingCopy.historyLoadFailedBody,
            UserFacingCopy.readAgainTimedOut,
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
