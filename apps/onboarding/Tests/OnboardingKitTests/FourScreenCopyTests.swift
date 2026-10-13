import XCTest
@testable import OnboardingKit

final class FourScreenCopyTests: XCTestCase {
    // MARK: - The Promise

    func testThePromiseSaysWhatTheCodeDoes() {
        XCTAssertEqual(OnboardingCopy.promiseTitle, "Before it starts")
        XCTAssertEqual(OnboardingCopy.promiseBody,
                       "When you click Start Remembering, Hippocampus begins reading your screen.")
        XCTAssertEqual(OnboardingCopy.promiseStays(kept: "kept 90 days"),
                       "Text and screenshots, encrypted, kept 90 days. Nothing is uploaded by Hippocampus. What your AI reads goes to the company that runs it.")
        // Password managers are left out: the helper skips a fixed list of
        // them, not every one.
        XCTAssertEqual(OnboardingCopy.promiseNeverRead, "Password fields and private browser windows.")
        XCTAssertEqual(OnboardingCopy.promiseStop, "Pause from the menu bar. Quit ends it.")
        XCTAssertEqual(OnboardingCopy.openAtLogin, "Open Hippocampus at login")
        XCTAssertEqual(OnboardingCopy.startRemembering, "Start Remembering")
        XCTAssertTrue(OnboardingCopy.promiseBody.contains(OnboardingCopy.startRemembering))
        XCTAssertTrue(OnboardingCopy.permissionsNothingYet.contains(OnboardingCopy.startRemembering))
    }

    func testThePromiseNeverSaysNeverUploaded() {
        let promise = OnboardingCopy.promiseStays(kept: "kept 90 days").lowercased()
        XCTAssertFalse(promise.contains("never uploaded"))
        XCTAssertTrue(promise.contains("goes to the company that runs"), "the provider boundary stays at consent")
        XCTAssertFalse(promise.contains("ai tools"), "\"your AI\" in sentences; AI Tools is only the pane's name")
    }

    func testThePromiseNeverPromisesEveryPasswordManager() {
        XCTAssertFalse(OnboardingCopy.promiseNeverRead.lowercased().contains("password manager"))
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
        XCTAssertEqual(OnboardingCopy.welcomeTitle, "Hippocampus remembers what you see.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.shiftTwice), "Press ⇧ ⇧ and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.rightOption), "Tap right ⌥ and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.welcomeBody(.chord), "Press ⌃ ⇧ Space and ask about your screen, now or earlier.")
        XCTAssertEqual(OnboardingCopy.accessibilityWhy(.shiftTwice),
                       "So it knows which window you’re in and skips password fields. It also lets Shift twice open Ask.")
        XCTAssertEqual(OnboardingCopy.accessibilityWhy(.chord),
                       "So it knows which window you’re in and skips password fields.")
    }

    func testPermissionRowWordsMatchTheirStates() {
        XCTAssertEqual(OnboardingCopy.permissionsTitle, "Two permissions")
        XCTAssertEqual(OnboardingCopy.allow, "Allow")
        XCTAssertEqual(OnboardingCopy.waitingForSettings, "Waiting for System Settings…")
        XCTAssertEqual(OnboardingCopy.notOnYet, "Not on yet.")
        XCTAssertEqual(OnboardingCopy.permissionOn, "On")
        XCTAssertEqual(OnboardingCopy.needsHelpHint,
                       "Turn on Hippocampus in the list. Not there? Click + and choose Hippocampus in Applications.")
        // macOS's app is System Settings; "Settings" alone is Preferences' old name.
        XCTAssertEqual(OnboardingCopy.openSettings, "Open System Settings")
    }

    func testTheWaitingHintsMentionMacOSsPrompt() {
        // Allow shows macOS's prompt as well as the pane (product critique 7).
        XCTAssertEqual(OnboardingCopy.accessibilityWaitingHint,
                       "macOS may ask first. Then turn on Hippocampus in the list.")
        XCTAssertEqual(OnboardingCopy.screenRecordingWaitingHint,
                       "macOS may ask first. Then turn on Hippocampus in the list. If macOS offers Quit & Reopen, choose Later.")
    }

