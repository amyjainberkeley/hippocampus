import SwiftUI
import AppKit
import OnboardingKit

/// Screen 3. Both permissions show at once, each framed by what it lets
/// Hippocampus do. "Allow" raises macOS's prompt only; the row then waits
/// until the person comes back to this window, and one refresh decides
/// whether it is on, when its checkmark appears. Nothing moves a row on a
/// timer. The window comes forward when the second one turns on.
struct PermissionsSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        PermissionsScreen(
            intro: OnboardingCopy.permissionsBody(isReview: flowVM.isReview),
            rows: OnboardingFlowViewModel.rowSurfaces.map(row),
            perform: perform
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
    }

    private func row(_ surface: PermissionSurface) -> PermissionRowModel {
        PermissionRowModel(
            surface: surface,
            key: AskKeyHint.current(),
            state: flowVM.rowState(surface),
            canAllow: flowVM.canRequest(surface),
            offersAskAgain: flowVM.offersAskAgain(surface)
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
        var id: String { text }
    }

    let surface: PermissionSurface
    let name: String
    let benefits: [Benefit]
    let note: String?
    let state: PermissionRowState
    let canAllow: Bool
    let offersAskAgain: Bool

    var id: PermissionSurface { surface }

    init(
        surface: PermissionSurface,
        key: AskKeyHint,
        state: PermissionRowState,
        canAllow: Bool,
        offersAskAgain: Bool,
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
            benefits = OnboardingCopy.accessibilityBenefits(key).enumerated().map { index, text in
                Benefit(text: text, symbol: symbols[min(index, symbols.count - 1)])
            }
            note = nil
        }
        self.state = state
        self.canAllow = canAllow
        self.offersAskAgain = offersAskAgain
    }

    var symbol: String {
        switch surface {
        case .screenRecording: "rectangle.dashed"
        case .accessibility: "accessibility"
        }
    }
}

/// The screen as drawn: the preview renderer builds it from fixture rows.
struct PermissionsScreen: View {
    let intro: String?
    let rows: [PermissionRowModel]
    let perform: (PermissionRowModel.Action, PermissionSurface) -> Void

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: OnboardingCopy.permissionsTitle, intro: intro)

                VStack(spacing: OnboardingDesign.Space.md) {
                    ForEach(rows) { row in
                        PermissionRowView(row: row) { perform($0, row.surface) }
                    }
                }

                // A row that says what to do in System Settings needs the
                // room, and the footer would only say it again, vaguer.
                if !rows.contains(where: { $0.state.showsGuidance }) {
                    Text(OnboardingCopy.permissionsFooter)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PermissionRowView: View {
    let row: PermissionRowModel
    let perform: (PermissionRowModel.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOn: Bool { row.state == .granted }

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.md + 2) {
            iconTile

            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                    .padding(.bottom, 1)
                ForEach(row.benefits) { benefit in
                    HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.sm) {
                        Image(systemName: benefit.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 15)
                            .accessibilityHidden(true)
                        Text(benefit.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = row.note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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
        .animation(OnboardingDesign.Motion.resolve(.easeOut(duration: 0.22), reduceMotion: reduceMotion), value: row.state)
    }

    /// The permission's symbol on a soft tile, green with a check once on.
    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isOn ? OnboardingDesign.Palette.onSoft : OnboardingDesign.Palette.accentSoft)
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: row.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isOn ? OnboardingDesign.Palette.on : OnboardingDesign.Palette.accent)
            )
            .accessibilityHidden(true)
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
                Text(OnboardingCopy.waitingHint(row.surface))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // For when macOS showed no prompt: the words the hint names.
                Button(OnboardingCopy.openSettings) { perform(.openSettings) }
                    .onboardingText(color: OnboardingDesign.Palette.accentText)
            }
            .padding(.top, OnboardingDesign.Space.sm)
        case .needsHelp:
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
                // The row's full width, as the waiting hint has: one line
                // where it fits, so two rows that need help fit the window.
                (Text(OnboardingCopy.notOnYet).fontWeight(.semibold).foregroundStyle(.primary)
                    + Text(" " + OnboardingCopy.needsHelpHint))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
    /// between, where the row's own lines say what to do.
    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .idle:
            Button(OnboardingCopy.allow) { perform(.allow) }
                .buttonStyle(RowButtonStyle(filled: true))
                .disabled(!row.canAllow)
                .opacity(row.canAllow ? 1 : 0.45)
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                Text(OnboardingCopy.permissionOn)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(OnboardingDesign.Palette.on)
            .padding(.top, 2)
            .transition(
                reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7, anchor: .center))
            )
            .accessibilityElement(children: .combine)
        case .waiting, .needsHelp:
            EmptyView()
        }
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
