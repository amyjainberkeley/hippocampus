// SPDX-License-Identifier: Apache-2.0
//
// HookRepair.swift — once per launch (SPEC 5.5): the hooks and the Codex
// instruction Hippocampus already wrote, brought up to date. Each hook is
// made quiet, so deleting the app without disconnecting never fills a
// session with errors; when this copy of Hippocampus is installed where it
// stays, each hook follows it there. Nothing is added, and a group edited
// by hand is left alone. The look-up entries are repaired by the agent as
// it starts (`repair_existing_registrations`).

import Foundation

public extension SessionContextInstaller {
    /// The app calls it once, from launch. It runs off the main thread under
    /// the installer's safety rules: structured edits, never a file edited
    /// by hand, never a link, an atomic replace under a lock.
    @MainActor
    static func repairOnLaunch(
        executableURL: URL? = Bundle.main.executableURL,
        bundleURL: URL = Bundle.main.bundleURL,
        dbURL: URL = ProcessSupervisor.databaseURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let executableURL,
              let installer = try? SessionContextInstaller.forApp(
                  executableURL: executableURL, dbURL: dbURL, environment: environment
              ) else { return }
        let movedHere = isInstalledToStay(executableURL: executableURL, bundleURL: bundleURL)
        Task.detached(priority: .utility) {
            _ = installer.repairExistingEntries(movedHere: movedHere)
        }
    }

    /// Whether this copy of Hippocampus is an app installed where it stays:
    /// inside an `.app`, and not run from a translocated or mounted copy.
    /// A build run from elsewhere never points anyone's hooks at itself.
    static func isInstalledToStay(executableURL: URL, bundleURL: URL) -> Bool {
        let path = executableURL.path
        return bundleURL.pathExtension == "app"
            && path.hasPrefix(bundleURL.path + "/Contents/MacOS/")
            && !path.contains("/AppTranslocation/")
            && !path.hasPrefix("/Volumes/")
    }
}
