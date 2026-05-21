import SwiftUI
import OnboardingKit

struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var trustVM: TrustPanelViewModel
    @EnvironmentObject var retentionVM: RetentionViewModel

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            navigationBar
        }
        .sheet(isPresented: $flowVM.isTrustPanelPresented) {
            TrustPanelView()
                .environmentObject(trustVM)
                .frame(width: 560, height: 520)
        }
    }

    @ViewBuilder
    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(step == flowVM.currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flowVM.currentStep {
        case .welcome:
            WelcomeStepView()
        case .screenRecording:
            PermissionStepView(
                title: "Screen Recording",
                explanation: "Hippocampus needs Screen Recording permission to see what's on your screen. Without it, nothing can be captured.",
                permissionKind: .screenRecording
            )
        case .accessibility:
            PermissionStepView(
                title: "Accessibility",
                explanation: "Accessibility lets Hippocampus detect which window is focused — and more importantly, detect password fields so it knows NOT to capture them.",
                permissionKind: .accessibility
            )
        case .automation:
            AutomationStepView()
        case .done:
            DoneStepView()
        }
    }

    @ViewBuilder
    private var navigationBar: some View {
        HStack {
            if flowVM.canGoBack {
                Button("Back") { flowVM.back() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button("What Hippocampus Sees") {
                flowVM.isTrustPanelPresented = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            if flowVM.canAdvance {
                Button("Continue") { flowVM.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
