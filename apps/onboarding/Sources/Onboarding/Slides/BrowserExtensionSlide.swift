import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

struct BrowserExtensionSlide: View {
    @EnvironmentObject var extensionVM: BrowserExtensionViewModel

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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(extensionVM.rows) { row in
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

                        Button(row.browser.kind == .safari ? "Open Safari → Settings" : "Install") {
                            extensionVM.installAction(for: row.browser)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(OnboardingTheme.accentBlue)
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
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 480)
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
