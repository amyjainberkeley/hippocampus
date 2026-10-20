import Foundation

/// Every string setup shows, in one place, so the tests can hold them.
/// The views in the `Onboarding` target read from here.
public enum OnboardingCopy {
    // MARK: - The five screens
    //
    // Words follow spec-copy S1 to S3 and RULINGS V and O: Hippocampus
    // "reads" a window, "remembers" as a product, and text is "kept" on
    // disk. Every claim was checked in code before it went here (RULINGS
    // O5 and O10); see `promiseStays(kept:)` and `promiseNeverRead`.

    // Welcome

    /// Says what Hippocampus does for the person, in their words (launch
    /// playbook, decision 4): their work, not the Mac, is what it keeps.
    public static let welcomeTitle = "Your work, remembered."
    /// Follows the keycaps: "Press ⇧ ⇧ and ask about your screen, now or earlier."
    public static let welcomeBodyAfterKeys = "and ask about your screen, now or earlier."
    public static let getStarted = "Get Started"

    /// The line under the demo, keycaps written out.
    public static func welcomeBody(_ key: AskKeyHint) -> String {
        "\(key.verb) \(key.keycaps.joined(separator: " ")) \(welcomeBodyAfterKeys)"
    }

    /// The line as VoiceOver reads it: the key in words, not symbols.
    public static func welcomeBodySpoken(_ key: AskKeyHint) -> String {
        "\(key.phrase) \(welcomeBodyAfterKeys)"
    }

    /// What VoiceOver says for the demo, which is drawn, not read: one
    /// described image (SPEC 7.3).
    public static let welcomeDemoLabel =
        "A short demo. Ask finds a link for the message you’re writing, with its source. Today fills in your day. Your AI tool starts with what you’re working on."

    /// The words inside Welcome's demo. Everything here is made up: no
    /// person's memory is ever shown in setup.
    public enum Demo {
        // The message the person is writing when they need the link: Ask
        // drops over it, so the page Ask finds is not the one on screen.
        public static let messageApp = "Mail"
        public static let messageTitle = "Team pricing"
        public static let messageToLabel = "To:"
        public static let messageTo = "Maya"
        public static let messageSubjectLabel = "Subject:"
        public static let messageBody = "Here’s the pricing page we looked at:"

        // Ask, dropped from the top of the screen over the message.
        public static let askQuestion = "what was that pricing link?"
        public static let askAnswer = "The Stripe pricing page you read this afternoon."
        /// Ask's header names the window it opened over, as the app's does.
        public static let askContext = "\(messageApp) · \(messageTitle)"
        public static let sourcesLabel = "Sources"
        public static let sourceApp = "Safari"
        public static let source = "stripe.com/pricing · 2:14 PM"
        /// Where the answer came from: a page read earlier, in Safari.
        public static let sourceAddress = "stripe.com/pricing"
        public static let onThisMac = "On this Mac"
        public static let copyAnswerKeys = "⌘C"
        public static let copyAnswer = "Copy Answer"
        public static let menuBarClock = "2:41 PM"

        // Today, in the window (SPEC 7.3): the sidebar's Today, one
        // Working On item and History, and the card for what is going on now.
        public static let places = ["Today", "Working On", "History"]
        /// The one thing the person is working on, as the sidebar names it
        /// from the window's title: the code folder the AI starts in.
        public static let workingOnItem = aiWindowTitle
        /// The section History sits in.
        public static let library = "Library"
        public static let remembering = "Remembering"
        public static let today = "Today"
        public static let yourDay = "Your day"
        public static let hours = ["9 AM", "12 PM", "3 PM"]
        /// The day strip's kinds, in the sidebar's nouns, coloured as the
        /// window colours them (no amber, no red).
        public static let legend = ["Documents", "Code", "Calls"]
        public static let sessionTitle = "Team pricing"
        public static let sessionTime = "2:12 – 2:36 PM · 24m"
        /// Today's card: the work going on now, since it began.
        public static let nowLine = "Now · since 2:12 PM"
        public static let sessionLine = "You compared Stripe’s tiers and drafted the Team plan."

        // Your AI, starting a session.
        public static let aiWindowTitle = "pricing-site"
        public static let aiContextTitle = "From Hippocampus"
        public static let aiContextLines = ["2:12 – 2:36 PM · Team pricing", "You’re redesigning the pricing page."]
        public static let aiPrompt = "where did I leave off?"
        public static let aiReply = "You were drafting the Team plan, with Stripe’s pricing open."
    }

