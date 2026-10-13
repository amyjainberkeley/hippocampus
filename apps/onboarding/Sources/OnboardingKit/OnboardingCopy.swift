import Foundation

/// Every string setup shows, in one place, so the tests can hold them.
/// The views in the `Onboarding` target read from here.
public enum OnboardingCopy {
    // MARK: - The four screens
    //
    // Words follow spec-copy S1 to S3 and RULINGS V and O: Hippocampus
    // "reads" a window, "remembers" as a product, and text is "kept" on
    // disk. Every claim was checked in code before it went here (RULINGS
    // O5 and O10); see `promiseStays(kept:)` and `promiseNeverRead`.

    // Welcome

    public static let welcomeTitle = "Hippocampus remembers what you see."
    /// Follows the keycaps: "Press ⇧ ⇧ and ask about your screen, now or earlier."
    public static let welcomeBodyAfterKeys = "and ask about your screen, now or earlier."
    public static let getStarted = "Get Started"

    /// The body as one sentence, keycaps written out.
    public static func welcomeBody(_ key: AskKeyHint) -> String {
        "\(key.verb) \(key.keycaps.joined(separator: " ")) \(welcomeBodyAfterKeys)"
    }

    /// The body as VoiceOver reads it: the key in words, not symbols.
    public static func welcomeBodySpoken(_ key: AskKeyHint) -> String {
        "\(key.phrase) \(welcomeBodyAfterKeys)"
    }

    // Permissions

    public static let permissionsTitle = "Two permissions"
    /// First run only: until consent the app does not start reading.
    public static let permissionsNothingYet = "Nothing is read until you click Start Remembering."
    public static let screenRecordingName = "Screen Recording"
    public static let screenRecordingWhy = "So it can read what’s on your screen."
    /// macOS 15 and later. Nothing in Hippocampus takes in sound: every
    /// screen stream adds a screen output only, none sets `capturesAudio`,
    /// and nothing opens the microphone. (It does play sounds, so "doesn’t
    /// use sound" would not be true.)
    public static let screenRecordingSoundNote = "macOS calls this Screen & System Audio Recording. Hippocampus doesn’t listen."
    public static let accessibilityName = "Accessibility"
    public static let accessibilityWhyBase = "So it knows which window you’re in and skips password fields."
    public static let allow = "Allow"
    public static let waitingForSettings = "Waiting for System Settings…"
    /// "Allow" raises macOS's prompt only, whose button is Open System
    /// Settings. The waiting row has a button with the same words for when
    /// no prompt shows, so the hint is right either way.
    public static let screenRecordingWaitingHint = "Choose Open System Settings, then turn on Hippocampus. If macOS offers Quit & Reopen, choose Later."
    public static let accessibilityWaitingHint = "Choose Open System Settings, then turn on Hippocampus."
    public static let notOnYet = "Not on yet."
    /// After "Not on yet.", on one line of the row: "it" is Hippocampus.
    public static let needsHelpHint = "Turn on Hippocampus in the list. Not there? Click + and choose it in Applications."
    public static let openSettings = "Open System Settings"
    public static let askAgain = "Ask Again"
    public static let permissionOn = "On"
    public static let permissionsFooter = "Change either one any time in System Settings."
    public static let continueLabel = "Continue"
    public static let back = "Back"

    /// The Accessibility row's second line: a single key or Shift twice
    /// needs it too. The chord does not, so it has none.
    public static func accessibilityKeyNote(_ key: AskKeyHint) -> String? {
        key.noun.map { "It also lets \($0) open Ask." }
    }

    /// Under the title. In review remembering may already be on, so the
    /// first run's sentence would not be true.
    public static func permissionsBody(isReview: Bool) -> String? {
        isReview ? nil : permissionsNothingYet
    }

    /// The Screen Recording row's second line: macOS 15 renamed the
    /// permission, and the new name mentions audio.
    public static func screenRecordingNote(macOSMajorVersion: Int) -> String? {
        macOSMajorVersion >= 15 ? screenRecordingSoundNote : nil
    }

