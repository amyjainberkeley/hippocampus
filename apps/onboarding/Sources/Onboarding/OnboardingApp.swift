import SwiftUI
import OnboardingKit

@main
struct OnboardingApp: App {
    @StateObject private var flowVM: OnboardingFlowViewModel
    @StateObject private var trustVM: TrustPanelViewModel
    @StateObject private var retentionVM: RetentionViewModel
    @StateObject private var extensionVM: BrowserExtensionViewModel
    @StateObject private var prepareBrainVM: PrepareBrainViewModel

    init() {
        #if canImport(AppKit)
        let sr: any TCCPermission = RealScreenRecordingPermission()
        let ax: any TCCPermission = RealAccessibilityPermission()
        #else
        let sr: any TCCPermission = StubTCCPermission(kind: .screenRecording)
        let ax: any TCCPermission = StubTCCPermission(kind: .accessibility)
        #endif

        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: sr, accessibility: ax
        ))
        _trustVM = StateObject(wrappedValue: TrustPanelViewModel(
            allowlistStore: StubAllowlistStore(),
            denylistStore: DiskDenylistEditorStore()
        ))
        _retentionVM = StateObject(wrappedValue: RetentionViewModel(
            store: DiskRetentionStore()
        ))

        #if canImport(AppKit)
        let detector: any BrowserDetector = RealBrowserDetector()
        #else
        let detector: any BrowserDetector = StubBrowserDetector()
        #endif
        _extensionVM = StateObject(wrappedValue: BrowserExtensionViewModel(
            detector: detector
        ))

        _prepareBrainVM = StateObject(wrappedValue: PrepareBrainViewModel(
            keyGenerator: LocalKeyGenerator(),
            modelDownloader: RealModelDownloader()
        ))
    }

    var body: some Scene {
        WindowGroup {
            OnboardingFlowView()
                .environmentObject(flowVM)
                .environmentObject(trustVM)
                .environmentObject(retentionVM)
                .environmentObject(extensionVM)
                .environmentObject(prepareBrainVM)
                .frame(
                    width: OnboardingTheme.windowWidth,
                    height: OnboardingTheme.windowHeight
                )
        }
        .windowResizability(.contentSize)
    }
}
