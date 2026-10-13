import SwiftUI

/// The process starts here. A render of the synthetic preview returns (or
/// exits) before anything of the app exists: no scene, no window, no menu-bar
/// item and no activation. Otherwise the app runs.
@main
enum RecallEntryPoint {
    @MainActor
    static func main() {
        #if DEBUG
        // Overview and You (`--render-previews=`): draws and exits.
        RecallPreviewRenderer.renderAndExitIfRequested()
        // The shell and Ask (`--render-window=`).
        if WindowRenderer.renderIfRequested() { return }
        #endif
        MCIRecallApp.main()
    }
}