    /// What a waiting row says to do.
    public static func waitingHint(_ surface: PermissionSurface) -> String {
        switch surface {
        case .screenRecording: screenRecordingWaitingHint
        case .accessibility: accessibilityWaitingHint
        }
    }

    // Promise

    public static let promiseTitle = "Before it starts"
    /// In review remembering has started, so "Before it starts" would not
    /// be true: the screen reads as the never-read panel does.
    public static func promiseTitle(isReview: Bool) -> String {
        isReview ? neverReadTitle : promiseTitle
    }
    public static let promiseBody = "When you click Start Remembering, Hippocampus begins reading your screen."
    /// The body above the button: on a first run it says what the click
    /// does. In review the button is "Continue" and remembering may already
    /// be on, so there is no body.
    public static func promiseBody(isReview: Bool) -> String? {
        isReview ? nil : promiseBody
    }
    public static let promiseStaysLead = "Stays on this Mac."
    public static let promiseNeverReadLead = "Never read."
    /// Password fields: the focused-window path drops the frame during
    /// secure input or on a secure field, whole-screen reading stops during
    /// secure input, and the extension never reads input values. Password
    /// managers are left out: the helper skips a fixed list of them
    /// (1Password, Bitwarden, Dashlane, LastPass, Keychain Access,
    /// Passwords), not every one. Private windows are not "never read":
    /// see `privateWindowsSkipped`.
    public static let promiseNeverRead = "Password fields. \(privateWindowsSkipped)"
    /// Browsers are read like every other window (RULINGS G8). A private
    /// window is skipped only when Hippocampus can tell without asking: a
    /// private marker in its title or top bar, the extension's private
    /// flag, or a check macOS already allowed. A private window that shows
    /// none of these is read, so the sentence promises no more than that.
    public static let privateWindowsSkipped = "Private browser windows are skipped when they show they are private."
    public static let promiseStopLead = "You can stop it."
    public static let promiseStop = "Pause from the menu bar. Quit ends it."
    /// The menu-bar mark's promise (RULINGS B1), word for word. Every state
    /// in which the screen may be read shows the solid dot.
    public static let dotPromise = "A solid dot means it is remembering. No solid dot means it is not."
    public static let openAtLogin = "Open Hippocampus at login"
    /// The panel Preferences opens with "What is never read…": the
    /// Promise's lines, read-only.
    public static let neverReadTitle = "What is never read"
    public static let startRemembering = "Start Remembering"
    public static let settingUpEncryption = "Setting up encryption…"
    public static let encryptionFailed = "Couldn’t set up encryption."
    public static let tryAgain = "Try Again"
    public static let consentFailedTitle = "Couldn’t start"
    public static let consentFailedMessage = "Couldn’t save your setup. Free up some disk space and try again."

    /// Promise's button. In review it only continues. On a first run it
    /// waits for the encryption key, and says so; after a failed setup it
    /// keeps its name, off, beside "Try Again".
    public static func promisePrimary(isReview: Bool, keyState: PrepareBrainViewModel.KeyState) -> String {
        if isReview { return continueLabel }
        switch keyState {
        case .checking, .generating: return settingUpEncryption
        case .ready, .failed: return startRemembering
        }
    }

    /// The first Promise line, after "Stays on this Mac.".
    ///
    /// No upload holds in code (RULINGS O10, product critique finding 13):
    /// the client's only network calls are the optional model download and
    /// update check (fetches, with system profiling off), loopback-only MCP
    /// servers and crash reports, and a feedback link opened in the
    /// browser. The `server` crate is not a dependency of anything shipped.
    ///
    /// Sharing waits on the person: an AI tool is connected only from the
    /// menu's Connect AI Tools… and the AI Tools pane, and setup connects
    /// nothing. Hippocampus is the subject, because "Copy for your AI"
    /// lets the person paste text into an AI that is not connected. The
    /// last sentence is the provider boundary engineering critique 8 keeps
    /// at consent, in RULINGS V's words ("your AI", "the company that runs
    /// it").
    public static func promiseStays(kept: String) -> String {
        "Text and screenshots, encrypted, \(kept). Nothing is uploaded by Hippocampus. It shares them with your AI only if you connect it. What your AI reads goes to the company that runs it."
    }

