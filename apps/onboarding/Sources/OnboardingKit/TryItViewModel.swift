// SPDX-License-Identifier: TBD-private
//
// TryItViewModel — the last setup screen. It shows the first thing
// Hippocampus read, speaks to the app in front when nothing was read yet,
// and ends when the person opens Ask.
//
// Timeline, from consent: "Turning on…" for 3 s; the first read about 2 s
// in, then every 2 s; a proof as soon as one exists (a newer one replaces
// it); "Still nothing read" after 45 s with none. Reading stops 30 s after
// the first proof, or 3 minutes in, whichever comes first. When the app
// posts `ai.hippocampus.ask.didShow` the card ends on "That’s it.".

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Whether the app was remembering when it opened setup again. A first
/// run is always `on`: consent starts it.
public enum RememberingState: String, Sendable, Equatable {
    case on
    case paused
    case off

    public static let environmentKey = "MCI_ONBOARDING_REMEMBERING"

    /// The app's state at spawn; missing or unknown means `on`.
    public init(environment: [String: String]) {
        self = environment[Self.environmentKey].flatMap(RememberingState.init(rawValue:)) ?? .on
    }
}

/// What the waiting card says about the app in front.
public enum FrontAppNote: Equatable, Sendable {
    /// "Nothing read yet. Open a document, note or chat, then come back."
    case ordinary
    /// System Settings, a password manager: "{App} is never read."
    case neverRead(app: String)
    /// A browser with no way to be read: "{Browser} isn’t read."
    case unreadBrowser(browser: String)
    /// Safari, Arc: "{Browser} isn’t read until you add the extension."
    case needsExtension(browser: String)
    /// Chrome, Canary, Brave, Edge: macOS asks before Hippocampus can tell
    /// a private window from a normal one.
    case browserWillAsk(browser: String)

    /// The helper's lists, mirrored (a parity test holds them to the
    /// capture helper's sources): apps whose windows are never read…
    static let neverReadApps: Set<String> = [
        "com.1password.1password", "com.1password.1password7",
        "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.dashlane",
        "com.lastpass.lastpass", "com.apple.keychainaccess",
        "com.apple.passwords", "com.apple.systempreferences",
        "com.apple.usernotificationcenter", "com.apple.securityagent",
        "com.apple.loginwindow", "com.apple.screensaver.engine", "com.apple.screensaver",
    ]
    /// …browsers whose pixels are never read without a privacy check…
    static let pixelExcludedBrowsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.apple.SafariTechnologyPreview", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
    ]
    /// …and the browsers that check can ask, which raises macOS's prompt.
    static let privacyCheckedBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
    ]
    /// Browsers the extension panel can install into.
    static var extensionBrowsers: Set<String> {
        Set(knownBrowsers.map(\.bundleId))
    }

    public init(bundleId: String?, name: String?) {
        guard let bundleId, !bundleId.isEmpty else {
            self = .ordinary
            return
        }
        let shown = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? BundleDisplayNameResolver.displayName(for: bundleId)
        if Self.neverReadApps.contains(bundleId.lowercased()) {
            self = .neverRead(app: shown)
        } else if Self.privacyCheckedBrowsers.contains(bundleId) {
            self = .browserWillAsk(browser: shown)
        } else if Self.pixelExcludedBrowsers.contains(bundleId) {
            self = Self.extensionBrowsers.contains(bundleId)
                ? .needsExtension(browser: shown) : .unreadBrowser(browser: shown)
        } else {
            self = .ordinary
        }
    }
}

/// Why nothing was read after 45 s, when that can be told.
public enum StallCause: Equatable, Sendable {
    case permissionOff(PermissionSurface)
    case frontApp(FrontAppNote)
    /// "Still nothing read." with "Restart Hippocampus".
    case unknown
}

@MainActor
public final class TryItViewModel: ObservableObject {
    public enum Card: Equatable, Sendable {
        /// "Turning on…"
        case starting
        case waiting(FrontAppNote)
        case proof(ReadProof)
        case stalled(StallCause)
        case notRemembering(RememberingState)
        /// Ask opened: "That’s it. Shift twice works anywhere."
        case finished
    }

    public static let askDidShowNotification = Notification.Name("ai.hippocampus.ask.didShow")
    public static let startingFor: TimeInterval = 3
    public static let firstReadAfter: TimeInterval = 2
    public static let readEvery: TimeInterval = 2
    public static let stalledAfter: TimeInterval = 45
    public static let readingAfterProof: TimeInterval = 30
    public static let readingAtMost: TimeInterval = 180
    /// Review mode looks back this far for something to show.
    public static let reviewLookBack: TimeInterval = 30

    /// Where reading starts: consent on a first run, otherwise 30 s ago.
    public static func cursor(consentGivenAtUs: UInt64?, now: Date) -> UInt64 {
        consentGivenAtUs
            ?? FourScreenFlowViewModel.microseconds(now.addingTimeInterval(-reviewLookBack))
    }

    @Published public private(set) var card: Card = .starting
    @Published public private(set) var latestProof: ReadProof?
    /// The last app the person brought forward that is not Hippocampus.
    @Published public private(set) var frontApp: (bundleId: String, name: String?)?
    public private(set) var isReading = true

