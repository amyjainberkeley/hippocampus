import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

/// The browser extension panel, opened from Preferences. Browsers are
/// read without it (RULINGS G8); it adds each page's address and the text
/// off screen. Install for a Chromium browser opens chrome://extensions
/// and shows the extension's folder in Finder; for Safari it opens
/// Safari's settings, which raises macOS's Automation prompt the first
/// time.
struct BrowserExtensionSlide: View {
    @EnvironmentObject var extensionVM: BrowserExtensionViewModel
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    /// True after the first click on Open Safari Settings this session.
    /// The note about macOS's prompt shows only before it: after the
    /// click the person has seen the prompt itself.
    @State private var didAttemptSafariAutomation = false

    var body: some View {
        BrowserExtensionScreen(
            rows: extensionVM.rows,
            automation: flowVM.automationPermission.status,
            didAttemptSafariAutomation: didAttemptSafariAutomation,
            perform: perform
        )
        .task {
            extensionVM.refreshAllStatuses()
        }
    }

    private func perform(_ action: BrowserExtensionScreen.Action) {
        switch action {
        case .install(let browser):
            if browser.kind == .safari {
                didAttemptSafariAutomation = true
            }
            extensionVM.installAction(for: browser)
            // macOS records the Automation answer a moment after the
            // click; look again then, so a "no" shows.
            if browser.kind == .safari {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    flowVM.probeAutomation()
                }
            }
        case .askAgainForAutomation:
            Task {
                _ = await flowVM.automationPermission.resetAndRetry()
                flowVM.refreshPermissions()
            }
        case .openAutomationSettings:
            flowVM.automationPermission.openPrivacySettings()
        case .copy(let text):
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        case .showInFinder(let path):
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            #endif
        }
    }
}

/// The panel as drawn: the preview renderer builds it from fixture rows.
/// Every word comes from `OnboardingCopy`.
struct BrowserExtensionScreen: View {
    enum Action {
        case install(DetectedBrowser)
        case askAgainForAutomation
        case openAutomationSettings
        case copy(String)
        case showInFinder(String)
    }

