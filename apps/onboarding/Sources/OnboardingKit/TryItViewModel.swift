// SPDX-License-Identifier: Apache-2.0
//
// TryItViewModel — the last setup screen. It reads the person's real window
// in front, shows what was read from it, says plainly when that window is
// skipped, and ends when the person opens Ask.
//
// The window in front is the frontmost window that is not Hippocampus's own
// (`FrontWindow`): right after consent, the one behind setup's window. It is
// read by the app like any other window, under the same rules: never-read
// apps, the person's exclusions, private browser windows and password fields
// are skipped (`ReadRules`, `SkipReason`). When the person brings another
// window forward, setup asks the app for one fresh read of it, past the
// reader's rest (`requestFreshRead`).
//
// Timeline, from consent: "Turning on…" for 3 s; the first read about 2 s
// in, then every 2 s; a proof as soon as one with a sentence exists (a newer
// one replaces it); "Still nothing read" after 45 s with none. Reading stops
// 30 s after the first proof, or 3 minutes in, whichever comes first. When
// the app posts `ai.hippocampus.ask.didShow` the card ends on "That’s it.",
// or on "That’s Ask." when Ask opened because the person clicked "Open it
// for me", which proves nothing about the key.
//
// In review (Show Setup Again) remembering was already on, so there is no
// "Turning on…". "Try Again" on a stalled card has the app restart
// remembering in place, and the timeline starts over with it.
//
// A stalled card names a permission that is off only from a check made
// then: what setup saw at consent may no longer be true.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Whether the app was remembering when it opened setup again. It counts
/// only in review: a first run is always `on`, because consent starts it
/// (`OnboardingFlowViewModel.rememberingForTryIt`).
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

/// Why nothing was read after 45 s, when that can be told. A skipped window
/// is not a stall: its card says why from the start.
public enum StallCause: Equatable, Sendable {
    case permissionOff(PermissionSurface)
    /// "Still nothing read." with "Try Again".
    case unknown
}

@MainActor
public final class TryItViewModel: ObservableObject {
    public enum Card: Equatable, Sendable {
        /// "Turning on…": consent just started remembering.
        case starting
        /// The window in front is being read, and nothing from it shows yet.
        case reading(FrontWindow)
        /// No window is open but setup's own.
        case noWindow
        /// The window in front was read and holds no sentence worth showing.
        case nothingToShow(FrontWindow)
        /// The window in front is not read, and why. Nil when secure text
        /// entry is on and no window is in front.
        case skipped(SkipReason, FrontWindow?)
        case proof(ReadProof)
        case stalled(StallCause)
        case notRemembering(RememberingState)
        /// Ask opened: "That’s it. Shift twice works anywhere." With
        /// `openedForThem`, Ask opened right after "Open it for me".
        case finished(openedForThem: Bool)
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
    /// Ask showing this soon after "Open it for me" was opened for them.
    public static let openedForThemWithin: TimeInterval = 10

    /// Where reading starts: consent on a first run, otherwise 30 s ago.
    public static func cursor(consentGivenAtUs: UInt64?, now: Date) -> UInt64 {
        consentGivenAtUs
            ?? OnboardingFlowViewModel.microseconds(now.addingTimeInterval(-reviewLookBack))
    }

    @Published public private(set) var card: Card = .starting
    @Published public private(set) var latestProof: ReadProof?
    /// The last app the person brought forward that is not Hippocampus.
    @Published public private(set) var frontApp: (bundleId: String, name: String?)?
    /// The window Try it reads now: the window in front.
    @Published public private(set) var target: FrontWindow?
    public private(set) var isReading = true

