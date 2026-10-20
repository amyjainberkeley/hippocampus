import SwiftUI
import AppKit
import OnboardingKit

/// Screen 3. Both permissions show at once, each framed by what it lets
/// Hippocampus do. "Allow" raises macOS's prompt only; the row then waits
/// until the person comes back to this window, and one refresh decides
/// whether it is on, when its checkmark appears. Nothing moves a row on a
/// timer. The window comes forward when the second one turns on.
///
/// A permission found on (SPEC 7.2): its tile crossfades from blue to the
/// calm green and "On" fades in as it grows to full size; VoiceOver hears
/// "Screen Recording is on.", and once both are, the footer and VoiceOver
/// say "Both are on. You can continue." After macOS's Quit & Reopen, the
/// row that came on shows its checkmark appearing once.
///
/// The Accessibility row names the key that opens Ask, with Change… for
/// setup's key picker (SPEC-DELTA 7).
struct PermissionsSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    /// The key the person chose, read at render time (RULINGS X2).
    @State private var key = AskKeyHint.current()
    @State private var announced: [PermissionSurface: PermissionRowState] = [:]
    @State private var keyPicker: AskKeyPickerModel?

    var body: some View {
        PermissionsScreen(
            intro: OnboardingCopy.permissionsBody(isReview: flowVM.isReview),
            rows: OnboardingFlowViewModel.rowSurfaces.map(row),
            perform: perform,
            changeKey: { keyPicker = AskKeyPickerModel(
                stored: AskShortcutLabel.storedValue(), facts: .thisMac,
                accepted: SetupAskKeyWriter.acceptedOnThisMac()
            ) },
            didShowTurnedOn: { surface in
                flowVM.didShowTurnedOn(surface)
                AccessibilityNotification.Announcement(OnboardingCopy.permissionIsOn(surface)).post()
            }
        )
        // The poll: about once a second while this screen shows.
        .task {
            while !Task.isCancelled {
                await flowVM.refreshPermissionsAsync()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Key setup starts here so the key is ready before consent;
        // it returns at once when the key is already ready.
        .task {
            await prepareBrainVM.generateKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await flowVM.userReturned() }
        }
        // Both on, likely from System Settings: come back to the front.
        .onChange(of: flowVM.bothTurnedOnCount) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.filter(\.isVisible).forEach { $0.orderFrontRegardless() }
        }
        // What turned on, said once (SPEC 7.2).
        .onAppear { announced = flowVM.rowStates }
        .onChange(of: flowVM.permissionRefreshCount) {
            let now = flowVM.rowStates
            if let words = PermissionAnnouncement.after(announced, now) {
                AccessibilityNotification.Announcement(words).post()
            }
            announced = now
        }
        .sheet(item: $keyPicker) { picker in
            AskKeySheet(
                model: picker,
                cancel: { keyPicker = nil },
                confirm: {
                    picker.confirm { chosen, accepted in
                        SetupAskKeyWriter.chooseOnThisMac(chosen, accepting: accepted)
                    }
                    key = AskKeyHint.current()
                    keyPicker = nil
                },
                openKeyboardSettings: { NSWorkspace.shared.open(KeyboardSettingsLink.url) }
            )
        }
    }

    private func row(_ surface: PermissionSurface) -> PermissionRowModel {
        PermissionRowModel(
            surface: surface,
            key: key,
            state: flowVM.rowState(surface),
            canAllow: flowVM.canRequest(surface),
            offersAskAgain: flowVM.offersAskAgain(surface),
            twoCopies: flowVM.twoCopiesInstalled,
            appearsOnce: flowVM.turnedOnWhileAway.contains(surface)
        )
    }

    private func perform(_ action: PermissionRowModel.Action, _ surface: PermissionSurface) {
        switch action {
        case .allow: flowVM.requestPermission(surface)
        case .openSettings: flowVM.openSettings(surface)
        case .askAgain: Task { await flowVM.askAgain(surface) }
        }
    }
}

/// What one row shows.
struct PermissionRowModel: Identifiable {
    enum Action { case allow, openSettings, askAgain }

    /// One thing the permission lets Hippocampus do.
    struct Benefit: Identifiable {
        let text: String
        let symbol: String
        /// The line that names the key that opens Ask: Change… sits by it.
        var namesTheKey = false
        var id: String { text }
    }

    let surface: PermissionSurface
    let name: String
    let benefits: [Benefit]
    let note: String?
    let state: PermissionRowState
    let canAllow: Bool
    let offersAskAgain: Bool
    /// macOS lists two copies of Hippocampus: the help says which.
    let twoCopies: Bool
    /// It came on while setup was closed: its checkmark appears once.
    let appearsOnce: Bool
    /// For the renderer's frames: this many seconds after it turned on.
    var drawnMoment: Double?