    // What you get

    public static let whatYouGetTitle = "What you get"
    public static let findTitle = "Find anything you’ve seen."
    public static let findLine = "Ask in plain words. See where each answer came from."
    public static let dayTitle = "Your day, written for you."
    public static let dayLine = "Today shows where you left off and what you’re working on."
    /// The decided line, the same in the README (launch decisions, Oct 15).
    /// Setup connects no AI tool (RULINGS O10): the person connects them
    /// later, from the menu's Connect AI Tools…. Then a session can start
    /// with the last few sessions of work (`WhatIsSent`): Claude Code's when
    /// the person lets it, and Codex's when Codex fetches them, so "can".
    public static let aiTitle = "Your AI tools start with what you’re working on."
    public static let aiLine = "Connect them from the menu bar. Each session can then start with your recent work."

    /// Every label the bottom bar's primary button can show on `screen`:
    /// the button keeps the width of the widest, so a label that changes in
    /// place crossfades without the button moving (SPEC 7.1).
    public static func primaryLabels(for screen: OnboardingScreen, isReview: Bool) -> [String] {
        switch screen {
        case .welcome: [getStarted]
        case .whatYouGet, .permissions: [continueLabel]
        case .promise: isReview ? [continueLabel] : [startRemembering, settingUpEncryption]
        case .tryIt: [done]
        }
    }

    // Permissions

    public static let permissionsTitle = "Two permissions"
    /// First run only: until consent the app does not start reading.
    public static let permissionsNothingYet = "Nothing is read until you click Start Remembering."
    public static let screenRecordingName = "Screen Recording"
    /// What Screen Recording lets Hippocampus do, one line per thing.
    public static let screenRecordingBenefits = ["Remembers what’s on your screen"]
    /// macOS 15 and later. Nothing in Hippocampus takes in sound: every
    /// screen stream adds a screen output only, none sets `capturesAudio`,
    /// and nothing opens the microphone. (It does play sounds, so "doesn’t
    /// use sound" would not be true.)
    public static let screenRecordingSoundNote = "macOS calls this Screen & System Audio Recording. Hippocampus doesn’t listen."
    public static let accessibilityName = "Accessibility"
    /// What Accessibility lets Hippocampus do, before the key's line.
    public static let accessibilityBenefitsBase = ["Knows the window you’re in", "Skips password fields"]
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
    /// The footer once both are on, which VoiceOver also announces
    /// (SPEC 7.2). No confetti, no sound.
    public static let bothOn = "Both are on. You can continue."
    /// Added to a row that needs help when macOS can list two copies of
    /// Hippocampus, an old preview and the new build (SPEC 7.7).
    public static let twoCopies = "If you see two, turn on the one in Applications."
    /// What a disabled Continue or Start Remembering says to VoiceOver.
    public static let turnOnBothFirst = "Turn on both permissions first."
    public static let continueLabel = "Continue"
    public static let back = "Back"

    /// What VoiceOver announces the moment a permission is found on.
    public static func permissionIsOn(_ surface: PermissionSurface) -> String {
        "\(name(surface)) is on."
    }

    /// The permission's name, as macOS's list shows it.
    public static func name(_ surface: PermissionSurface) -> String {
        switch surface {
        case .screenRecording: screenRecordingName
        case .accessibility: accessibilityName
        }
    }

    /// What a row that needs help says after "Not on yet.": the steps, and
    /// on a line of its own the one about two copies when macOS can list
    /// two, so neither breaks mid-sentence.
    public static func needsHelpLines(twoCopies: Bool) -> [String] {
        twoCopies ? [needsHelpHint, Self.twoCopies] : [needsHelpHint]
    }

    /// The Accessibility row's last line: a single key or Shift twice
    /// needs it too. The chord does not, so it has none.
    public static func accessibilityKeyBenefit(_ key: AskKeyHint) -> String? {
        key.noun.map { "Opens Ask with \($0)" }
    }

    /// Everything the Accessibility row says it does, the key's line last.
    public static func accessibilityBenefits(_ key: AskKeyHint) -> [String] {
        accessibilityBenefitsBase + [accessibilityKeyBenefit(key)].compactMap { $0 }
    }

    /// Under the title. In review remembering may already be on, so the
    /// first run's sentence would not be true.
    public static func permissionsBody(isReview: Bool) -> String? {
        isReview ? nil : permissionsNothingYet
    }

    /// The Screen Recording row's last line: macOS 15 renamed the
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

