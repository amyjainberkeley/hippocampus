import XCTest
@testable import OnboardingKit

/// Every string setup shows, held exactly where a claim is made, and the
/// style rules (spec-copy S2, RULINGS V) for all of them.
final class OnboardingCopyTests: XCTestCase {
    // MARK: - The Promise

    func testThePromiseSaysWhatTheCodeDoes() {
        XCTAssertEqual(OnboardingCopy.promiseTitle, "Before it starts")
        XCTAssertEqual(OnboardingCopy.promiseBody,
                       "When you click Start Remembering, Hippocampus begins reading your screen.")
        // Setup connects no AI tool, so sharing waits on the person.
        XCTAssertEqual(OnboardingCopy.promiseStays(kept: "kept 90 days"),
                       "Text and screenshots, encrypted, kept 90 days. Nothing is uploaded by Hippocampus. It shares them with your AI only if you connect it. What your AI reads goes to the company that runs it.")
        // The helper never reads a broad, enumerated set of password apps,
        // but no list names every one, so the line says "known" and never
        // promises every password manager. Private windows are skipped only
        // when they show it (RULINGS G8).
        XCTAssertEqual(OnboardingCopy.promiseNeverRead,
                       "Password fields and known password apps. Private browser windows are skipped when they show they are private.")
        // Pausing stops the capture helper; quitting stops it and the agent.
        XCTAssertEqual(OnboardingCopy.promiseStop, "Pause or quit from the menu bar, and reading stops.")
        // The menu-bar mark's promise, word for word (RULINGS B1), read by
        // VoiceOver on the legend that draws it.
        XCTAssertEqual(OnboardingCopy.dotPromise, "A solid dot means it is remembering. No solid dot means it is not.")
        XCTAssertEqual(OnboardingCopy.dotLegendTitle, "In the menu bar")
        XCTAssertEqual(OnboardingCopy.dotLegendOn, "Remembering")
        XCTAssertEqual(OnboardingCopy.dotLegendOff, "Not remembering")
        XCTAssertEqual(OnboardingCopy.openAtLogin, "Open Hippocampus at login")
        XCTAssertEqual(OnboardingCopy.startRemembering, "Start Remembering")
        XCTAssertTrue(OnboardingCopy.promiseBody.contains(OnboardingCopy.startRemembering))
        XCTAssertTrue(OnboardingCopy.permissionsNothingYet.contains(OnboardingCopy.startRemembering))
    }

    func testEachPromiseShowsOneSentenceALineAndDropsNothing() {
        // The Promise shows each detail one sentence a line, so it reads as
        // facts. The lines joined again are the checked words, exactly.
        let stays = OnboardingCopy.promiseStays(kept: "kept 90 days")
        XCTAssertEqual(OnboardingCopy.sentences(stays), [
            "Text and screenshots, encrypted, kept 90 days.",
            "Nothing is uploaded by Hippocampus.",
            "It shares them with your AI only if you connect it.",
            "What your AI reads goes to the company that runs it.",
        ])
        XCTAssertEqual(OnboardingCopy.sentences(OnboardingCopy.promiseNeverRead), [
            "Password fields and known password apps.",
            OnboardingCopy.privateWindowsSkipped,
        ])
        XCTAssertEqual(OnboardingCopy.sentences(OnboardingCopy.promiseStop), [OnboardingCopy.promiseStop])
        for kept in ["kept 90 days", "kept 1 day", "kept until you delete it"] {
            for detail in [OnboardingCopy.promiseStays(kept: kept), OnboardingCopy.promiseNeverRead,
                           OnboardingCopy.promiseStop] {
                XCTAssertEqual(OnboardingCopy.sentences(detail).joined(separator: " "), detail)
            }
        }
    }

