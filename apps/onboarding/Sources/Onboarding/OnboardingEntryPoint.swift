// SPDX-License-Identifier: TBD-private
import AppKit
import CoreGraphics
import Foundation
import OnboardingKit

/// Runs before any window. A debug build asked to render previews draws
/// them and returns; the Screen Recording commands (`--tcc-probe`,
/// `--tcc-request`) answer from a fresh process and exit; otherwise setup
/// starts and exits when the app that started it exits.
@main
enum OnboardingEntryPoint {
    @MainActor
    static func main() {
        #if DEBUG
        // Before the parent watch and the app: nothing on screen.
        if OnboardingPreviewRenderer.renderIfRequested() { return }
        #endif
        if let code = TCCProbeCommand.exitCode(
            arguments: ProcessInfo.processInfo.arguments,
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        ) {
            exit(code)
        }
        let parentWatch = ParentProcessWatch {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
            // A modal sheet can hold termination; the parent is gone either way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
        withExtendedLifetime(parentWatch) {
            OnboardingApp.main()
        }
    }
}
