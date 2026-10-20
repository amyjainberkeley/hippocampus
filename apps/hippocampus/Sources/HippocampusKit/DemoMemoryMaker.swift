// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryMaker.swift — makes Demo Memory's made-up week with the two tools
// bundled beside the agent (SPEC-DELTA 6): `mci-seed-brain` writes the week,
// `demo-screens` draws its screenshots and seals them with the capture
// helper's codec.

import Foundation

/// How much the week holds, as the seeder counted it.
public struct DemoMemoryWeek: Equatable, Sendable {
    public let moments: Int
    public let screenshots: Int

    public init(moments: Int, screenshots: Int) {
        self.moments = moments
        self.screenshots = screenshots
    }
}

/// Makes the made-up week into an empty Demo Memory folder.
public protocol DemoMemoryMaking: Sendable {
    func make(into folder: DemoMemoryFolder, keyHex: String, now: Date, timeZone: TimeZone) async throws
        -> DemoMemoryWeek
}

public enum DemoMemoryMakeError: Error, Equatable {
    /// A tool is not in this copy of Hippocampus.
    case missingTool(String)
    /// A tool ended with this status.
    case failed(tool: String, status: Int32)
    case timedOut(tool: String)
    case unreadableOutput(tool: String)
}

/// The tools bundled in Hippocampus.app, run with the key on standard input
/// and an environment of their own that names no memory and no key: the
/// week is written only where the arguments say, and the seeder refuses the
/// person's own memory's folder by itself.
public struct BundledDemoMemoryMaker: DemoMemoryMaking {
    public static let seederName = "mci-seed-brain"
    public static let drawerName = "demo-screens"

    public let seeder: URL
    public let drawer: URL
    /// The home the tools are told; the seeder refuses to write inside its
    /// `Library/Application Support/MCI`.
    public let home: URL
    public let timeout: TimeInterval

    public init(seeder: URL, drawer: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                timeout: TimeInterval = 180) {
        self.seeder = seeder
        self.drawer = drawer
        self.home = home
        self.timeout = timeout
    }

    /// The tools in `Contents/MacOS` beside the agent. A development build
    /// (one with the development key) may name others with
    /// `MCI_DEMO_SEEDER` and `MCI_DEMO_SCREENS`; a release build never.
    public static func bundled(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        developmentBuild: Bool = DevelopmentFileKeyMode.active() != nil
    ) -> Self {
        let folder = bundle.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        func tool(_ name: String, _ variable: String) -> URL {
            if developmentBuild, let path = environment[variable], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return folder.appendingPathComponent(name)
        }
        return Self(seeder: tool(seederName, "MCI_DEMO_SEEDER"), drawer: tool(drawerName, "MCI_DEMO_SCREENS"))
    }

    /// The only environment the tools get.
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    }

    public func make(into folder: DemoMemoryFolder, keyHex: String, now: Date, timeZone: TimeZone) async throws
        -> DemoMemoryWeek {
        for tool in [seeder, drawer] where !FileManager.default.isExecutableFile(atPath: tool.path) {
            throw DemoMemoryMakeError.missingTool(tool.lastPathComponent)
        }
        let clock = ["--now-us", String(UInt64(max(0, now.timeIntervalSince1970) * 1_000_000)),
                     "--tz-offset-secs", String(timeZone.secondsFromGMT(for: now))]
        try FileManager.default.createDirectory(at: folder.making, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder.making) }

        let screens = folder.making.appendingPathComponent("screens.json")
        let list = try await run(seeder, ["--demo-week", "--print-screens"] + clock, input: nil)
        try DemoMemoryFolder.writeNew(list, to: screens)

        let manifest = folder.making.appendingPathComponent("manifest.json")
        _ = try await run(drawer, ["--spec", screens.path, "--blob-root", folder.blobs.path,
                                   "--manifest", manifest.path, "--key-stdin"], input: keyHex)

        let report = try await run(seeder, ["--demo-week", "--screens", manifest.path,
                                            "--db-path", folder.database.path, "--key-stdin"] + clock,
                                   input: keyHex)
        struct Counts: Decodable {
            let moments: Int
            let screenshots: Int
        }
        guard let counts = try? JSONDecoder().decode(Counts.self, from: report) else {
            throw DemoMemoryMakeError.unreadableOutput(tool: Self.seederName)
        }
        return DemoMemoryWeek(moments: counts.moments, screenshots: counts.screenshots)
    }

    /// Runs one tool with `input` on standard input, within the timeout.
    private func run(_ tool: URL, _ arguments: [String], input: String?) async throws -> Data {
        let environment = self.environment
        let timeout = self.timeout
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = environment
            let output = Pipe()
            let standardInput = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            if input == nil {
                process.standardInput = FileHandle.nullDevice
            } else {
                process.standardInput = standardInput
            }
            try process.run()
            if let input {
                try? standardInput.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            }
            try? standardInput.fileHandleForWriting.close()
            let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                process.terminate()
                throw DemoMemoryMakeError.timedOut(tool: tool.lastPathComponent)
            }
            let data = await reader.value
            guard process.terminationStatus == 0 else {
                throw DemoMemoryMakeError.failed(tool: tool.lastPathComponent, status: process.terminationStatus)
            }
            return data
        }.value
    }
}