    func testThePromiseNeverSaysNeverUploaded() {
        let promise = OnboardingCopy.promiseStays(kept: "kept 90 days").lowercased()
        XCTAssertFalse(promise.contains("never uploaded"))
        XCTAssertTrue(promise.contains("only if you connect it"), "sharing waits on the person")
        XCTAssertTrue(promise.contains("goes to the company that runs"), "the provider boundary stays at consent")
        XCTAssertFalse(promise.contains("ai tools"), "\"your AI\" in sentences; AI Tools is only the pane's name")
    }

    func testInReviewThePromiseIsTitledLikeTheNeverReadPanel() {
        // Remembering has started, so "Before it starts" is not true then.
        XCTAssertEqual(OnboardingCopy.promiseTitle(isReview: false), "Before it starts")
        XCTAssertEqual(OnboardingCopy.promiseTitle(isReview: true), "What is never read")
        XCTAssertEqual(OnboardingCopy.promiseTitle(isReview: true), OnboardingCopy.neverReadTitle)
    }

    func testThePromiseNeverPromisesEveryPasswordManager() {
        XCTAssertFalse(OnboardingCopy.promiseNeverRead.lowercased().contains("password manager"))
        XCTAssertTrue(OnboardingCopy.promiseNeverRead.hasPrefix("Password fields and known password apps."),
                      "only the apps the helper knows are promised")
    }

    func testPrivateBrowserWindowsArePromisedOnlyWhenTheyShowIt() {
        // Browsers are read like every other window, and a private one is
        // skipped when Hippocampus can tell without asking (RULINGS G8).
        XCTAssertEqual(OnboardingCopy.privateWindowsSkipped,
                       "Private browser windows are skipped when they show they are private.")
        XCTAssertTrue(OnboardingCopy.promiseNeverRead.hasSuffix(OnboardingCopy.privateWindowsSkipped))
        XCTAssertTrue(OnboardingCopy.appAccessSkipped.hasSuffix(OnboardingCopy.privateWindowsSkipped))
        for string in newStrings {
            let lower = string.lowercased()
            XCTAssertFalse(lower.contains("and private browser windows"), "\"\(string)\" lists them as never read")
            XCTAssertFalse(lower.contains("private browser windows."), "\"\(string)\" lists them as never read")
        }
    }

    func testNoStringSaysABrowserNeedsAnExtensionOrAPromptToBeRead() {
        for string in newStrings {
            let lower = string.lowercased()
            for claim in ["until you add the extension", "isn’t read until", "macos will ask about",
                          "choose allow so hippocampus", "add extension"] {
                XCTAssertFalse(lower.contains(claim), "\"\(string)\" says \"\(claim)\"")
            }
        }
    }

    func testInReviewThePromiseHasNoStartRememberingBody() {
        XCTAssertEqual(OnboardingCopy.promiseBody(isReview: false), OnboardingCopy.promiseBody)
        XCTAssertNil(OnboardingCopy.promiseBody(isReview: true), "the button reads Continue in review")
    }

    // MARK: - {kept}

    func testKeptNamesEachRetentionChoice() {
        XCTAssertEqual(OnboardingCopy.kept(policy: .ninetyDays, customDays: nil, needsReview: false), "kept 90 days")
        XCTAssertEqual(OnboardingCopy.kept(policy: .thirtyDays, customDays: nil, needsReview: false), "kept 30 days")
        XCTAssertEqual(OnboardingCopy.kept(policy: .sevenDays, customDays: nil, needsReview: false), "kept 7 days")
        XCTAssertEqual(OnboardingCopy.kept(policy: .custom, customDays: 45, needsReview: false), "kept 45 days")
        XCTAssertEqual(OnboardingCopy.kept(policy: .custom, customDays: 1, needsReview: false), "kept 1 day")
        XCTAssertEqual(OnboardingCopy.kept(policy: .forever, customDays: nil, needsReview: false), "kept until you delete it")
    }