    // Promise: privacy at a glance, then consent

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
    /// secure input, and the extension never reads input values.
    ///
    /// Password apps: the helper never reads a broad, enumerated set of
    /// password managers and authenticators (see
    /// `ReadRules.neverReadPasswordManagerFamilies`, held to the helper's
    /// list by `CaptureListParityTests`). No list can name every one that
    /// exists, so the line promises the known ones only, never all of them.
    ///
    /// Private windows are not "never read": see `privateWindowsSkipped`.
    public static let promiseNeverRead = "Password fields and known password apps. \(privateWindowsSkipped)"
    /// Browsers are read like every other window (RULINGS G8). A private
    /// window is skipped only when Hippocampus can tell without asking: a
    /// private marker in its title or top bar, the extension's private
    /// flag, or a check macOS already allowed. A private window that shows
    /// none of these is read, so the sentence promises no more than that.
    public static let privateWindowsSkipped = "Private browser windows are skipped when they show they are private."
    public static let promiseStopLead = "You can stop it."
    /// Pausing stops the capture helper, and quitting stops the helper and
    /// the agent and waits until both have exited, so reading stops either way.
    public static let promiseStop = "Pause or quit from the menu bar, and reading stops."
    /// The menu-bar mark's promise (RULINGS B1), word for word. Every state
    /// in which the screen may be read shows the solid dot. The legend
    /// draws it and VoiceOver reads it.
    public static let dotPromise = "A solid dot means it is remembering. No solid dot means it is not."
    /// The legend: where the mark is, then its two pictures, the solid dot
    /// and none.
    public static let dotLegendTitle = "In the menu bar"
    public static let dotLegendOn = "Remembering"
    public static let dotLegendOff = "Not remembering"
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

    /// `text` with its last two words joined by a no-break space, so a line
    /// never ends with one word alone ("on.") under a full one. The words
    /// are unchanged; only where the line may break.
    public static func keepingLastWordsTogether(_ text: String) -> String {
        guard let last = text.lastIndex(of: " ") else { return text }
        return text.replacingCharacters(in: last...last, with: "\u{00A0}")
    }

