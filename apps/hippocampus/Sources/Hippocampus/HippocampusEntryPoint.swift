import Foundation
import HippocampusKit
import SwiftUI

@main
enum HippocampusEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == SessionContextHook.flag {
            SessionContextHook.runCLI(arguments: arguments, executableURL: Bundle.main.executableURL)
            return
        }
        if arguments.first == PreferencesOpenRequest.flag,
           PreferencesOpenRequest(arguments: arguments) == nil { return }
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