    func testKeptTellsTheTruthWhenTheRetentionFileNeedsReview() async throws {
        let directory = try temporaryDirectory()
        // An older version's file: a finite policy without schema 2. Until the
        // person reviews it, nothing is deleted.
        try Data(#"{"mode":"thirtyDays","days":null}"#.utf8)
            .write(to: directory.appendingPathComponent("retention.json"))
        let store = DiskRetentionStore(directory: directory)
        let needsReview = await store.needsReview()
        XCTAssertTrue(needsReview)
        let kept = await OnboardingCopy.kept(from: store)
        XCTAssertEqual(kept, "kept until you delete it")
        XCTAssertTrue(OnboardingCopy.promiseStays(kept: kept).hasPrefix("Text and screenshots, encrypted, kept until you delete it."))
    }

    func testKeptWithNoRetentionFileIsNinetyDays() async throws {
        let store = DiskRetentionStore(directory: try temporaryDirectory())
        let kept = await OnboardingCopy.kept(from: store)
        XCTAssertEqual(kept, "kept 90 days")
    }

    // MARK: - The other screens

    func testWelcomeAndPermissionsFollowTheKey() {
        XCTAssertEqual(OnboardingCopy.welcomeTitle, "Your Mac, with a memory.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.shiftTwice), "Press ⇧ ⇧ and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.rightOption), "Tap right ⌥ and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.chord), "Press ⌃ ⇧ Space and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.welcomeBodySpoken(.shiftTwice),
                       "Press Shift twice and ask about your screen, now or earlier.", "VoiceOver hears words, not symbols")
        // Each permission is framed by what it lets Hippocampus do.
        XCTAssertEqual(OnboardingCopy.screenRecordingBenefits, ["Remembers what’s on your screen"])
        XCTAssertEqual(OnboardingCopy.accessibilityBenefits(.shiftTwice),
                       ["Knows the window you’re in", "Skips password fields", "Opens Ask with Shift twice"])
        XCTAssertEqual(OnboardingCopy.accessibilityKeyBenefit(.rightShift), "Opens Ask with right Shift")
        XCTAssertNil(OnboardingCopy.accessibilityKeyBenefit(.chord), "the chord needs no Accessibility")
        XCTAssertEqual(OnboardingCopy.accessibilityBenefits(.chord), ["Knows the window you’re in", "Skips password fields"])
    }

    func testWhatYouGetNamesThreeThingsTheAppDoes() {
        XCTAssertEqual(OnboardingCopy.whatYouGetTitle, "What you get")
        XCTAssertEqual(OnboardingCopy.findTitle, "Find anything you’ve seen.")
        XCTAssertEqual(OnboardingCopy.findLine, "Ask in plain words. See where each answer came from.")
        XCTAssertEqual(OnboardingCopy.dayTitle, "Your day, written for you.")
        XCTAssertEqual(OnboardingCopy.dayLine, "Overview turns today into sessions you can scan.")
        XCTAssertEqual(OnboardingCopy.aiTitle, "Your AI starts with your context.")
        // Setup connects no AI tool: the person does, later, from the menu.
        XCTAssertEqual(OnboardingCopy.aiLine, "Connect it once, and each session opens with your recent work.")
    }

    func testTheWelcomeDemoIsMadeUpAndTellsOneStory() {
        XCTAssertEqual(OnboardingCopy.Demo.askQuestion, "what was that pricing link?")
        XCTAssertEqual(OnboardingCopy.Demo.source, "stripe.com/pricing · 2:14 PM")
        XCTAssertTrue(OnboardingCopy.Demo.source.hasPrefix(OnboardingCopy.Demo.sourceAddress))
        // Ask opens over a message about the same work, not over the page
        // it finds: the link comes back from earlier.
        XCTAssertEqual(OnboardingCopy.Demo.messageTitle, OnboardingCopy.Demo.sessionTitle)
        XCTAssertEqual(OnboardingCopy.Demo.askContext, "Mail · Team pricing")
        XCTAssertFalse(OnboardingCopy.Demo.messageBody.lowercased().contains("stripe"))
        // The day it fills in ends on the session Ask and the AI talk about.
        XCTAssertEqual(OnboardingCopy.Demo.sessionTitle, "Team pricing")
        XCTAssertTrue(OnboardingCopy.Demo.aiContextLines[0].hasSuffix(OnboardingCopy.Demo.sessionTitle))
        XCTAssertTrue(OnboardingCopy.Demo.aiContextLines[0].hasPrefix("2:12 – 2:36 PM"))
        XCTAssertTrue(OnboardingCopy.Demo.sessionTime.hasPrefix("2:12 – 2:36 PM"))
        XCTAssertEqual(OnboardingCopy.Demo.places, ["Overview", "Ask", "You"], "the window's three places")
        XCTAssertEqual(OnboardingCopy.welcomeDemoLabel,
                       "A short demo. Ask finds a link for the message you’re writing, with its source. Overview fills in the day. Your AI starts with your recent work.")
    }

