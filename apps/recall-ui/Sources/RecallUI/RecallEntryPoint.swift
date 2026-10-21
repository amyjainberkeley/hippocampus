import Darwin
import RecallUIKit
import SwiftUI

/// The process starts here. A render of the synthetic preview returns (or
/// exits) before anything of the app exists: no scene, no window, no menu-bar
/// item and no activation. Otherwise the app runs.
@main
enum RecallEntryPoint {
    @MainActor
    static func main() {
        // Owner-only before anything is created: every file this process
        // makes is 0600 and every folder 0700 (reports/e2e, finding 5).
        umask(0o077)
        #if DEBUG
        // Overview and You (`--render-previews=`): draws and exits.
        RecallPreviewRenderer.renderAndExitIfRequested()
        // The shell and Ask (`--render-window=`).
        if WindowRenderer.renderIfRequested() { return }
        #endif
        // Copies AppKit makes itself (⌘C on selected text, a view's Copy
        // command) stay on this Mac and out of clipboard history too.
        ClipboardHygiene.ruleEveryCopy()
        MCIRecallApp.main()
    }
}
