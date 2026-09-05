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
        HippocampusApp.main()
    }
}
