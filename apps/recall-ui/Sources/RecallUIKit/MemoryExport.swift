// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Where an export goes, and what to say about it (storage-security review
/// S8). An export is a plaintext copy of the memory: the person chooses
/// where it goes, in a save panel that says so, and hears when the folder
/// they chose syncs to iCloud.
public enum ExportDestination {
    /// The save panel's message.
    public static let panelMessage =
        "This file isn\u{2019}t encrypted: anyone who can open it can read it. "
        + "Desktop, Documents and iCloud Drive may sync it to iCloud, and Spotlight can read files there."

    /// The name the save panel suggests.
    public static func suggestedName(now: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        return "hippocampus-export-\(stamp).jsonl"
    }

    /// A warning when `url` is in a folder that leaves this Mac or may:
    /// iCloud Drive, or Desktop and Documents, which iCloud syncs when
    /// "Desktop & Documents Folders" is on. Nil elsewhere.
    public static func warning(
        for url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ relative: String) -> Bool {
            let folder = home.appendingPathComponent(relative, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            return path == folder || path.hasPrefix(folder + "/")
        }
        if inside("Library/Mobile Documents") {
            return "It\u{2019}s in iCloud Drive, so a copy leaves this Mac."
        }
        if inside("Desktop") || inside("Documents") {
            return "Desktop and Documents may sync to iCloud."
        }
        return nil
    }
}

/// Export Everything: the bundled agent writes every moment, in full, as
/// JSON lines, to a new file only this user can read (`mci-agent export`).
public enum MemoryExport {
    /// A large memory takes a while to write.
    public static let timeoutSeconds: TimeInterval = 900

    /// The command for `url`.
    public static func command(
        to url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> ContextHandoffCommand {
        let agent = try ContextHandoffCommand.agentURL(
            environment: environment,
            recallExecutableURL: recallExecutableURL,
            isExecutable: isExecutable
        )
        var arguments = ["export", "--out", url.path]
        if let dbPath = environment["MCI_DB_PATH"], !dbPath.isEmpty {
            arguments += ["--db-path", dbPath]
        }
        return ContextHandoffCommand(executableURL: agent, arguments: arguments)
    }

    /// Writes the export and returns how many moments it holds.
    public static func run(to url: URL) async throws -> Int {
        let output = try await ContextHandoffExporter.run(
            command: try command(to: url),
            timeoutSeconds: timeoutSeconds
        )
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ContextHandoffError.commandFailed
        }
        return count
    }
}