    let rows: [BrowserExtensionViewModel.BrowserRow]
    /// macOS's Automation answer for Hippocampus, for the Safari note.
    let automation: TCCStatus
    let didAttemptSafariAutomation: Bool
    let perform: (Action) -> Void

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: OnboardingCopy.extensionTitle, intro: OnboardingCopy.extensionBody)

                if rows.isEmpty {
                    Text(OnboardingCopy.noBrowserFound)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                        automationNote
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider() }
                                browserRow(row)
                            }
                        }
                        .glassCard(padding: 0)
                    }
                }
            }
        }
    }

    // MARK: - Safari and macOS's Automation prompt

    /// Before the first click on Open Safari Settings, what macOS is about
    /// to ask and why; after a "no", how to get it back. Only with Safari.
    @ViewBuilder
    private var automationNote: some View {
        let hasSafari = rows.contains { $0.browser.kind == .safari }
        if hasSafari && automation == .denied {
            note(
                symbol: "exclamationmark.triangle.fill",
                tint: OnboardingDesign.Palette.attention,
                title: OnboardingCopy.automationOffTitle,
                body: OnboardingCopy.automationOffBody,
                offersRecovery: true
            )
        } else if hasSafari && automation != .granted && !didAttemptSafariAutomation {
            note(
                symbol: "info.circle.fill",
                tint: OnboardingDesign.Palette.accent,
                title: OnboardingCopy.automationAskTitle,
                body: OnboardingCopy.automationAskBody,
                offersRecovery: false
            )
        }
    }

    private func note(
        symbol: String, tint: Color, title: String, body: String, offersRecovery: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: OnboardingDesign.Space.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 14))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardingDesign.Palette.ink)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if offersRecovery {
                    HStack(spacing: OnboardingDesign.Space.lg) {
                        Button(OnboardingCopy.askAgain) { perform(.askAgainForAutomation) }
                            .buttonStyle(RowButtonStyle(filled: false))
                        Button(OnboardingCopy.openAutomationSettings) { perform(.openAutomationSettings) }
                            .onboardingText(color: OnboardingDesign.Palette.accentText)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(OnboardingDesign.Space.md)
        .background(
            RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - One browser

    private func browserRow(_ row: BrowserExtensionViewModel.BrowserRow) -> some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            HStack(spacing: OnboardingDesign.Space.md) {
                Image(systemName: row.browser.kind == .safari ? "safari" : "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(OnboardingDesign.Palette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.browser.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingDesign.Palette.ink)
                    if row.browser.kind == .safari {
                        Text(OnboardingCopy.safariExtensionHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: OnboardingDesign.Space.sm)
                statusBadge(row.extensionStatus)
                Button(row.browser.kind == .safari ? OnboardingCopy.openSafariSettings : OnboardingCopy.install) {
                    perform(.install(row.browser))
                }
                .buttonStyle(RowButtonStyle(filled: false))
            }

            if let instructions = row.installInstructions {
                chromiumSteps(instructions)
                    .padding(.leading, 22 + OnboardingDesign.Space.md)
            }
        }
        .padding(.vertical, OnboardingDesign.Space.md)
        .padding(.horizontal, OnboardingDesign.Space.lg)
    }

    @ViewBuilder
    private func statusBadge(_ status: ExtensionStatus) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(OnboardingDesign.Palette.success)
                .font(.system(size: 14))
                .accessibilityLabel(OnboardingCopy.permissionOn)
        case .notInstalled:
            EmptyView()
        case .unknown:
            CheckingBadge()
        }
    }

    /// What to do in the browser after Install, as it happened: the
    /// browser and Finder opened, or only Finder, or the extension's
    /// folder is missing from this copy of Hippocampus.
    @ViewBuilder
    private func chromiumSteps(
        _ instructions: BrowserExtensionViewModel.ChromiumInstallInstructions
    ) -> some View {
        if let path = instructions.unpackedDirPath {
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.md) {
                    Text(OnboardingCopy.extensionStepsIntro(
                        browser: instructions.browserName, didOpenBrowser: instructions.didOpenBrowser
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The address that sentence names, to paste.
                    if !instructions.didOpenBrowser {
                        Spacer(minLength: OnboardingDesign.Space.sm)
                        Button(OnboardingCopy.copyAddress) { perform(.copy("chrome://extensions")) }
                            .onboardingText(color: OnboardingDesign.Palette.accentText)
                    }
                }

                VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs) {
                    step(1, OnboardingCopy.extensionStepDeveloperMode)
                    step(2, OnboardingCopy.extensionStepLoadUnpacked)
                    step(3, OnboardingCopy.extensionStepChooseFolder)
                }

                HStack(spacing: OnboardingDesign.Space.md) {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: OnboardingDesign.Space.sm)
                    Button(OnboardingCopy.copyPath) { perform(.copy(path)) }
                        .onboardingText(color: OnboardingDesign.Palette.accentText)
                    Button(OnboardingCopy.showInFinder) { perform(.showInFinder(path)) }
                        .onboardingText(color: OnboardingDesign.Palette.accentText)
                }
            }
        } else {
            Text(OnboardingCopy.extensionFolderMissing)
                .font(.system(size: 12))
                .foregroundStyle(OnboardingDesign.Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OnboardingDesign.Space.sm) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(OnboardingDesign.Palette.accentText)
                .frame(width: 12, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The extension's state is being looked up: an hourglass that turns
/// slowly, so it reads as a check rather than a download.
struct CheckingBadge: View {
    @State private var isRotating: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "hourglass")
            .foregroundStyle(.secondary)
            .font(.system(size: 14))
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 2.0).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = !reduceMotion
            }
            .accessibilityLabel(OnboardingCopy.checking)
            .accessibilityIdentifier("BrowserExtensionStatusBadgeChecking")
    }
}
