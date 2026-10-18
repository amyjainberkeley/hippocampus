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
        ("momentGone", UserFacingCopy.momentGone),
        ("momentLoadFailed", UserFacingCopy.momentLoadFailed),
        ("momentChangedNothingSaved", UserFacingCopy.momentChangedNothingSaved),
        ("saveContextFailedTitle", UserFacingCopy.saveContextFailedTitle),
        ("saveContextFailedBody", UserFacingCopy.saveContextFailedBody),
        ("copyFailedTryAgain", UserFacingCopy.copyFailedTryAgain),
        ("relatedLoadFailed", UserFacingCopy.relatedLoadFailed),
        ("recentMoments", UserFacingCopy.recentMoments(3)),
        ("exportedMoments", UserFacingCopy.exportedMoments(3)),
        ("deleteLast24hExplanation", UserFacingCopy.deleteLast24hExplanation),
        ("deleteEverythingExplanation", UserFacingCopy.deleteEverythingExplanation),
        ("meaningFiltersSeveralApps", UserFacingCopy.meaningFiltersSeveralApps),
        ("meaningMayMissMatches", UserFacingCopy.meaningMayMissMatches),
        ("hasLinkFilter", UserFacingCopy.hasLinkFilter),
        ("datesTitle", UserFacingCopy.datesTitle),
        ("moreApps", UserFacingCopy.moreApps(4)),
        ("commandFieldLabel", UserFacingCopy.commandFieldLabel),
        ("shortcutsSheetLabel", UserFacingCopy.shortcutsSheetLabel),
        ("whatsNewNothingListed", UserFacingCopy.whatsNewNothingListed),
        ("whatsNewNoNotes", UserFacingCopy.whatsNewNoNotes),
        ("whatsNewReopen", UserFacingCopy.whatsNewReopen),
        ("deleteEverythingTitle", UserFacingCopy.deleteEverythingTitle),
        ("deleteUnavailable", UserFacingCopy.deleteUnavailable),
        ("deleteAction", UserFacingCopy.deleteAction),
        ("exportEverythingAction", UserFacingCopy.exportEverythingAction),
        ("deleteLast24hAction", UserFacingCopy.deleteLast24hAction),
        ("deleteEverythingAction", UserFacingCopy.deleteEverythingAction),
        ("exportNotEncrypted", UserFacingCopy.exportNotEncrypted),
        ("savedToDownloads", UserFacingCopy.savedToDownloads),
        ("storageText", UserFacingCopy.storageText),
        ("storageScreenshots", UserFacingCopy.storageScreenshots),
        ("auditTitle", UserFacingCopy.auditTitle),
        ("auditExportAction", UserFacingCopy.auditExportAction),
        ("auditCaption", UserFacingCopy.auditCaption),
        ("auditEmpty", UserFacingCopy.auditEmpty),
        ("auditAction.range24", UserFacingCopy.auditAction(.deleteEventsInRange, details: ["range_hours": "24"])),
        ("auditAction.wipe", UserFacingCopy.auditAction(.wipeBrain, details: [:])),
        ("auditAction.export", UserFacingCopy.auditAction(.exportJson, details: [:])),
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
        ("noAnswer.needsAModel", UserFacingCopy.noAnswer("needs_apple_intelligence_or_local_model")),
        ("noAnswer.serverUnreachable", UserFacingCopy.noAnswer("local_server_unreachable")),
        ("noAnswer.modelMissing", UserFacingCopy.noAnswer("local_model_missing")),
        ("noAnswer.modelUnset", UserFacingCopy.noAnswer("local_model_unset")),
        ("noAnswer.modelNotLocal", UserFacingCopy.noAnswer("local_model_not_local")),
        ("noAnswer.serverNotLocal", UserFacingCopy.noAnswer("local_server_not_local")),
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
        // Overview's AI heading (positioning, launch decisions 2026-10-15),
        // and more of the window's own words, so the launch guard covers them.
        ("aiStartsWith", UserFacingCopy.aiStartsWith),
        ("openPage", UserFacingCopy.openPage),
        ("connectAction", UserFacingCopy.connectAction),
        ("showInHistory", UserFacingCopy.showInHistory),
        ("showEarlierTop", UserFacingCopy.showEarlier),
        ("groupWorkingOn", UserFacingCopy.groupWorkingOn),
        ("groupHowYouWork", UserFacingCopy.groupHowYouWork),
        ("groupSkills", UserFacingCopy.groupSkills),
        ("groupPeople", UserFacingCopy.groupPeople),
        ("groupStruggles", UserFacingCopy.groupStruggles),
        ("namesTitle", UserFacingCopy.namesTitle),
        ("namesBody", UserFacingCopy.namesBody),
        ("namesExample", UserFacingCopy.namesExample),
        ("folderTitle", UserFacingCopy.folderTitle),
        ("folderSubtitle", UserFacingCopy.folderSubtitle),
        ("folderEmptyBody", UserFacingCopy.folderEmptyBody),
        ("folderNothingSent", UserFacingCopy.folderNothingSent),
        ("folderScope", UserFacingCopy.folderScope),
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
    /// example the owner called out.
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

    // MARK: - Launch copy guard (professional, trustworthy tone)

    /// Rule 4 — no marketing or machine-written words.
    func testUserFacingCopyHasNoMarketingSpeak() {
        for entry in Self.allUserFacingStrings {
            if let word = CopyStyleValidator.containsMarketingSpeak(entry.text) {
                XCTFail("\(entry.name) uses marketing/machine word \u{201C}\(word)\u{201D}: \(entry.text)")
            }
        }
    }

    /// Rule 5 — status, help and empty-state copy never shouts.
    func testUserFacingCopyHasNoExclamationMarks() {
        for entry in Self.allUserFacingStrings {
            XCTAssertFalse(
                CopyStyleValidator.containsExclamation(entry.text),
                "\(entry.name) shouts with an exclamation mark: \(entry.text)"
            )
        }
    }

    /// Rule 6 — no em-dash pileups (one spaced em-dash is still fine).
    func testUserFacingCopyHasNoEmDashPileups() {
        for entry in Self.allUserFacingStrings {
            XCTAssertFalse(
                CopyStyleValidator.hasEmDashPileup(entry.text),
                "\(entry.name) stacks em-dashes: \(entry.text)"
            )
        }
    }

    /// The marketing validator catches the words it exists to catch, and
    /// clears clean copy.
    func testMarketingValidatorCatchesItsExamples() {
        XCTAssertEqual(CopyStyleValidator.containsMarketingSpeak("Seamlessly unlock your flow"), "seamlessly")
        XCTAssertEqual(CopyStyleValidator.containsMarketingSpeak("An AI-powered assistant"), "ai-powered")
        XCTAssertNotNil(CopyStyleValidator.containsMarketingSpeak("Supercharge your Mac"))
        XCTAssertNil(CopyStyleValidator.containsMarketingSpeak("Nothing is lost. Try again in a moment."))
        XCTAssertTrue(CopyStyleValidator.containsExclamation("All set!"))
        XCTAssertFalse(CopyStyleValidator.containsExclamation("All set."))
        XCTAssertTrue(CopyStyleValidator.hasEmDashPileup("one \u{2014} two \u{2014} three"))
        XCTAssertFalse(CopyStyleValidator.hasEmDashPileup("safe \u{2014} then stop"))
        // "AI" on its own is fine; only the hype compound is banned.
        XCTAssertNil(CopyStyleValidator.containsMarketingSpeak("Copy for your AI"))
    }

    /// Positioning (launch decisions, 2026-10-15): the window leads with how
    /// your AI starts, not what it \u{201C}already knows\u{201D} — the latter
    /// echoes a competitor's launch headline.
    func testAIHeadingLeadsWithHowYourAIStarts() {
        XCTAssertEqual(UserFacingCopy.aiStartsWith, "What your AI starts with")
        XCTAssertFalse(UserFacingCopy.aiStartsWith.lowercased().contains("already knows"))
    }
}
