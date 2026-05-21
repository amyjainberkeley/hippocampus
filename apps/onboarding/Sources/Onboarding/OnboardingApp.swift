import SwiftUI
import OnboardingKit

@main
struct OnboardingApp: App {
    @StateObject private var flowVM: OnboardingFlowViewModel
    @StateObject private var trustVM: TrustPanelViewModel
    @StateObject private var retentionVM: RetentionViewModel

    init() {
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let auto = StubTCCPermission(kind: .automation)
        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: sr, accessibility: ax, automation: auto
        ))
        _trustVM = StateObject(wrappedValue: TrustPanelViewModel(
            store: StubAllowlistStore()
        ))
        _retentionVM = StateObject(wrappedValue: RetentionViewModel(
            store: StubRetentionStore()
        ))
    }

    var body: some Scene {
        WindowGroup {
            OnboardingFlowView()
                .environmentObject(flowVM)
                .environmentObject(trustVM)
                .environmentObject(retentionVM)
                .frame(width: 640, height: 480)
        }
        .windowResizability(.contentSize)
    }
}
