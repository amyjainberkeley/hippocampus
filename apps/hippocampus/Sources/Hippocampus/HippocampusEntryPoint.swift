import Foundation
import HippocampusKit
import SwiftUI

@main
enum HippocampusEntryPoint {
    @MainActor
    static func main() {
        #if DEBUG
        // Draws Ask's states to PNGs and returns before any scene, menu-bar
        // item, window or activation exists.
        if CommandBarPreviewRenderer.renderIfRequested() { return }
        #endif
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == SessionContextHook.flag {
            SessionContextHook.runCLI(arguments: arguments, executableURL: Bundle.main.executableURL)
            return
        }
        if arguments.first == PreferencesOpenRequest.flag,
           PreferencesOpenRequest(arguments: arguments) == nil { return }
        // Copies AppKit makes itself (⌘C on selected text in Ask or
        // Preferences) stay on this Mac and out of clipboard history too.
        ClipboardHygiene.ruleEveryCopy()
        // A direct Recall launch cannot use Launch Services' shared bundle-ID
        // reuse. Serialize GUI parents before constructing any supervisor.
        guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL else {
            HippocampusApp.main()
            return
        }
        do {
            guard let lease = try ParentApplicationLease.acquire(executableURL: executable) else {
                PreferencesOpenRequest(arguments: arguments)?.post(to: executable)
                return
            }
            withExtendedLifetime(lease) { HippocampusApp.main() }
        } catch {
            FileHandle.standardError.write(Data("Hippocampus could not acquire its parent application lease.\n".utf8))
        }
    }
}