    /// A promise's detail, one sentence a line, so each reads as one fact
    /// rather than as a paragraph. Nothing is dropped: the sentences joined
    /// with spaces are the detail.
    public static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var rest = Substring(text)
        while let stop = rest.range(of: ". ") {
            sentences.append(String(rest[..<stop.lowerBound]) + ".")
            rest = rest[stop.upperBound...]
        }
        if !rest.isEmpty { sentences.append(String(rest)) }
        return sentences
    }

    /// The first Promise line, after "Stays on this Mac.".
    ///
    /// No upload holds in code (RULINGS O10, product critique finding 13):
    /// the client's only network calls are the update check (a fetch, with
    /// system profiling off), a model server on this Mac when the person
    /// runs one, and a feedback link opened in the browser. MCP servers
    /// speak over stdio. Nothing is downloaded at setup.
    ///
    /// "Of your screen" covers the pictures of windows beside the one in
    /// front, which new installs keep (SPEC 6.1, 7.6): one consent, and
    /// Preferences › Remembering says exactly what is kept.
    ///
    /// Sharing waits on the person: an AI tool is connected only from the
    /// menu's Connect AI Tools… and the AI Tools pane, and setup connects
    /// nothing. Ask {Tool} and Copy for Your AI put text in a tool's message
    /// box or on the clipboard, and the person sends it, so the sentence
    /// names both ways (SPEC 7.5). It drops the spec's last word,
    /// "yourself", to keep to twelve words; "you" already says who sends.
    /// The last sentence is the provider boundary engineering critique 8
    /// keeps at consent, in RULINGS V's words ("your AI", "the company that
    /// runs it").
    public static func promiseStays(kept: String) -> String {
        "Text and screenshots of your screen, encrypted, \(kept). Nothing is uploaded by Hippocampus. Your AI gets them only if you connect it or send them. What your AI reads goes to the company that runs it."
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
    /// Over what was read: the screen's title once a proof shows, in Amy's
    /// words. "Just" here means a moment ago: the read happened seconds
    /// before, and the card under it says how many.
    public static func tryItReadFrom(_ app: String) -> String {
        "Here’s what I \(justRead) from \(app)"
    }

    /// The one place setup says "just", meaning a moment ago, never "only"
    /// or "simply". The copy tests allow it in this phrase alone.
    static let justRead = "just read"
    /// The window in front is being read.
    public static func tryItReading(_ app: String) -> String {
        "Reading \(app)…"
    }
    /// No window but setup's own is open.
    public static let tryItNoWindow = "No window to read yet."
    /// While nothing is read yet and the Mac is in Low Power Mode, which
    /// reads the window in front four times less often (SPEC 7.7).
    public static let tryItLowPower = "Low Power Mode is on, so reading takes a little longer."
    /// The window in front was read and holds no sentence worth showing:
    /// a Finder window, a photo.
    public static func tryItNothingToShow(_ app: String) -> String {
        "Nothing to read in \(app) yet."
    }
    public static let tryItOpenSomething = "Open a page, a document or a chat."
    /// Under every skipped window: reading another one shows it works.
    public static let tryItSwitchWindows = "Switch to another window to try it."
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

    /// Why the window in front is not read, in one sentence. A browser is
    /// read like any other window (RULINGS G8): only a window that shows
    /// it is private is skipped.
    public static func skippedText(_ reason: SkipReason, app: String?) -> String {
        switch reason {
        case .neverRead: "\(app ?? "This app") is never read."
        case .excluded: "\(app ?? "This app") is skipped, as you asked."
        case .privateWindow: "This private window is skipped."
        case .passwordField: "Nothing is read while a password field is in use."
        }
    }

    /// The card after 45 s with nothing read.
    public static func stalledText(_ cause: StallCause) -> String {
        switch cause {
        case .permissionOff(let surface):
            "\(surface == .accessibility ? accessibilityName : screenRecordingName) is off. Turn it on in System Settings."
        case .unknown: tryItStillNothing
        }
    }

    /// The proof card's heading: the window's title, or the app's name
    /// when the window has none. The screen's title names the app.
    public static func proofHeading(_ proof: ReadProof) -> String {
        guard let title = proof.windowTitle, !title.isEmpty else { return proof.appName }
        return title
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
    /// a question works; otherwise the first try is a search, which works on
    /// every Mac, so the line asks for one in those words. Nil when no key
    /// opens Ask now: the card then offers only "Open it for me".
    public static func tryItNext(_ key: AskKeyNow, answersAvailable: Bool) -> String? {
        guard let phrase = key.phrase else { return nil }
        return answersAvailable
            ? "\(phrase) and ask about it."
            : "\(phrase) and search for a word from that window."
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

    // MARK: - The key that opens Ask (SPEC-DELTA 7)
    //
    // Setup's picker, from the Accessibility row's Change… button. Shift
    // twice stays the default; Fn (Globe) is offered with its checks shown
    // before it is chosen, and never taken from another app silently.

    public enum AskKey {
        public static let title = "Open Ask with"
        /// Beside "Opens Ask with Shift twice" in the Accessibility row.
        public static let change = "Change…"
        public static let shiftTwiceLine = "Press either Shift twice. It works on every keyboard."
        public static let fnLine = "Tap Fn by itself. Fn with arrows and function keys keeps working."
        public static let cancel = "Cancel"
        /// Takes Fn over what else uses it: the person's own click.
        public static let useFn = "Use Fn"
        public static let openKeyboardSettings = "Open Keyboard Settings"
        /// A keyboard without Fn: Shift twice opens Ask meanwhile.
        public static let noFnKey = "This keyboard has no Fn key, so Shift twice opens Ask."
        /// macOS's own setting, the exact step in Keyboard settings. The
        /// setting's label draws a globe; the words name the key instead.
        public static let globeStep = "In Keyboard settings, choose Do Nothing for the Globe key."

        /// A known Fn app is installed: say so by name, and the two ways on.
        public static func appsUseFn(_ names: [String]) -> String {
            switch names.count {
            case 0: return ""
            case 1: return "\(names[0]) uses Fn. Pick another key, or turn Fn off in \(names[0])."
            case 2: return "\(names[0]) and \(names[1]) use Fn. Pick another key, or turn Fn off in both."
            default:
                let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
                return "\(list) use Fn. Pick another key, or turn Fn off in each."
            }
        }

        /// What macOS does with the Globe key now.
        public static func globeUsesFn(_ action: GlobeKeyAction) -> String {
            switch action {
            case .changeInputSource: "macOS uses the Globe key to change the input source."
            case .showEmojiAndSymbols: "macOS uses the Globe key to show Emoji & Symbols."
            case .startDictation: "macOS uses the Globe key to start Dictation."
            case .macOSDefault, .doNothing: "macOS uses the Globe key for its own shortcut."
            }
        }
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