    func testTryItSaysWhatItReadAndWhyAWindowIsSkipped() {
        // Amy's words, word for word: "just" means a moment ago.
        XCTAssertEqual(OnboardingCopy.tryItReadFrom("Safari"), "Here’s what I just read from Safari")
        XCTAssertEqual(OnboardingCopy.tryItReading("Safari"), "Reading Safari…")
        XCTAssertEqual(OnboardingCopy.tryItNoWindow, "No window to read yet.")
        XCTAssertEqual(OnboardingCopy.tryItNothingToShow("Finder"), "Nothing to read in Finder yet.")
        XCTAssertEqual(OnboardingCopy.tryItOpenSomething, "Open a page, a document or a chat.")
        XCTAssertEqual(OnboardingCopy.tryItSwitchWindows, "Switch to another window to try it.")
        XCTAssertEqual(OnboardingCopy.skippedText(.neverRead, app: "Passwords"), "Passwords is never read.")
        XCTAssertEqual(OnboardingCopy.skippedText(.excluded, app: "Messages"), "Messages is skipped, as you asked.")
        XCTAssertEqual(OnboardingCopy.skippedText(.privateWindow, app: "Google Chrome"), "This private window is skipped.")
        XCTAssertEqual(OnboardingCopy.skippedText(.passwordField, app: "Safari"),
                       "Nothing is read while a password field is in use.")
        XCTAssertEqual(OnboardingCopy.skippedText(.neverRead, app: nil), "This app is never read.")
    }

    func testPermissionsSaysNothingIsReadOnlyBeforeConsent() {
        XCTAssertEqual(OnboardingCopy.permissionsBody(isReview: false),
                       "Nothing is read until you click Start Remembering.")
        XCTAssertNil(OnboardingCopy.permissionsBody(isReview: true), "in review it may already be reading")
    }

    func testPermissionRowWordsMatchTheirStates() {
        XCTAssertEqual(OnboardingCopy.permissionsTitle, "Two permissions")
        XCTAssertEqual(OnboardingCopy.allow, "Allow")
        XCTAssertEqual(OnboardingCopy.waitingForSettings, "Waiting for System Settings…")
        XCTAssertEqual(OnboardingCopy.notOnYet, "Not on yet.")
        XCTAssertEqual(OnboardingCopy.permissionOn, "On")
        XCTAssertEqual(OnboardingCopy.needsHelpHint,
                       "Turn on Hippocampus in the list. Not there? Click + and choose it in Applications.")
        // macOS's app is System Settings; "Settings" alone is Preferences' old name.
        XCTAssertEqual(OnboardingCopy.openSettings, "Open System Settings")
    }

    func testTheWaitingHintsNameTheButtonThatLeadsOn() {
        // Allow raises macOS's prompt only, whose button is Open System
        // Settings; a waiting row offers a button with the same words, so
        // the hint is right whether or not the prompt showed.
        XCTAssertEqual(OnboardingCopy.waitingHint(.accessibility),
                       "Choose Open System Settings, then turn on Hippocampus.")
        XCTAssertEqual(OnboardingCopy.waitingHint(.screenRecording),
                       "Choose Open System Settings, then turn on Hippocampus. If macOS offers Quit & Reopen, choose Later.")
        for surface in PermissionSurface.allCases {
            XCTAssertTrue(OnboardingCopy.waitingHint(surface).contains(OnboardingCopy.openSettings))
        }
    }

