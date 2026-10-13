import SwiftUI
import AppKit
import OnboardingKit

/// Screen 4. Remembering is on. The card shows the first thing it read,
/// or says what to do until it has; the screen ends when Ask opens.
/// `TryItPresentation` decides what each card says.
struct TryItSlide: View {
    @StateObject private var tryIt: TryItViewModel
    /// Whether answers work on this Mac; nil until the check answers.
    @State private var understanding: UnderstandingAvailability?
    private let openSettings: (PermissionSurface) -> Void

    /// - Parameters:
    ///   - consentGivenAtUs: set when this run gave consent. Then reading
    ///     starts there and the card opens on "Turning on…"; in review it
    ///     looks back a little and there is no "Turning on…".
    init(
        consentGivenAtUs: UInt64?,
        remembering: RememberingState,
        permissionsOn: @escaping @MainActor () async -> (screenRecording: Bool, accessibility: Bool),
        openSettings: @escaping (PermissionSurface) -> Void
    ) {
        let now = Date()
        _tryIt = StateObject(wrappedValue: TryItViewModel(
            probe: AgentLastReadProbe(launcher: AgentReaderLauncher()),
            startedAt: consentGivenAtUs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) } ?? now,
            cursorTsUs: TryItViewModel.cursor(consentGivenAtUs: consentGivenAtUs, now: now),
            remembering: remembering,
            turningOn: consentGivenAtUs != nil,
            permissionsOn: permissionsOn
        ))
        self.openSettings = openSettings
    }

    var body: some View {
        TryItScreen(
            presentation: TryItPresentation(card: tryIt.card, keyNow: .current(), understanding: understanding),
            now: nil,
            perform: perform
        )
        .task {
            tryIt.observeSystem()
            await tryIt.run()
        }
        .task {
            understanding = await UnderstandingProbe.check()
        }
        .onDisappear {
            tryIt.stopObserving()
        }
    }

    private func perform(_ action: TryItScreen.Action) {
        switch action {
        case .tryAgain:
            NSWorkspace.shared.open(AppLink.restart)
            Task { await tryIt.tryAgain() }
        case .openSettings(let surface):
            openSettings(surface)
        case .openItForMe:
            tryIt.willOpenAskForThem()
            NSWorkspace.shared.open(AppLink.ask)
        }
    }
}

/// The screen as drawn: the preview renderer builds it from fixture cards.
struct TryItScreen: View {
    enum Action: Equatable {
        case tryAgain
        case openSettings(PermissionSurface)
        case openItForMe
    }

    let presentation: TryItPresentation
    /// A fixed clock for the preview renderer; nil keeps time.
    let now: Date?
    var locale: Locale = .current
    let perform: (Action) -> Void

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: OnboardingCopy.tryItTitle)

                if let proof = presentation.proof {
                    ProofCard(proof: proof, now: now, locale: locale)
                    underProof
                } else {
                    status
                        .frame(maxWidth: .infinity, minHeight: Self.statusHeight)
                }
            }
        }
    }

    /// The room a status takes below the title, so it sits in the middle
    /// of the free space rather than under the title with nothing below.
    static let statusHeight: CGFloat = 330

    /// Before anything is read, and once Ask has opened.
    @ViewBuilder
    private var status: some View {
        if let finished = presentation.finished {
            VStack(spacing: OnboardingDesign.Space.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(OnboardingDesign.Palette.success)
                    .accessibilityHidden(true)
                Text(finished)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let message = presentation.messageParts {
            VStack(spacing: OnboardingDesign.Space.lg) {
                if presentation.isWorking {
                    ProgressView()
                } else {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(OnboardingDesign.Palette.accent)
                        .accessibilityHidden(true)
                }
                VStack(spacing: OnboardingDesign.Space.xs + 2) {
                    Text(message.heading)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                    if let detail = message.detail {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .accessibilityElement(children: .combine)
                if let action = presentation.screenAction {
                    Button(label(action)) { perform(action) }
                        .buttonStyle(RowButtonStyle(filled: false))
                }
            }
        }
    }

    /// What to try now, and the two things worth knowing once it reads.
    private var underProof: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            HStack(spacing: OnboardingDesign.Space.md) {
                if let next = presentation.next {
                    if !presentation.keycaps.isEmpty {
                        KeycapRow(keycaps: presentation.keycaps, size: 13)
                    }
                    Text(next)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: OnboardingDesign.Space.sm)
                    openItForMe
                } else {
                    // No key opens Ask now: the link is the way in.
                    openItForMe
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs) {
                if let note = presentation.stopSharingNote {
                    Text(note)
                }
                if let note = presentation.answersNote {
                    Text(note)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OnboardingDesign.Space.xs)
    }

    @ViewBuilder
    private var openItForMe: some View {
        if presentation.offersOpenItForMe {
            Button(OnboardingCopy.openItForMe) { perform(.openItForMe) }
                .onboardingText(color: OnboardingDesign.Palette.accentText)
        }
    }

    private func label(_ action: Action) -> String {
        switch action {
        case .tryAgain: OnboardingCopy.tryAgain
        case .openSettings: OnboardingCopy.openSettings
        case .openItForMe: OnboardingCopy.openItForMe
        }
    }
}

private extension TryItScreen.Action {
    init(_ action: TryItPresentation.Action) {
        switch action {
        case .tryAgain: self = .tryAgain
        case .openSettings(let surface): self = .openSettings(surface)
        }
    }
}

private extension TryItPresentation {
    var screenAction: TryItScreen.Action? { action.map(TryItScreen.Action.init) }
}

/// What was read: the app and window, when, and up to three lines.
struct ProofCard: View {
    let proof: ReadProof
    /// A fixed clock for the preview renderer; nil counts the seconds.
    let now: Date?
    var locale: Locale = .current

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            HStack(spacing: OnboardingDesign.Space.md) {
                Image(nsImage: Self.icon(for: proof.appBundleId))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(OnboardingCopy.proofHeading(proof))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    readAgo
                }
                Spacer(minLength: 0)
            }
            if !proof.lines.isEmpty {
                VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                    ForEach(Array(proof.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(OnboardingDesign.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 0)
        .accessibilityElement(children: .combine)
    }

    /// "Read 12 seconds ago", counting up once a second.
    @ViewBuilder
    private var readAgo: some View {
        if let now {
            readAgo(at: now)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                readAgo(at: context.date)
            }
        }
    }

    private func readAgo(at now: Date) -> some View {
        Text(OnboardingCopy.readAgo(proof.at, now: now, locale: locale))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    /// Icons already looked up, by app.
    @MainActor private static var icons: [String: NSImage] = [:]

    /// The app's own icon, or the generic one when it is not installed.
    static func icon(for bundleId: String) -> NSImage {
        if let known = icons[bundleId] { return known }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[bundleId] = icon
        return icon
    }
}
