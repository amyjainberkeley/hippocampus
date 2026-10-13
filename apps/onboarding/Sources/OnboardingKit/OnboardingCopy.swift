import Foundation

/// Load-bearing user-facing copy strings that are asserted on by
/// `OnboardingKitTests`. Kept in `OnboardingKit` (not in the SwiftUI
/// slide files) so tests can hold ground truth without importing the
/// executable target.
///
/// Why this exists (cycle 8.38 onboarding audit, PR-2):
/// - Fix (a) The `howItWorksFootprint` copy must reflect the
///   2026-05-31 amended footprint SLO (≤ 10–15% CPU / ≤ 2 GB RAM).
///   The prior "under 2% CPU / under 250 MB RAM" string set the
///   user's expectation 5× too aggressive — CEO Amy flagged this as a
///   trust-budget bug on the CRS 8.32 scan.
/// - Fix (b) The `welcomeRewindSubheader` copy is triggered by a
///   `onboarding://start?migration=rewind` deep-link fired from the
///   `/rewind` landing lane (cycle 8.37 PR #30).
/// - Fix (c) `doneMenuBarHint` replaces the previous shortcut promises
///   for `⇧⌘F` / `⇧⌘P` — neither is bound anywhere in HippocampusApp,
///   so the copy is a plain-English menu-bar reminder instead of a lie.
public enum OnboardingCopy {
    /// `HowItWorksSlide` featureRow — footprint SLO paraphrase for
    /// non-technical users. Must contain "15%" and "2 GB" so any
    /// future edit that regresses to the pre-2026-05-31 tight bar
    /// (or drops the amended numbers entirely) fails a unit test.
    public static let howItWorksFootprint = "Runs quietly in the background — typically under 15% of one CPU core and under 2 GB of memory during a full-day session."

    /// `WelcomeSlide` sub-header shown only when the flow VM's
    /// `migrationSource == .rewind`. Copy chosen to reassure a
    /// user coming from Rewind's 2025-12-19 sunset that Hippocampus
    /// is fully local — the biggest concern of the ex-Rewind cohort
    /// per the CRS 8.37 competitor scan.
    public static let welcomeRewindSubheader = "Welcome from Rewind. Your data stays on your Mac — nothing uploaded, nothing shared."

    /// `DoneSlide` — replaces the previous `⇧⌘F` / `⇧⌘P` shortcut
    /// promises. Do NOT add hotkey copy back unless `HippocampusApp`
    /// actually binds a global hotkey (recall-UI audit PR-5).
    public static let doneMenuBarHint = "You can open Hippocampus from the menu bar icon anytime."

    /// Captured memory has no Hippocampus cloud copy, but a user can request
    /// context through a connected third-party AI client. These strings keep
    /// that provider boundary visible in both the welcome and trust screens.
    public static let welcomeAIHandoff = "Hippocampus keeps no cloud copy. Context you request through a connected AI tool follows that provider's terms."

    public static let trustAIHandoff = "Connected AI tools receive only context you request and follow their provider terms."

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
    /// Shown when there is no clip: search works on every Mac.
    public static let welcomeFallback = "Type a word. Find where you saw it."
    /// Under the clip, once it ships.
    public static let welcomeClipCaption = "Sample data."
    public static let getStarted = "Get Started"

    /// The body as one sentence, keycaps written out.
    public static func welcomeBody(_ key: AskKeyHint) -> String {
        "\(key.verb) \(key.keycaps.joined(separator: " ")) \(welcomeBodyAfterKeys)"
    }

    // Permissions

    public static let permissionsTitle = "Two permissions"
    public static let permissionsBody = "macOS asks before any app can read the screen."
    /// First run only: until consent the app does not start reading.
    public static let permissionsNothingYet = "Nothing is read until you click Start Remembering."
    public static let screenRecordingName = "Screen Recording"
    public static let screenRecordingWhy = "So it can read what’s on your screen."
    /// macOS 15 and later. The capture helper sets up no audio stream.
    public static let screenRecordingSoundNote = "macOS calls this Screen & System Audio Recording. Hippocampus doesn’t use sound."
    public static let accessibilityName = "Accessibility"
    public static let accessibilityWhyBase = "So it knows which window you’re in and skips password fields."
    public static let allow = "Allow"
    public static let waitingForSettings = "Waiting for System Settings…"
    public static let screenRecordingWaitingHint = "Turn on Hippocampus in the list. If macOS offers Quit & Reopen, choose Later."
    public static let accessibilityWaitingHint = "Turn on Hippocampus in the list."
    public static let notOnYet = "Not on yet."
    public static let needsHelpHint = "Turn on Hippocampus in the list. Not there? Click + and choose Hippocampus in Applications."
    public static let openSettings = "Open Settings"
    public static let askAgain = "Ask Again"
    public static let permissionOn = "On"
    public static let permissionsFooter = "Change either one any time in System Settings."
    public static let continueLabel = "Continue"