    /// How long text and screenshots are kept, for `promiseStays`. A
    /// retention file from an older version needs review, and until then
    /// nothing is deleted, so it says "kept until you delete it".
    public static func kept(policy: RetentionPolicy, customDays: Int?, needsReview: Bool) -> String {
        if needsReview { return keptUntilDeleted }
        switch policy {
        case .forever: return keptUntilDeleted
        case .ninetyDays, .thirtyDays, .sevenDays: return keptDays(policy.days ?? 90)
        case .custom: return customDays.map(keptDays) ?? keptUntilDeleted
        }
    }

    public static func kept(from store: any RetentionStore) async -> String {
        let policy = await store.currentPolicy()
        let customDays = await store.currentCustomDays()
        let needsReview = await store.needsReview()
        return kept(policy: policy, customDays: customDays, needsReview: needsReview)
    }

    static let keptUntilDeleted = "kept until you delete it"

    static func keptDays(_ days: Int) -> String {
        days == 1 ? "kept 1 day" : "kept \(days) days"
    }

    // Try it

    public static let tryItTitle = "Try it"
    public static let tryItStarting = "Turning on…"
    public static let tryItWaiting = "Nothing read yet. Open a document, note or chat, then come back."
    /// The stalled card with no cause it can name. Its button is
    /// `tryAgain`: the app restarts remembering in place
    /// (`hippocampus://restart`, the menu's own Try Again), and this
    /// screen starts over with it.
    public static let tryItStillNothing = "Still nothing read."
    public static let openItForMe = "Open it for me"
    public static let tryItPaused = "Remembering is paused. Resume it from the menu bar."
    public static let tryItOff = "Remembering is off. Turn it on from the menu bar."
    /// Once a proof shows: where the indicator is, and what it does.
    public static let stopSharingNote = "macOS shows an icon in the menu bar while Hippocampus reads. Stop Sharing there ends it."
    /// Under a proof when answers are not available: one line, for the
    /// reason the model check gives (`UnderstandingProbe`). Answers come
    /// from Apple Intelligence or from a model Ollama or LM Studio serves
    /// on this Mac; when either answers, nothing is said.
    ///
    /// Neither answers. On macOS 26 Apple Intelligence can be turned on,
    /// so the line says what to do; before it, what answers need.
    public static func noModelNote(macOSMajorVersion: Int) -> String {
        macOSMajorVersion >= 26 ? turnOnAppleIntelligenceOrInstallAModel : answersNeedAModel
    }
    public static let answersNeedAModel = "Answers need Apple Intelligence or a model on this Mac. Search works now."
    public static let turnOnAppleIntelligenceOrInstallAModel =
        "For answers, turn on Apple Intelligence or install Ollama and a model."
    /// Apple Intelligence is on but not ready, and no model on this Mac answers.
    public static let appleIntelligencePreparing = "Apple Intelligence is getting ready. Search works now."
    /// Set to use Apple Intelligence alone, and it is off.
    public static let answersNeedAppleIntelligence = "Answers need Apple Intelligence. Search works without it."
    /// Set to use Apple Intelligence alone, on a Mac that cannot run it.
    public static let answersUnsupported = "Search works. Answers need macOS 26 with Apple Intelligence."
    public static let done = "Done"
    /// Ask opened, but not by a key that works now.
    public static let askFromMenuBar = "That’s Ask. Open it from the menu bar."

    /// The waiting card, by the app in front. A browser is read like any
    /// other window (RULINGS G8), so it gets the ordinary card.
    public static func waitingText(_ note: FrontAppNote) -> String {
        switch note {
        case .ordinary: tryItWaiting
        case .neverRead(let app): "\(app) is never read. Try a document, note or chat."
        }
    }

    /// The card after 45 s with nothing read.
    public static func stalledText(_ cause: StallCause) -> String {
        switch cause {
        case .permissionOff(let surface):
            "\(surface == .accessibility ? accessibilityName : screenRecordingName) is off. Turn it on in System Settings."
        case .frontApp(let note): waitingText(note)
        case .unknown: tryItStillNothing
        }
    }

