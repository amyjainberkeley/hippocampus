import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

struct BrowserExtensionSlide: View {
    @EnvironmentObject var extensionVM: BrowserExtensionViewModel
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    /// True after the user has clicked "Open Safari → Settings" once
    /// this session. Drives the inline Automation warning so it only
    /// shows before the first click (there's no value repeating the
    /// warning after the user has already seen the OS dialog). Reset
    /// on view teardown — a user coming back to this slide gets the
    /// warning again, which is fine (defensive re-education).
    @State private var didAttemptSafariAutomation = false

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 48))
                    .foregroundStyle(OnboardingTheme.accentBlue)

                OnboardingTheme.title("Get richer captures from your browser")

                Text("Install the Hippocampus extension to capture full page text — not just what's visible on screen. This makes search much richer.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                if extensionVM.hasBrowsers {
                    browserList
                } else {
                    Text("No supported browsers detected.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            extensionVM.refreshAllStatuses()
        }
    }

    private var browserList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Inline Automation-TCC warning for the Safari row.
            // Renders before the first click (info) or after a prior
            // denial (recovery). Explains WHY the OS dialog is about
            // to appear so the user doesn't panic-deny (audit F1).
            automationCallout

            VStack(alignment: .leading, spacing: 0) {
                ForEach(extensionVM.rows) { row in
                    browserRow(row)
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: 480)
    }

    @ViewBuilder
    private func browserRow(_ row: BrowserExtensionViewModel.BrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                browserIcon(for: row.browser)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.browser.name)
                        .font(.system(size: 14, weight: .medium))
                    if row.browser.kind == .safari {
                        Text("Opens Safari → Settings → Extensions. Toggle Hippocampus on.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                extensionStatusBadge(row.extensionStatus)
                installButton(for: row.browser)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)

            if let instructions = row.installInstructions {
                chromiumInstructions(instructions)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private func installButton(for browser: DetectedBrowser) -> some View {
        Button(browser.kind == .safari ? "Open Safari → Settings" : "Install") {
            if browser.kind == .safari {
                didAttemptSafariAutomation = true
            }
            extensionVM.installAction(for: browser)
            // After Safari click, probe Automation TCC ~2s later so
            // the OS has time to record grant/deny and the denial
            // banner can render on the next paint.
            if browser.kind == .safari {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    _ = flowVM.probeAutomation()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(OnboardingTheme.accentBlue)
    }

    /// Info callout pre-click OR recovery banner post-denial. Only
    /// renders when at least one Safari row exists — no Safari, no
    /// Automation TCC.
    @ViewBuilder
    private var automationCallout: some View {
        let hasSafari = extensionVM.rows.contains { $0.browser.kind == .safari }
        let status = flowVM.automationPermission.status
        if hasSafari && status == .denied {
            calloutBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Automation was denied",
                body: "macOS won't re-prompt until you grant it in Settings, or reset the permission.",
                showRecoveryActions: true
            )
        } else if hasSafari && status != .granted && !didAttemptSafariAutomation {
            calloutBanner(
                icon: "info.circle.fill",
                tint: OnboardingTheme.accentBlue,
                title: "Safari asks for Automation",
                body: "Safari asks for Automation because Hippocampus reads the active tab's URL and text — everything stays local. macOS will show a system dialog the first time you click \"Open Safari → Settings\".",
                showRecoveryActions: false
            )
        }
    }

    private func calloutBanner(
        icon: String,
        tint: Color,
        title: String,
        body: String,
        showRecoveryActions: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showRecoveryActions {
                    HStack(spacing: 8) {
                        Button("Reset & retry") {
                            Task {
                                _ = await flowVM.automationPermission.resetAndRetry()
                                flowVM.refreshPermissions()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Open Automation Settings") {
                            flowVM.automationPermission.openPrivacySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func browserIcon(for browser: DetectedBrowser) -> some View {
        switch browser.kind {
        case .safari:
            Image(systemName: "safari")
                .foregroundStyle(OnboardingTheme.accentBlue)
        case .chromium:
            Image(systemName: "globe")
                .foregroundStyle(OnboardingTheme.accentBlue)
        }
    }

    @ViewBuilder
    private func extensionStatusBadge(_ status: ExtensionStatus) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case .notInstalled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
        case .unknown:
            // Distinguish "probe hasn't run yet" from "probe ran and
            // found nothing" — the empirical delivery probe returns
            // `.notInstalled` (orange) only after `mci-agent stats`
            // has responded. Before that, show a gentle spinning
            // hourglass so the user knows we're still checking.
            CheckingBadge()
        }
    }

    /// Inline 3-step guidance rendered after the user clicks Install
    /// on a Chromium row. Branches on whether `open -a <browser>`
    /// actually launched the browser and whether the bundled
    /// unpacked extension was found, so the copy matches what the
    /// user is seeing on screen.
    @ViewBuilder
    private func chromiumInstructions(
        _ instructions: BrowserExtensionViewModel.ChromiumInstallInstructions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if instructions.didOpenBrowser {
                Text("\(instructions.browserName) just opened to chrome://extensions and Finder is showing the unpacked extension folder. Three steps:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Couldn't auto-open \(instructions.browserName). Open it yourself, paste the URL, then drag the folder onto the page:")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                instructionStep(number: "1", text: "In \(instructions.browserName), toggle Developer mode (top-right of chrome://extensions).")
                instructionStep(number: "2", text: "Click Load unpacked.")
                instructionStep(
                    number: "3",
                    text: instructions.unpackedDirPath == nil
                        ? "Select extensions/chromium from the repo (the bundled copy isn't in this build)."
                        : "Drag the highlighted folder from Finder onto the page, or click Load unpacked and select it."
                )
            }

            if let path = instructions.unpackedDirPath {
                HStack(spacing: 8) {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy path") { copyToClipboard(path) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Button("Reveal") { revealInFinder(path) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }

            if !instructions.didOpenBrowser {
                Button("Copy chrome://extensions") {
                    copyToClipboard("chrome://extensions")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OnboardingTheme.accentBlue.opacity(0.05))
        )
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(OnboardingTheme.accentBlue)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func revealInFinder(_ path: String) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #endif
    }
}

/// Loading-state badge for the `.unknown` extension-status case. Rotates
/// an hourglass 360° every 2s to signal "checking…" without adding a
/// second string of copy to the row. Kept `internal` (default) so tests
/// can reference the type directly.
///
/// Design choice: hourglass vs `ProgressView` — the hourglass reads as
/// "waiting on a check" more clearly than a spinner (which reads as
/// "downloading" in the surrounding onboarding context). Slow rotation
/// avoids attention-hijacking the row while the probe runs.
struct CheckingBadge: View {
    @State private var isRotating: Bool = false

    var body: some View {
        Image(systemName: "hourglass")
            .foregroundStyle(.secondary)
            .font(.system(size: 14))
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                .linear(duration: 2.0).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = true
            }
            .accessibilityLabel("Checking extension status")
            .accessibilityIdentifier("BrowserExtensionStatusBadgeChecking")
    }
}
