import SwiftUI
import OnboardingKit

@main
struct OnboardingApp: App {
    @StateObject private var flowVM: OnboardingFlowViewModel
    @StateObject private var trustVM: TrustPanelViewModel
    @StateObject private var retentionVM: RetentionViewModel

    init() {
        #if canImport(AppKit)
        let sr: any TCCPermission = RealScreenRecordingPermission()
        let ax: any TCCPermission = RealAccessibilityPermission()
        let auto: any TCCPermission = RealAutomationPermission()
        #else
        let sr: any TCCPermission = StubTCCPermission(kind: .screenRecording)
        let ax: any TCCPermission = StubTCCPermission(kind: .accessibility)
        let auto: any TCCPermission = StubTCCPermission(kind: .automation)
        #endif

        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: sr, accessibility: ax, automation: auto
        ))
        _trustVM = StateObject(wrappedValue: TrustPanelViewModel(
            allowlistStore: StubAllowlistStore(),
            denylistStore: DiskDenylistEditorStore()
        ))
        _retentionVM = StateObject(wrappedValue: RetentionViewModel(
            store: DiskRetentionStore()
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