    func testTheSoundNoteClaimsOnlyThatNothingListens() throws {
        // Hippocampus plays sounds, so "doesn’t use sound" would be false;
        // it takes none in. No source turns on screen audio or a microphone.
        XCTAssertEqual(OnboardingCopy.screenRecordingSoundNote,
                       "macOS calls this Screen & System Audio Recording. Hippocampus doesn’t listen.")
        XCTAssertNil(OnboardingCopy.screenRecordingNote(macOSMajorVersion: 14), "macOS 14 says Screen Recording")
        XCTAssertEqual(OnboardingCopy.screenRecordingNote(macOSMajorVersion: 15), OnboardingCopy.screenRecordingSoundNote)
        XCTAssertEqual(OnboardingCopy.screenRecordingNote(macOSMajorVersion: 26), OnboardingCopy.screenRecordingSoundNote)
        for package in ["apps/hippocampus/Sources", "apps/recall-ui/Sources", "apps/onboarding/Sources",
                        "adapters/macos/MCICaptureHelper/Sources"] {
            let root = repositoryRoot.appendingPathComponent(package)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for call in ["capturesAudio = true", "captureMicrophone = true", "AVAudioRecorder", "AVAudioEngine",
                             "AVCaptureDevice.default(for: .audio"] {
                    XCTAssertFalse(text.contains(call), "\(url.lastPathComponent) uses \(call)")
                }
            }
        }
    }

    func testAnswersLinesSayWhyEachTime() {
        // Neither Apple Intelligence nor a model on this Mac answers: on
        // macOS 26 Apple Intelligence can be turned on, so say how.
        XCTAssertEqual(OnboardingCopy.noModelNote(macOSMajorVersion: 14),
                       "Answers need Apple Intelligence or a model on this Mac. Search works now.")
        XCTAssertEqual(OnboardingCopy.noModelNote(macOSMajorVersion: 15), OnboardingCopy.answersNeedAModel)
        XCTAssertEqual(OnboardingCopy.noModelNote(macOSMajorVersion: 26),
                       "For answers, turn on Apple Intelligence or install Ollama and a model.")
        XCTAssertEqual(OnboardingCopy.noModelNote(macOSMajorVersion: 27),
                       OnboardingCopy.turnOnAppleIntelligenceOrInstallAModel)
        XCTAssertEqual(OnboardingCopy.appleIntelligencePreparing, "Apple Intelligence is getting ready. Search works now.")
        // Set to use Apple Intelligence alone.
        XCTAssertEqual(OnboardingCopy.answersNeedAppleIntelligence, "Answers need Apple Intelligence. Search works without it.")
        XCTAssertEqual(OnboardingCopy.answersUnsupported, "Search works. Answers need macOS 26 with Apple Intelligence.")
    }

    // MARK: - The panels

    func testTheBrowserExtensionPanelSaysWhatTheExtensionAdds() {
        // Every browser window is read without it (RULINGS G8), so the
        // body says what it adds. It sends a page's text up to a limit, so
        // nothing says "whole".
        XCTAssertEqual(OnboardingCopy.extensionTitle, "Remember web pages")
        XCTAssertEqual(OnboardingCopy.extensionBody, "The extension adds each page’s address and the text not on screen.")
        XCTAssertFalse(OnboardingCopy.extensionBody.lowercased().contains("whole"))
        XCTAssertEqual(OnboardingCopy.safariExtensionHint, "In Safari’s extension settings, turn on Hippocampus.")
        // The prompt comes from opening Safari's settings; reading a
        // browser needs none.
        XCTAssertEqual(OnboardingCopy.automationAskBody,
                       "macOS asks to let Hippocampus control Safari. That’s how it opens Safari’s settings.")
        XCTAssertEqual(OnboardingCopy.automationOffBody,
                       "macOS won’t ask twice. Click Ask Again, or turn it on in System Settings.")
        XCTAssertTrue(OnboardingCopy.automationOffBody.contains(OnboardingCopy.askAgain), "names the button beside it")
    }

    func testTheExtensionStepsSayWhatOpened() {
        XCTAssertEqual(OnboardingCopy.extensionStepsIntro(browser: "Chrome", didOpenBrowser: true),
                       "Chrome and a Finder window opened. Three steps:")
        XCTAssertEqual(OnboardingCopy.extensionStepsIntro(browser: "Chrome", didOpenBrowser: false),
                       "Open Chrome yourself, go to chrome://extensions, then:")
        XCTAssertEqual([OnboardingCopy.extensionStepDeveloperMode, OnboardingCopy.extensionStepLoadUnpacked,
                        OnboardingCopy.extensionStepChooseFolder],
                       ["Turn on Developer mode, top right.", "Click Load unpacked.", "Choose the folder Finder is showing."])
    }

    func testTheAppAccessPanelSaysWhatIsSkippedInEveryApp() {
        // Every ordinary app is read; the Promise's checked words say what
        // is not.
        XCTAssertEqual(OnboardingCopy.appAccessSkipped,
                       "Password fields are skipped in every app. Private browser windows are skipped when they show they are private.")
    }

    // MARK: - Style (spec-copy S2, RULINGS V)

    /// Every string the five screens add, with the key-dependent ones for
    /// each key.
    private var newStrings: [String] {
        var strings = [
            OnboardingCopy.welcomeTitle, OnboardingCopy.welcomeBodyAfterKeys, OnboardingCopy.getStarted,
            OnboardingCopy.welcomeDemoLabel,
            OnboardingCopy.whatYouGetTitle, OnboardingCopy.findTitle, OnboardingCopy.findLine,
            OnboardingCopy.dayTitle, OnboardingCopy.dayLine, OnboardingCopy.aiTitle, OnboardingCopy.aiLine,
            OnboardingCopy.permissionsTitle, OnboardingCopy.permissionsNothingYet, OnboardingCopy.back,
            OnboardingCopy.screenRecordingName, OnboardingCopy.screenRecordingSoundNote,
            OnboardingCopy.accessibilityName, OnboardingCopy.allow, OnboardingCopy.waitingForSettings,
            OnboardingCopy.screenRecordingWaitingHint, OnboardingCopy.accessibilityWaitingHint, OnboardingCopy.notOnYet,
            OnboardingCopy.needsHelpHint, OnboardingCopy.openSettings, OnboardingCopy.askAgain, OnboardingCopy.permissionOn,
            OnboardingCopy.permissionsFooter, OnboardingCopy.continueLabel,
            OnboardingCopy.promiseTitle, OnboardingCopy.promiseBody, OnboardingCopy.promiseStaysLead,
            OnboardingCopy.promiseNeverReadLead, OnboardingCopy.promiseNeverRead, OnboardingCopy.promiseStopLead,
            OnboardingCopy.promiseStop, OnboardingCopy.dotPromise, OnboardingCopy.openAtLogin,
            OnboardingCopy.startRemembering, OnboardingCopy.neverReadTitle,
            OnboardingCopy.dotLegendTitle, OnboardingCopy.dotLegendOn, OnboardingCopy.dotLegendOff,
            OnboardingCopy.settingUpEncryption, OnboardingCopy.encryptionFailed, OnboardingCopy.tryAgain,
            OnboardingCopy.consentFailedTitle, OnboardingCopy.consentFailedMessage,
            OnboardingCopy.promiseStays(kept: "kept until you delete it"),
            OnboardingCopy.privateWindowsSkipped,
            OnboardingCopy.tryItTitle, OnboardingCopy.tryItStarting, OnboardingCopy.tryItStillNothing,
            OnboardingCopy.openItForMe, OnboardingCopy.askFromMenuBar,
            OnboardingCopy.tryItPaused, OnboardingCopy.tryItOff, OnboardingCopy.stopSharingNote,
            OnboardingCopy.answersNeedAModel, OnboardingCopy.turnOnAppleIntelligenceOrInstallAModel,
            OnboardingCopy.answersNeedAppleIntelligence, OnboardingCopy.appleIntelligencePreparing,
            OnboardingCopy.answersUnsupported, OnboardingCopy.done,
            OnboardingCopy.stalledText(.permissionOff(.screenRecording)), OnboardingCopy.stalledText(.unknown),
            OnboardingCopy.tryItReadFrom("Safari"), OnboardingCopy.tryItReading("Safari"),
            OnboardingCopy.tryItNoWindow, OnboardingCopy.tryItNothingToShow("Finder"),
            OnboardingCopy.tryItOpenSomething, OnboardingCopy.tryItSwitchWindows,
        ]
        strings += OnboardingCopy.screenRecordingBenefits
        let reasons: [SkipReason] = [.neverRead, .excluded, .privateWindow, .passwordField]
        strings += reasons.map { OnboardingCopy.skippedText($0, app: "System Settings") }
        // Welcome's demo: made up, but on screen, so held to the same rules.
        let demo = OnboardingCopy.Demo.self
        strings += [
            demo.messageApp, demo.messageTitle, demo.messageToLabel, demo.messageTo, demo.messageSubjectLabel,
            demo.messageBody, demo.askContext,
            demo.askQuestion, demo.askAnswer, demo.sourcesLabel, demo.sourceApp, demo.source, demo.sourceAddress,
            demo.onThisMac, demo.copyAnswerKeys, demo.copyAnswer, demo.menuBarClock, demo.remembering,
            demo.today, demo.sessionTitle, demo.sessionTime, demo.sessionLine, demo.aiWindowTitle, demo.aiContextTitle,
            demo.aiPrompt, demo.aiReply,
        ]
        strings += demo.places + demo.hours + demo.legend + demo.aiContextLines
        strings += [14, 15, 26].map(OnboardingCopy.noModelNote)
        // The panels, and the Promise in review.
        strings += [
            OnboardingCopy.promiseTitle(isReview: true), OnboardingCopy.appAccessSkipped,
            OnboardingCopy.extensionTitle, OnboardingCopy.extensionBody, OnboardingCopy.noBrowserFound,
            OnboardingCopy.safariExtensionHint, OnboardingCopy.openSafariSettings, OnboardingCopy.install,
            OnboardingCopy.automationAskTitle, OnboardingCopy.automationAskBody, OnboardingCopy.automationOffTitle,
            OnboardingCopy.automationOffBody, OnboardingCopy.openAutomationSettings,
            OnboardingCopy.extensionStepDeveloperMode, OnboardingCopy.extensionStepLoadUnpacked,
            OnboardingCopy.extensionStepChooseFolder, OnboardingCopy.copyPath, OnboardingCopy.showInFinder,
            OnboardingCopy.copyAddress, OnboardingCopy.checking, OnboardingCopy.extensionFolderMissing,
            OnboardingCopy.extensionStepsIntro(browser: "Google Chrome", didOpenBrowser: true),
            OnboardingCopy.extensionStepsIntro(browser: "Google Chrome", didOpenBrowser: false),
        ]
        for key in AskKeyHint.allCases {
            strings += [OnboardingCopy.welcomeBody(key), OnboardingCopy.welcomeBodySpoken(key)]
            strings += OnboardingCopy.accessibilityBenefits(key)
        }
        strings += PermissionSurface.allCases.map(OnboardingCopy.waitingHint)
        for key in Self.keysThatWorkNow {
            strings += [
                OnboardingCopy.tryItFinished(key, openedForThem: false), OnboardingCopy.tryItFinished(key, openedForThem: true),
            ]
            strings += [true, false].compactMap { OnboardingCopy.tryItNext(key, answersAvailable: $0) }
        }
        return strings
    }

    /// What the app can publish as working now (spec-shell S3), the chosen
    /// key when it publishes nothing, and nothing working.
    static let keysThatWorkNow: [AskKeyNow] = {
        let published: [(String, String)] = [
            ("⇧⇧", "Press Shift twice"), ("right ⇧", "Tap right Shift"), ("right ⌘", "Tap right ⌘"),
            ("right ⌥", "Tap right ⌥"), ("⌃⇧Space", "Press ⌃⇧Space"),
        ]
        return published.map { AskKeyNow(effectiveLabel: $0.0, effectivePhrase: $0.1, stored: nil) }
            + AskKeyHint.allCases.map { AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: $0.rawValue) }
            + [AskKeyNow(effectiveLabel: "", effectivePhrase: "", stored: "shiftTwice")]
    }()

    func testNewStringsUseNoBannedWordsOrPunctuation() {
        let banned = [
            "brain", "mci", "capture", "captured", "captures", "record", "recorded", "recording", "event", "events",
            "frame", "frames", "keyframe", "keyframes", "ocr", "mcp", "helper", "agent", "daemon", "pipeline",
            "denylist", "allowlist", "tcc", "grant", "granted", "revoke", "provider", "just", "simply", "seamlessly",
            "powerful", "smart", "magic", "unlock", "supercharge", "journey", "insights", "leverage", "locally",
            "on-device", "monitor", "track", "watch", "observe", "collect", "evidence", "session context",
        ]
        for string in newStrings {
            // macOS's own names are allowed as macOS spells them, and Try
            // it's title says "I just read", where "just" means a moment
            // ago. Nowhere else may "just" mean "only" or "simply".
            let plain = string
                .replacingOccurrences(of: "Screen & System Audio Recording", with: "")
                .replacingOccurrences(of: "Screen Recording", with: "")
                .replacingOccurrences(of: "what I \(OnboardingCopy.justRead) from", with: "")
                .lowercased()
            let words = Set(plain.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            for word in banned where word.contains(" ") ? plain.contains(word) : words.contains(word) {
                XCTFail("\"\(string)\" uses \"\(word)\"")
            }
            for mark in ["—", ";", "!", " / ", "'", "\"", "..."] {
                XCTAssertFalse(string.contains(mark), "\"\(string)\" uses \(mark)")
            }
        }
    }

    func testNewSentencesAreTwelveWordsOrFewer() {
        for string in newStrings {
            let sentences = string.components(separatedBy: CharacterSet(charactersIn: ".?"))
            for sentence in sentences {
                let words = sentence.split(whereSeparator: \.isWhitespace)
                XCTAssertLessThanOrEqual(words.count, 12, "\"\(sentence)\" in \"\(string)\"")
            }
        }
    }

    func testButtonsAreTitleCase() {
        // As macOS writes them: short words after the first stay lowercase
        // ("Show in Finder").
        let minor: Set<Substring> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to"]
        for button in [OnboardingCopy.getStarted, OnboardingCopy.back, OnboardingCopy.allow, OnboardingCopy.openSettings,
                       OnboardingCopy.askAgain,
                       OnboardingCopy.continueLabel, OnboardingCopy.startRemembering, OnboardingCopy.tryAgain,
                       OnboardingCopy.done,
                       OnboardingCopy.openSafariSettings, OnboardingCopy.install, OnboardingCopy.openAutomationSettings,
                       OnboardingCopy.copyPath, OnboardingCopy.showInFinder, OnboardingCopy.copyAddress] {
            for (index, word) in button.split(separator: " ").enumerated() where index == 0 || !minor.contains(word) {
                XCTAssertTrue(word.first?.isUppercase == true, "\(button)")
            }
        }
    }
}