    var id: PermissionSurface { surface }

    init(
        surface: PermissionSurface,
        key: AskKeyHint,
        state: PermissionRowState,
        canAllow: Bool,
        offersAskAgain: Bool,
        twoCopies: Bool = false,
        appearsOnce: Bool = false,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        self.surface = surface
        switch surface {
        case .screenRecording:
            name = OnboardingCopy.screenRecordingName
            benefits = OnboardingCopy.screenRecordingBenefits.map { Benefit(text: $0, symbol: "text.viewfinder") }
            note = OnboardingCopy.screenRecordingNote(macOSMajorVersion: macOSMajorVersion)
        case .accessibility:
            name = OnboardingCopy.accessibilityName
            let symbols = ["macwindow", "lock", "keyboard"]
            let keyLine = OnboardingCopy.accessibilityKeyBenefit(key)
            benefits = OnboardingCopy.accessibilityBenefits(key).enumerated().map { index, text in
                Benefit(text: text, symbol: symbols[min(index, symbols.count - 1)], namesTheKey: text == keyLine)
            }
            note = nil
        }
        self.state = state
        self.canAllow = canAllow
        self.offersAskAgain = offersAskAgain
        self.twoCopies = twoCopies
        self.appearsOnce = appearsOnce
    }

    var symbol: String {
        switch surface {
        case .screenRecording: "rectangle.dashed"
        case .accessibility: "accessibility"
        }
    }

    /// What VoiceOver says the row's state is.
    var stateWords: String {
        switch state {
        case .granted: OnboardingCopy.permissionOn
        case .waiting: OnboardingCopy.waitingForSettings
        case .needsHelp: OnboardingCopy.notOnYet
        case .idle: OnboardingCopy.allow
        }
    }
}

/// The screen as drawn: the preview renderer builds it from fixture rows.
struct PermissionsScreen: View {
    let intro: String?
    let rows: [PermissionRowModel]
    let perform: (PermissionRowModel.Action, PermissionSurface) -> Void
    /// Opens setup's key picker; nil draws no Change… button.
    var changeKey: (() -> Void)?
    /// A row has shown its checkmark appearing after Quit & Reopen.
    var didShowTurnedOn: (PermissionSurface) -> Void = { _ in }

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: OnboardingCopy.permissionsTitle, intro: intro)

                VStack(spacing: OnboardingDesign.Space.xl) {
                    VStack(spacing: OnboardingDesign.Space.md) {
                        ForEach(rows) { row in
                            PermissionRowView(row: row, changeKey: changeKey, didShowTurnedOn: didShowTurnedOn) {
                                perform($0, row.surface)
                            }
                        }
                    }

                    // A row that says what to do in System Settings needs the
                    // room, and the footer would only say it again, vaguer.
                    if !rows.contains(where: { $0.state.showsGuidance }) {
                        Text(rows.allSatisfy { $0.state == .granted } ? OnboardingCopy.bothOn : OnboardingCopy.permissionsFooter)
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                            .contentTransition(.opacity)
                    }
                }
                .arrivesAfterTitle()
            }
        }
    }
}

