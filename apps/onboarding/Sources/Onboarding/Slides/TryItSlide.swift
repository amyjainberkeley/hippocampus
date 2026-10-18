import SwiftUI
import AppKit
import OnboardingKit

/// Screen 5. Remembering is on. Hippocampus reads the person's real window
/// in front, the one behind setup, and the screen shows what it read from
/// it, or says plainly why that window is skipped. It ends when Ask opens.
/// `TryItPresentation` decides what each state says.
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
        let windows = WindowServerFrontWindowSource()
        _tryIt = StateObject(wrappedValue: TryItViewModel(
            probe: AgentLastReadProbe(launcher: AgentReaderLauncher()),
            startedAt: consentGivenAtUs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) } ?? now,
            cursorTsUs: TryItViewModel.cursor(consentGivenAtUs: consentGivenAtUs, now: now),
            remembering: remembering,
            turningOn: consentGivenAtUs != nil,
            permissionsOn: permissionsOn,
            frontWindow: { windows.frontWindow() },
            rules: ReadRules(excludedApps: PersonExclusions.load()),
            passwordFieldInUse: { SecureTextEntry.isOn() },
            requestFreshRead: { SetupReadRequest.post() }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: presentation.title)

                if let proof = presentation.proof {
                    ProofCard(proof: proof, now: now, locale: locale)
                        .transition(OnboardingDesign.Motion.entrance(reduceMotion: reduceMotion))
                    underProof
                } else {
                    status
                        .frame(maxWidth: .infinity, minHeight: Self.statusHeight)
                }
            }
            .animation(OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.standard, reduceMotion: reduceMotion),
                       value: presentation)
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
                    .foregroundStyle(OnboardingDesign.Palette.on)
                    .accessibilityHidden(true)
                Text(finished)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let heading = presentation.heading {
            VStack(spacing: OnboardingDesign.Space.lg) {
                StatusIcon(icon: presentation.icon, working: presentation.isWorking)
                VStack(spacing: OnboardingDesign.Space.xs + 2) {
                    Text(heading)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.spoken ?? heading)
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
                        .font(.system(size: 15, weight: .medium))
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

/// Beside a status: the app it is about, crossed out when its window is
/// skipped, or a symbol. A small spinner while it reads.
private struct StatusIcon: View {
    let icon: TryItPresentation.Icon?
    let working: Bool

    var body: some View {
        Group {
            switch icon {
            case .app(let bundleId, let skipped):
                AppIconImage(bundleId: bundleId, side: 56, grey: skipped)
                    .opacity(skipped ? 0.7 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if skipped {
                            badge("eye.slash")
                        } else if working {
                            ProgressView().controlSize(.small)
                                .padding(4)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 6, y: 6)
                        }
                    }
            case .symbol(let name):
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OnboardingDesign.Palette.accentSoft)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: name)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(OnboardingDesign.Palette.accent)
                    )
            case nil:
                if working {
                    ProgressView()
                        .frame(width: 56, height: 56)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(OnboardingDesign.Palette.ink.opacity(0.85)))
            .offset(x: 6, y: 6)
    }
}

/// What was read: the window, when, and up to three of its lines, drawn as
/// Hippocampus draws a moment it remembers.
struct ProofCard: View {
    let proof: ReadProof
    /// A fixed clock for the preview renderer; nil counts the seconds.
    let now: Date?
    var locale: Locale = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OnboardingDesign.Space.md) {
                AppIconImage(bundleId: proof.appBundleId, side: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(OnboardingCopy.proofHeading(proof))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    readAgo
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OnboardingDesign.Space.lg + 2)
            .padding(.vertical, OnboardingDesign.Space.md + 2)
            if !proof.lines.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
                    ForEach(Array(proof.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: OnboardingDesign.Space.sm + 2) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(MiniPalette.border)
                                .frame(width: 2.5)
                            Text(line)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, OnboardingDesign.Space.lg + 2)
                .padding(.vertical, OnboardingDesign.Space.lg)
            }
        }
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
}
