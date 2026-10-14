// SPDX-License-Identifier: Apache-2.0
//
// PermissionReset.swift — "Reset Permissions…" in Preferences, Advanced,
// Troubleshooting (spec-shell S2, spec-copy S3 #10, RULINGS S10). It resets
// only Hippocampus's own grants: without the bundle id, `tccutil reset`
// forgets that service for every app on the Mac
// (critique-shell-engineering 7).

import Foundation

public enum PermissionReset {
    /// The app the grants belong to; the window, onboarding and the helper
    /// run inside its bundle.
    public static let bundleIdentifier = "ai.hippocampus"

    /// Each `tccutil` service, with the name macOS shows for it.
    public static let services: [(service: String, name: String)] = [
        ("ScreenCapture", "Screen Recording"),
        ("Accessibility", "Accessibility"),
        ("SystemPolicyAllFiles", "Full Disk Access"),
    ]

    public static let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")

    public static func arguments(service: String) -> [String] {
        ["reset", service, bundleIdentifier]
    }

    public static let confirmTitle = "Reset permissions?"
    public static let confirmMessage = "macOS will forget that you allowed Screen Recording, Accessibility and Full Disk Access. Hippocampus asks again next time it opens."
    public static let confirmButton = "Reset"
    public static let doneTitle = "Permissions reset"
    public static let doneMessage = "Restart Hippocampus to allow them again."

    /// One line per permission that could not be reset.
    public static func failureMessage(names: [String]) -> String {
        names.map { "Couldn’t reset \($0). Reset it in System Settings, under Privacy & Security." }
            .joined(separator: "\n")
    }

    /// Resets each service with `run`, which returns the exit status, or nil
    /// when the command could not start. Returns the names that failed.
    public static func reset(run: (URL, [String]) -> Int32?) -> [String] {
        services.compactMap { entry in
            run(tccutil, arguments(service: entry.service)) == 0 ? nil : entry.name
        }
    }

    /// Runs `tccutil` and waits for it; nil when it could not start.
    public static func runTCCUtil(_ executable: URL, _ arguments: [String]) -> Int32? {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