    private let probe: any LastReadProbe
    private var startedAt: Date
    private var cursor: UInt64
    private let remembering: RememberingState
    /// Remembering was started for this screen (consent, or Try Again), so
    /// it opens on "Turning on…".
    private var turningOn: Bool
    private let now: () -> Date
    private let permissionsOn: @MainActor () async -> (screenRecording: Bool, accessibility: Bool)
    private let nameFor: (String) -> String
    private let frontWindow: @MainActor () -> FrontWindow?
    private let rules: ReadRules
    private let passwordFieldInUse: @MainActor () -> Bool
    private let requestFreshRead: @MainActor () -> Void
    private var lastReadAt: Date?
    private var firstProofAt: Date?
    private var openedForThemAt: Date?
    /// Bumped by Try Again. A step that started before it decides nothing.
    private var timeline = 0
    private var observers: [Any] = []

    /// - Parameters:
    ///   - startedAt: consent on a first run; when the screen opened in review.
    ///   - cursorTsUs: show only what was saved after this, in microseconds.
    ///   - remembering: `.on` on a first run; the app's state in review.
    ///   - turningOn: true on a first run, where consent just started
    ///     remembering; false in review, where it was already on.
    ///   - permissionsOn: checks both permissions now. Asked only when
    ///     nothing was read for 45 s, to name the cause.
    ///   - frontWindow: the window in front now (`WindowServerFrontWindowSource`).
    ///     Nil falls back to the last app the person brought forward.
    ///   - rules: which windows the app skips.
    ///   - passwordFieldInUse: secure text entry is on (`SecureTextEntry`).
    ///   - requestFreshRead: asks the app to read the window in front once,
    ///     now, as opening Ask does.
    public init(
        probe: any LastReadProbe,
        startedAt: Date,
        cursorTsUs: UInt64,
        remembering: RememberingState = .on,
        turningOn: Bool = true,
        now: @escaping () -> Date = Date.init,
        permissionsOn: @escaping @MainActor () async -> (screenRecording: Bool, accessibility: Bool) = { (true, true) },
        nameFor: @escaping (String) -> String = BundleDisplayNameResolver.displayName(for:),
        frontWindow: @escaping @MainActor () -> FrontWindow? = { nil },
        rules: ReadRules = ReadRules(),
        passwordFieldInUse: @escaping @MainActor () -> Bool = { false },
        requestFreshRead: @escaping @MainActor () -> Void = {}
    ) {
        self.probe = probe
        self.startedAt = startedAt
        self.cursor = cursorTsUs
        self.remembering = remembering
        self.turningOn = turningOn
        self.now = now
        self.permissionsOn = permissionsOn
        self.nameFor = nameFor
        self.frontWindow = frontWindow
        self.rules = rules
        self.passwordFieldInUse = passwordFieldInUse
        self.requestFreshRead = requestFreshRead
        if remembering != .on {
            card = .notRemembering(remembering)
            isReading = false
        } else if !turningOn {
            // Remembering was already on: the card speaks to the window in
            // front from the start.
            target = currentTarget()
            card = target.map(Card.reading) ?? .noWindow
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

    /// One step: find the window in front, read when due, stop reading when
    /// it is time, choose the card.
    public func tick() async {
        if case .finished = card { return }
        if case .notRemembering = card { return }
        let timeline = self.timeline
        let elapsed = now().timeIntervalSince(startedAt)
        let window = currentTarget()
        if window != target { target = window }
        if isReading, elapsed >= Self.firstReadAfter, readIsDue() {
            lastReadAt = now()
            if case .rows(let rows, let newest) = await probe.rows(after: cursor) {
                if let newest { cursor = max(cursor, newest) }
                consider(rows)
            }
        }
        // Try Again started the screen over while this step read: what was
        // read counts, and the next step decides on the new clock.
        guard timeline == self.timeline else { return }
        if isReading, shouldStopReading(elapsed: elapsed) {
            await stopReading()
        }
        // Ask may have opened while this step waited.
        if case .finished = card { return }
        let next = await chooseCard(elapsed: elapsed)
        // …or opened, or Try Again started over, while the permissions
        // were checked.
        if case .finished = card { return }
        guard timeline == self.timeline else { return }
        card = next
    }

    /// The person brought an app forward. Its window is the one in front
    /// now; unless it is skipped, the app is asked to read it once, now,
    /// rather than after the reader's rest.
    public func appActivated(bundleId: String?, name: String?) {
        guard let bundleId, !ReadProof.ownBundleIds.contains(bundleId.lowercased()) else { return }
        frontApp = (bundleId, name)
        guard isReading, remembering == .on, !hasProofToShow else { return }
        if case .finished = card { return }
        let window = FrontWindow(bundleId: bundleId, appName: name ?? nameFor(bundleId), title: nil)
        guard rules.skipReason(for: window) == nil, !passwordFieldInUse() else { return }
        requestFreshRead()
    }

    /// "Open it for me" is about to open `hippocampus://ask`. Ask showing
    /// soon after is that link, not the key.
    public func willOpenAskForThem() {
        openedForThemAt = now()
    }

    /// The app showed Ask. The card ends here: on the key, unless Ask
    /// opened right after "Open it for me". A later show by the key turns
    /// "That’s Ask." into "That’s it.".
    public func askDidShow() {
        let forThem = openedForThemAt.map { now().timeIntervalSince($0) < Self.openedForThemWithin } ?? false
        if forThem { openedForThemAt = nil }
        if case .finished(openedForThem: false) = card { return }
        card = .finished(openedForThem: forThem)
        Task { await stopReading() }
    }

    /// "Try Again" on a stalled card, after the app was asked to restart
    /// remembering (`hippocampus://restart`). The screen starts over with
    /// it: "Turning on…", then reading for up to another three minutes.
    public func tryAgain() async {
        guard remembering == .on else { return }
        if case .finished = card { return }
        timeline += 1
        startedAt = now()
        turningOn = true
        lastReadAt = nil
        card = await chooseCard(elapsed: 0)
        if !isReading {
            isReading = true
            await probe.resume()
        }
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

    /// A proof with a sentence in it: the screen has done its job.
    private var hasProofToShow: Bool {
        latestProof.map { !$0.lines.isEmpty } ?? false
    }

    /// The window in front, or the last app brought forward when the window
    /// list says nothing.
    private func currentTarget() -> FrontWindow? {
        if let window = frontWindow() { return window }
        guard let app = frontApp else { return nil }
        return FrontWindow(bundleId: app.bundleId, appName: app.name ?? nameFor(app.bundleId), title: nil)
    }

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
            from: rows, lastActivatedApp: target?.bundleId, nameFor: nameFor
        ) else { return }
        if let shown = latestProof {
            // Each read starts after the newest row already seen, so a proof
            // from it is newer; it replaces the card unless it would take a
            // sentence away.
            if proof.tsUs <= shown.tsUs { return }
            if !shown.lines.isEmpty, proof.lines.isEmpty { return }
        }
        latestProof = proof
        if !proof.lines.isEmpty, firstProofAt == nil { firstProofAt = now() }
    }

    private func chooseCard(elapsed: TimeInterval) async -> Card {
        if let latestProof, !latestProof.lines.isEmpty { return .proof(latestProof) }
        if turningOn, elapsed < Self.startingFor { return .starting }
        let window = target
        if elapsed >= Self.stalledAfter {
            // Checked now, not taken from consent: a permission turned off
            // since is the cause most worth naming.
            let on = await permissionsOn()
            if !on.screenRecording { return .stalled(.permissionOff(.screenRecording)) }
            if !on.accessibility { return .stalled(.permissionOff(.accessibility)) }
        }
        if passwordFieldInUse() { return .skipped(.passwordField, window) }
        if let window, let reason = rules.skipReason(for: window) { return .skipped(reason, window) }
        guard let window else { return .noWindow }
        if let latestProof, latestProof.appBundleId == window.bundleId { return .nothingToShow(window) }
        if elapsed >= Self.stalledAfter { return .stalled(.unknown) }
        return .reading(window)
    }
}