    /// The Accessibility row. A single key or Shift twice needs it too.
    public static func accessibilityWhy(_ key: AskKeyHint) -> String {
        guard let noun = key.noun else { return accessibilityWhyBase }
        return "\(accessibilityWhyBase) It also lets \(noun) open Ask."
    }

    // Promise

    public static let promiseTitle = "Before it starts"
    public static let promiseBody = "When you click Start Remembering, Hippocampus begins reading your screen."
    public static let promiseStaysLead = "Stays on this Mac."
    public static let promiseNeverReadLead = "Never read."
    /// Password fields: the focused-window path drops the frame during
    /// secure input or on a secure field, and the extension never reads
    /// input values. Private windows: browser pixels need a positive
    /// normal-window check, and the extension skips incognito. Password
    /// managers: the app list the helper never reads.
    public static let promiseNeverRead = "Password fields, private browser windows and password managers."
    public static let promiseStopLead = "You can stop it."
    public static let promiseStop = "Pause from the menu bar. Quit ends it."
    public static let openAtLogin = "Open Hippocampus at login"
    public static let startRemembering = "Start Remembering"
    public static let settingUpEncryption = "Setting up encryption…"
    public static let encryptionFailed = "Couldn’t set up encryption."
    public static let tryAgain = "Try Again"
    public static let consentFailedTitle = "Couldn’t start"
    public static let consentFailedMessage = "Couldn’t save your setup. Free up some disk space and try again."

    /// The first Promise line, after "Stays on this Mac.".
    ///
    /// "Nothing is uploaded by Hippocampus." holds in code (RULINGS O10,
    /// product critique finding 13): the client's only network calls are
    /// the optional model download and update check (fetches, with system
    /// profiling off), loopback-only MCP servers and crash reports, and a
    /// feedback link opened in the browser. The `server` crate is not a
    /// dependency of anything shipped. The last sentence is the provider
    /// boundary engineering critique 8 keeps at consent.
    public static func promiseStays(kept: String) -> String {
        "Text and screenshots, encrypted, \(kept). Nothing is uploaded by Hippocampus. What connected AI tools read goes to the company that runs them."
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
    public static let tryItStillNothing = "Still nothing read."
    public static let restartHippocampus = "Restart Hippocampus"
    public static let addExtension = "Add Extension"
    public static let openItForMe = "Open it for me"
    public static let tryItPaused = "Remembering is paused. Resume it from the menu bar."
    public static let tryItOff = "Remembering is off. Turn it on from the menu bar."
    /// Once a proof shows: where the indicator is, and what it does.
    public static let stopSharingNote = "macOS shows an icon in the menu bar while Hippocampus reads. Stop Sharing there ends it."
    public static let answersNeedAppleIntelligence = "Answers need Apple Intelligence. Search works without it."
    public static let appleIntelligencePreparing = "Apple Intelligence is getting ready. Search works now."
    public static let answersUnsupported = "Search works. Answers need Apple Intelligence."
    public static let done = "Done"

    /// The waiting card, by the app in front.
    public static func waitingText(_ note: FrontAppNote) -> String {
        switch note {
        case .ordinary: tryItWaiting
        case .neverRead(let app): "\(app) is never read. Try a document, note or chat."
        case .unreadBrowser(let browser): "\(browser) isn’t read. Try a document, note or chat."
        case .needsExtension(let browser): "\(browser) isn’t read until you add the extension."
        case .browserWillAsk(let browser): "macOS will ask about \(browser). Choose Allow so Hippocampus can skip private windows."
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

    /// Under a proof: what to try now. With Apple Intelligence a question
    /// works; without it, a word from the window still finds it.
    public static func tryItNext(_ key: AskKeyHint, answersAvailable: Bool) -> String {
        let press = key.phrase.prefix(1).lowercased() + key.phrase.dropFirst()
        return answersAvailable
            ? "Now \(press) and ask about it."
            : "Now \(press) and type a word from that window."
    }

    /// When Ask opens: "That’s it. Shift twice works anywhere."
    public static func tryItFinished(_ key: AskKeyHint) -> String {
        let name = key.sentenceName
        return "That’s it. \(name.prefix(1).uppercased() + name.dropFirst()) works anywhere."
    }
}
