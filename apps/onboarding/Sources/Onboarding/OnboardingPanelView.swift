import SwiftUI
import OnboardingKit

/// One panel, opened by route after consent (`hippocampus://setup/<panel>`):
/// the same window, no dots, no Back, one "Done".
struct OnboardingPanelView: View {
    let panel: OnboardingPanel
    /// The preview renderer fixes what the never-read panel says is kept.
    var keptForPreview: String?
    let done: () -> Void

    var body: some View {
        OnboardingWindow {
            content
        } bar: {
            BottomBar(primaryLabel: OnboardingCopy.done, primary: done)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .appAccess:
            AllowlistSlide()
        case .browserExtension:
            BrowserExtensionSlide()
        case .mcpServers:
            McpServersSlide()
        case .neverRead:
            NeverReadPanel(keptForPreview: keptForPreview)
        }
    }
}

/// What is never read, and the rest of the Promise, read-only.
struct NeverReadPanel: View {
    var keptForPreview: String?
    /// Read from the retention file; a missing file means 90 days.
    @State private var kept = OnboardingCopy.kept(policy: .ninetyDays, customDays: nil, needsReview: false)

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                ScreenHeader(title: OnboardingCopy.neverReadTitle)
                PromiseLines(kept: keptForPreview ?? kept)
            }
        }
        .task {
            guard keptForPreview == nil else { return }
            kept = await OnboardingCopy.kept(from: DiskRetentionStore())
        }
    }
}