struct PermissionRowView: View {
    let row: PermissionRowModel
    var changeKey: (() -> Void)?
    var didShowTurnedOn: (PermissionSurface) -> Void = { _ in }
    let perform: (PermissionRowModel.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// After Quit & Reopen the row first shows as it was, then turns on.
    @State private var revealed = true

    private var isOn: Bool { row.state == .granted && revealed }

    /// The green tile's share: all or nothing, or the renderer's frame.
    private var greenShare: Double {
        if let time = row.drawnMoment, row.state == .granted { return PermissionOnMotion.tile(at: time) }
        return isOn ? 1 : 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.md + 2) {
            iconTile

            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .padding(.bottom, 1)
                if row.state.showsGuidance {
                    // While the row says what to do in System Settings, what
                    // it is for takes one line, so both rows fit the window.
                    Text(row.benefits.map(\.text).joined(separator: " · "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(row.benefits) { benefit in
                        HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.sm) {
                            Image(systemName: benefit.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                                .frame(width: 15)
                                .accessibilityHidden(true)
                            Text(benefit.text)
                                .font(.system(size: 13))
                                .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if benefit.namesTheKey, let changeKey {
                                Button(OnboardingCopy.AskKey.change, action: changeKey)
                                    .onboardingText(color: OnboardingDesign.Palette.accentText)
                            }
                        }
                    }
                }
                if let note = row.note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                guidance
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, OnboardingDesign.Space.lg + 2)
        .padding(.vertical, OnboardingDesign.Space.lg)
        .glassCard(padding: 0)
        .animation(OnboardingDesign.Motion.resolve(.easeOut(duration: PermissionOnMotion.tileCrossfade),
                                                   reduceMotion: reduceMotion), value: row.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.stateWords)
        .onAppear(perform: revealOnce)
    }

    /// After Quit & Reopen: the checkmark appears once the screen has
    /// arrived, so the person sees that it worked.
    private func revealOnce() {
        guard row.appearsOnce, row.state == .granted else { return }
        revealed = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ScreenTransition.standardDuration + 0.2))
            // Colour and opacity only, so it plays under Reduce Motion too.
            withAnimation(.easeOut(duration: PermissionOnMotion.tileCrossfade)) {
                revealed = true
            }
            didShowTurnedOn(row.surface)
        }
    }

    /// The permission's symbol on a soft tile: blue, crossfading to the
    /// calm green with a check once on (220 ms).
    private var iconTile: some View {
        ZStack {
            tile(fill: OnboardingDesign.Palette.accentSoft, ink: OnboardingDesign.Palette.accent)
                .opacity(1 - greenShare)
            tile(fill: OnboardingDesign.Palette.onSoft, ink: OnboardingDesign.Palette.on)
                .opacity(greenShare)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private func tile(fill: Color, ink: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .overlay(
                Image(systemName: row.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ink)
            )
    }

    /// What to do next, under the row's own lines, while it is not on.
    /// It takes the row's full width, so the lines above keep theirs.
    @ViewBuilder
    private var guidance: some View {
        switch row.state {
        case .waiting:
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                HStack(spacing: OnboardingDesign.Space.xs + 2) {
                    ProgressView().controlSize(.small)
                    Text(OnboardingCopy.waitingForSettings)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                // One step a line, so neither wraps a word or two alone.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(OnboardingCopy.sentences(OnboardingCopy.waitingHint(row.surface)), id: \.self) { step in
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                // For when macOS showed no prompt: the words the hint names.
                Button(OnboardingCopy.openSettings) { perform(.openSettings) }
                    .onboardingText(color: OnboardingDesign.Palette.accentText)
            }
            .padding(.top, OnboardingDesign.Space.sm)
        case .needsHelp:
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
                // The row's full width, as the waiting hint has: one line
                // where it fits, so two rows that need help fit the window.
                let lines = OnboardingCopy.needsHelpLines(twoCopies: row.twoCopies)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(OnboardingCopy.notOnYet).fontWeight(.semibold).foregroundStyle(.primary)
                        + Text(" " + lines[0]))
                    ForEach(lines.dropFirst(), id: \.self) { Text($0) }
                }
                .font(.system(size: 12))
                .foregroundStyle(OnboardingDesign.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: OnboardingDesign.Space.lg) {
                    Button(OnboardingCopy.openSettings) { perform(.openSettings) }
                        .buttonStyle(RowButtonStyle(filled: false))
                    if row.offersAskAgain {
                        Button(OnboardingCopy.askAgain) { perform(.askAgain) }
                            .onboardingText(color: OnboardingDesign.Palette.accentText)
                    }
                }
            }
            .padding(.top, OnboardingDesign.Space.sm)
        case .idle, .granted:
            EmptyView()
        }
    }

    /// "Allow" before asking, a checkmark the moment it is on; nothing in
    /// between, where the row's own lines say what to do. The checkmark
    /// fades in as it grows from 0.85 to full size (200 ms), and only fades
    /// under Reduce Motion.
    @ViewBuilder
    private var trailing: some View {
        if let time = row.drawnMoment, row.state == .granted {
            let checkmark = PermissionOnMotion.checkmark(at: time, reduceMotion: false)
            onCheckmark
                .opacity(checkmark.opacity)
                .scaleEffect(checkmark.scale)
        } else if isOn {
            onCheckmark
                .transition(
                    (reduceMotion
                        ? AnyTransition.opacity
                        : .opacity.combined(with: .scale(scale: PermissionOnMotion.checkmarkStartScale, anchor: .center)))
                    .animation(.easeOut(duration: PermissionOnMotion.checkmarkDuration))
                )
        } else if row.state == .idle {
            Button(OnboardingCopy.allow) { perform(.allow) }
                .buttonStyle(RowButtonStyle(filled: true))
                .disabled(!row.canAllow)
                .opacity(row.canAllow ? 1 : 0.45)
        }
    }

    private var onCheckmark: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
            Text(OnboardingCopy.permissionOn)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(OnboardingDesign.Palette.on)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// The compact button a row carries: filled for "Allow", outlined for
/// "Open System Settings".
struct RowButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : OnboardingDesign.Palette.ink)
            .padding(.horizontal, OnboardingDesign.Space.md + 2)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? OnboardingDesign.Palette.accent : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(filled ? Color.clear : Color.primary.opacity(0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .fixedSize()
    }
}
