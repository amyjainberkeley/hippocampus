import SwiftUI
import OnboardingKit

struct BrowserExtensionStepView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var extensionVM: BrowserExtensionViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Browser Extension")
                .font(.title)
                .fontWeight(.semibold)

            Text("Install the Hippocampus extension to capture full page text — not just what's visible on screen. This makes search much richer.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if extensionVM.hasBrowsers {
                browserList
            } else {
                Text("No supported browsers detected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Maybe Later") {
                flowVM.advance()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var browserList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(extensionVM.rows) { row in
                HStack(spacing: 10) {
                    browserIcon(for: row.browser)
                        .frame(width: 20)
                    Text(row.browser.name)
                        .font(.body)
                    Spacer()
                    statusBadge(for: row.extensionStatus)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Install") {
                        extensionVM.installAction(for: row.browser)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Already installed?") {
                        extensionVM.checkExtension(for: row.browser.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.bottom, 4)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private func browserIcon(for browser: DetectedBrowser) -> some View {
        switch browser.kind {
        case .safari:
            Image(systemName: "safari")
        case .chromium:
            Image(systemName: "globe")
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ExtensionStatus) -> some View {
        switch status {
        case .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .notInstalled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
