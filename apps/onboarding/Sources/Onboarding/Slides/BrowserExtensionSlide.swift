import SwiftUI
import OnboardingKit

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
    }

    private var browserList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(extensionVM.rows) { row in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        browserIcon(for: row.browser)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.browser.name)
                                .font(.system(size: 14, weight: .medium))
                            if row.browser.kind == .safari {
                                Text("beta — Developer ID required")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        extensionStatusBadge(row.extensionStatus)

                        Button(row.browser.kind == .safari ? "Details" : "Install") {
                            extensionVM.installAction(for: row.browser)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(OnboardingTheme.accentBlue)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                }
            }
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420)
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
            EmptyView()
        }
    }
}