    func testTheSoundNoteClaimsOnlyThatNothingListens() throws {
        // Hippocampus plays sounds, so "doesn’t use sound" would be false;
        // it takes none in. No source turns on screen audio or a microphone.
        XCTAssertEqual(OnboardingCopy.screenRecordingSoundNote,
                       "macOS calls this Screen & System Audio Recording. Hippocampus doesn’t listen.")
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
        XCTAssertEqual(OnboardingCopy.answersNeedAppleIntelligence, "Answers need Apple Intelligence. Search works without it.")
        XCTAssertEqual(OnboardingCopy.answersUnsupported, "Search works. Answers need macOS 26 with Apple Intelligence.")
    }

    // MARK: - Style (spec-copy S2, RULINGS V)

    /// Every string the four screens add, with the key-dependent ones for
    /// each key.
    private var newStrings: [String] {
        var strings = [
            OnboardingCopy.welcomeTitle, OnboardingCopy.welcomeBodyAfterKeys, OnboardingCopy.welcomeFallback,
            OnboardingCopy.welcomeClipCaption, OnboardingCopy.getStarted,
            OnboardingCopy.permissionsTitle, OnboardingCopy.permissionsBody, OnboardingCopy.permissionsNothingYet,
            OnboardingCopy.screenRecordingName, OnboardingCopy.screenRecordingWhy, OnboardingCopy.screenRecordingSoundNote,
            OnboardingCopy.accessibilityName, OnboardingCopy.allow, OnboardingCopy.waitingForSettings,
            OnboardingCopy.screenRecordingWaitingHint, OnboardingCopy.accessibilityWaitingHint, OnboardingCopy.notOnYet,
            OnboardingCopy.needsHelpHint, OnboardingCopy.openSettings, OnboardingCopy.askAgain, OnboardingCopy.permissionOn,
            OnboardingCopy.permissionsFooter, OnboardingCopy.continueLabel,
            OnboardingCopy.promiseTitle, OnboardingCopy.promiseBody, OnboardingCopy.promiseStaysLead,
            OnboardingCopy.promiseNeverReadLead, OnboardingCopy.promiseNeverRead, OnboardingCopy.promiseStopLead,
            OnboardingCopy.promiseStop, OnboardingCopy.openAtLogin, OnboardingCopy.startRemembering,
            OnboardingCopy.settingUpEncryption, OnboardingCopy.encryptionFailed, OnboardingCopy.tryAgain,
            OnboardingCopy.consentFailedTitle, OnboardingCopy.consentFailedMessage,
            OnboardingCopy.promiseStays(kept: "kept until you delete it"),
            OnboardingCopy.tryItTitle, OnboardingCopy.tryItStarting, OnboardingCopy.tryItStillNothing,
            OnboardingCopy.addExtension, OnboardingCopy.openItForMe, OnboardingCopy.askFromMenuBar,
            OnboardingCopy.tryItPaused, OnboardingCopy.tryItOff, OnboardingCopy.stopSharingNote,
            OnboardingCopy.answersNeedAppleIntelligence, OnboardingCopy.appleIntelligencePreparing,
            OnboardingCopy.answersUnsupported, OnboardingCopy.done,
            OnboardingCopy.stalledText(.permissionOff(.screenRecording)), OnboardingCopy.stalledText(.unknown),
        ]
        let notes: [FrontAppNote] = [
            .ordinary, .neverRead(app: "System Settings"), .unreadBrowser(browser: "Firefox"),
            .needsExtension(browser: "Safari"), .browserWillAsk(browser: "Google Chrome"),
        ]
        strings += notes.map(OnboardingCopy.waitingText)
        for key in AskKeyHint.allCases {
            strings += [OnboardingCopy.welcomeBody(key), OnboardingCopy.accessibilityWhy(key)]
        }
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
            // macOS's own names are allowed as macOS spells them.
            let plain = string
                .replacingOccurrences(of: "Screen & System Audio Recording", with: "")
                .replacingOccurrences(of: "Screen Recording", with: "")
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
        for button in [OnboardingCopy.getStarted, OnboardingCopy.allow, OnboardingCopy.openSettings, OnboardingCopy.askAgain,
                       OnboardingCopy.continueLabel, OnboardingCopy.startRemembering, OnboardingCopy.tryAgain,
                       OnboardingCopy.addExtension, OnboardingCopy.done] {
            for word in button.split(separator: " ") {
                XCTAssertTrue(word.first?.isUppercase == true, "\(button)")
            }
        }
    }
}