    /// The card's heading: "Notes · Launch plan".
    public static func proofHeading(_ proof: ReadProof) -> String {
        guard let title = proof.windowTitle, !title.isEmpty else { return proof.appName }
        return "\(proof.appName) · \(title)"
    }

    /// "Read 12 seconds ago", in the person's language.
    public static func readAgo(_ date: Date, now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let seconds = max(1, now.timeIntervalSince(date).rounded())
        return "Read \(formatter.localizedString(fromTimeInterval: -seconds))"
    }

    /// Under a proof: what to try now, with the key that opens Ask right
    /// now. When answers work (Apple Intelligence, or a model on this Mac)
    /// a question works; otherwise a word from the window still finds it.
    /// Nil when no key opens Ask now: the card then offers only "Open it
    /// for me".
    public static func tryItNext(_ key: AskKeyNow, answersAvailable: Bool) -> String? {
        guard let phrase = key.phrase else { return nil }
        let press = phrase.prefix(1).lowercased() + phrase.dropFirst()
        return answersAvailable
            ? "Now \(press) and ask about it."
            : "Now \(press) and type a word from that window."
    }

    /// When Ask opens. After the key: "That’s it. Shift twice works
    /// anywhere." After "Open it for me", which proves nothing about the
    /// key: "That’s Ask. Press Shift twice to open it anywhere." With no key
    /// working now: "That’s Ask. Open it from the menu bar."
    public static func tryItFinished(_ key: AskKeyNow, openedForThem: Bool) -> String {
        guard let phrase = key.phrase, let name = key.name else { return askFromMenuBar }
        if openedForThem { return "That’s Ask. \(phrase) to open it anywhere." }
        return "That’s it. \(name.prefix(1).uppercased() + name.dropFirst()) works anywhere."
    }

    // MARK: - The browser extension panel
    //
    // Opened from Preferences. Browsers are read like every other window
    // without it (RULINGS G8), so the body says what it adds: the page's
    // address, and its text beyond what is on screen (the extension sends
    // a page's text up to a limit, so not "the whole page").

    public static let extensionTitle = "Remember web pages"
    public static let extensionBody = "The extension adds each page’s address and the text not on screen."
    public static let noBrowserFound = "No supported browser found."
    public static let safariExtensionHint = "In Safari’s extension settings, turn on Hippocampus."
    public static let openSafariSettings = "Open Safari Settings"
    public static let install = "Install"
    /// Before the first click on Open Safari Settings, which raises
    /// macOS's Automation prompt: the click opens Safari and presses ⌘,
    /// there. Reading a browser needs no prompt (RULINGS G8), so the note
    /// names only what the click does.
    public static let automationAskTitle = "macOS will ask first"
    public static let automationAskBody = "macOS asks to let Hippocampus control Safari. That’s how it opens Safari’s settings."
    public static let automationOffTitle = "Automation is off"
    public static let automationOffBody = "macOS won’t ask twice. Click Ask Again, or turn it on in System Settings."
    public static let openAutomationSettings = "Open Automation Settings"
    public static let extensionStepDeveloperMode = "Turn on Developer mode, top right."
    public static let extensionStepLoadUnpacked = "Click Load unpacked."
    public static let extensionStepChooseFolder = "Choose the folder Finder is showing."
    public static let copyPath = "Copy Path"
    public static let showInFinder = "Show in Finder"
    public static let copyAddress = "Copy Address"
    /// The extension's state is being looked up.
    public static let checking = "Checking…"
    /// Install found no extension folder to show: the app is incomplete.
    public static let extensionFolderMissing = "Part of Hippocampus is missing. Reinstall it, then try again."

    /// Over the three steps after Install, by whether the browser opened.
    public static func extensionStepsIntro(browser: String, didOpenBrowser: Bool) -> String {
        didOpenBrowser
            ? "\(browser) and a Finder window opened. Three steps:"
            : "Open \(browser) yourself, go to chrome://extensions, then:"
    }

    // MARK: - The app access panel

    /// Under its title. Every ordinary app is read, so what is skipped in
    /// all of them is what the person needs to know (spec-copy S3 #9, in
    /// the Promise's checked words).
    public static let appAccessSkipped = "Password fields are skipped in every app. \(privateWindowsSkipped)"
}