    private let probe: any LastReadProbe
    private let startedAt: Date
    private var cursor: UInt64
    private let remembering: RememberingState
    private let now: () -> Date
    private let permissionsOn: () -> (screenRecording: Bool, accessibility: Bool)
    private let nameFor: (String) -> String
    private var lastReadAt: Date?
    private var firstProofAt: Date?
    private var observers: [Any] = []

    /// - Parameters:
    ///   - startedAt: consent on a first run; when the screen opened in review.
    ///   - cursorTsUs: show only what was saved after this, in microseconds.
    ///   - remembering: `.on` on a first run; the app's state in review.
    public init(
        probe: any LastReadProbe,
        startedAt: Date,
        cursorTsUs: UInt64,
        remembering: RememberingState = .on,
        now: @escaping () -> Date = Date.init,
        permissionsOn: @escaping () -> (screenRecording: Bool, accessibility: Bool) = { (true, true) },
        nameFor: @escaping (String) -> String = BundleDisplayNameResolver.displayName(for:)
    ) {
        self.probe = probe
        self.startedAt = startedAt
        self.cursor = cursorTsUs
        self.remembering = remembering
        self.now = now
        self.permissionsOn = permissionsOn
        self.nameFor = nameFor
        if remembering != .on {
            card = .notRemembering(remembering)
            isReading = false
        }
    }

    /// Run the timeline once a second until Ask opens. Call from the
    /// screen's task; cancelling the task stops it and the reader.
    public func run(sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            await tick()
            if case .finished = card { break }
            await sleep(.seconds(1))
        }
        await stopReading()
    }

    /// One step: read when due, stop reading when it is time, choose the card.
    public func tick() async {
        if case .finished = card { return }
        if case .notRemembering = card { return }
        let elapsed = now().timeIntervalSince(startedAt)
        if isReading, elapsed >= Self.firstReadAfter, readIsDue() {
            lastReadAt = now()
            if case .rows(let rows, let newest) = await probe.rows(after: cursor) {
                if let newest { cursor = max(cursor, newest) }
                consider(rows)
            }
        }
        if isReading, shouldStopReading(elapsed: elapsed) {
            await stopReading()
        }
        // Ask may have opened while this step waited.
        if case .finished = card { return }
        card = chooseCard(elapsed: elapsed)
    }

    /// The person brought an app forward.
    public func appActivated(bundleId: String?, name: String?) {
        guard let bundleId, !ReadProof.ownBundleIds.contains(bundleId.lowercased()) else { return }
        frontApp = (bundleId, name)
    }

    /// The app showed Ask: the person found the key. The card ends here.
    public func askDidShow() {
        card = .finished
        Task { await stopReading() }
    }

    public func stopReading() async {
        guard isReading else { return }
        isReading = false
        await probe.stop()
    }

    #if canImport(AppKit)
    /// Listen for Ask showing and for the app in front. The screen calls
    /// this when it appears and `stopObserving()` when it goes.
    public func observeSystem() {
        guard observers.isEmpty else { return }
        let ask = DistributedNotificationCenter.default().addObserver(
            forName: Self.askDidShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.askDidShow() }
        }
        let activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleId = app?.bundleIdentifier
            let name = app?.localizedName
            MainActor.assumeIsolated { self?.appActivated(bundleId: bundleId, name: name) }
        }
        observers = [ask, activation]
    }

    public func stopObserving() {
        guard observers.count == 2 else { return }
        DistributedNotificationCenter.default().removeObserver(observers[0])
        NSWorkspace.shared.notificationCenter.removeObserver(observers[1])
        observers.removeAll()
    }
    #endif

    // MARK: - Choosing

    private func readIsDue() -> Bool {
        guard let lastReadAt else { return true }
        return now().timeIntervalSince(lastReadAt) >= Self.readEvery
    }

    private func shouldStopReading(elapsed: TimeInterval) -> Bool {
        if elapsed >= Self.readingAtMost { return true }
        if let firstProofAt, now().timeIntervalSince(firstProofAt) >= Self.readingAfterProof { return true }
        return false
    }

    private func consider(_ rows: [ReadRow]) {
        guard let proof = ReadProof.choose(
            from: rows, lastActivatedApp: frontApp?.bundleId, nameFor: nameFor
        ) else { return }
        // Each read starts after the newest row already seen, so a proof
        // from it is newer and replaces the card.
        if let shown = latestProof, proof.tsUs <= shown.tsUs { return }
        latestProof = proof
        if firstProofAt == nil { firstProofAt = now() }
    }

    private func chooseCard(elapsed: TimeInterval) -> Card {
        if let latestProof { return .proof(latestProof) }
        if elapsed < Self.startingFor { return .starting }
        let note = FrontAppNote(bundleId: frontApp?.bundleId, name: frontApp?.name)
        if elapsed >= Self.stalledAfter { return .stalled(stallCause(note)) }
        return .waiting(note)
    }

    private func stallCause(_ note: FrontAppNote) -> StallCause {
        let on = permissionsOn()
        if !on.screenRecording { return .permissionOff(.screenRecording) }
        if !on.accessibility { return .permissionOff(.accessibility) }
        if note != .ordinary { return .frontApp(note) }
        return .unknown
    }
}
